from datetime import date, timedelta

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, status

from .. import clock, db, schedule
from ..deps import CurrentUser, Scope, get_current_user, get_scope, require_owner
from ..money import rules, service as money
from ..phone import normalize
from ..scope import branch_filter, link_teacher, require_teacher, teacher_filter
from ..schemas import (
    CreateTeacherRequest,
    JoinTeacherRequest,
    MergeTeachersRequest,
    ScheduleSlot,
    Teacher,
    TeacherGroupCard,
    TeacherListItem,
    TeacherMatch,
    TeacherMonthPoint,
    TeacherProfile,
    SetTeacherBranchesRequest,
    UpdateTeacherRequest,
)
from .timetable import _timetable

router = APIRouter(prefix="/teachers", tags=["teachers"], dependencies=[Depends(get_current_user)])


def _clean_phone(phone: str | None) -> str | None:
    return normalize(phone) if phone and phone.strip() else None


_BRANCHES = """
coalesce((select array_agg(tb.branch_id order by b.name) from teacher_branches tb join branches b on b.id = tb.branch_id
          where tb.teacher_id = t.id and {scope}), '{{}}') as branch_ids,
coalesce((select array_agg(b.name order by b.name) from teacher_branches tb join branches b on b.id = tb.branch_id
          where tb.teacher_id = t.id and {scope}), '{{}}') as branch_names
"""


def _branches(n: int) -> str:
    return _BRANCHES.format(scope=branch_filter("tb.branch_id", n))


async def _teacher(conn, scope: Scope, teacher_id: int) -> Teacher:
    """The teacher as the scope sees them, or 404."""
    row = await conn.fetchrow(
        f"select t.*, {_branches(2)} from teachers t where t.id = $1 and {teacher_filter('t', 2)}",
        teacher_id,
        scope.ids,
    )
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "O'qituvchi topilmadi.")
    return Teacher(**row)


@router.get("", response_model=list[TeacherListItem])
async def list_teachers(include_inactive: bool = False, scope: Scope = Depends(get_scope)):
    where = teacher_filter("t", 1) + ("" if include_inactive else " and t.is_active")
    rows = await db.pool().fetch(
        f"""
        select t.*, {_branches(1)},
               count(distinct g.id) filter (where g.is_active) as group_count,
               count(e.id) filter (where g.is_active and e.status = 'active') as student_count
        from teachers t
        left join groups g on g.teacher_id = t.id and {branch_filter('g.branch_id', 1)}
        left join enrollments e on e.group_id = g.id
        where {where}
        group by t.id
        order by t.full_name asc
        """,
        scope.ids,
    )
    return [TeacherListItem(**row) for row in rows]


async def _branch_names(conn, teacher_id: int) -> list[str]:
    return await conn.fetchval(
        "select coalesce(array_agg(b.name order by b.name), '{}') from teacher_branches tb "
        "join branches b on b.id = tb.branch_id where tb.teacher_id = $1",
        teacher_id,
    )


async def _refuse_phone_twin(conn, phone: str, *, except_id: int | None = None) -> None:
    other = await conn.fetchval(
        "select id from teachers where phone = $1 and ($2::bigint is null or id <> $2) limit 1", phone, except_id
    )
    if other is not None:
        where = ", ".join(await _branch_names(conn, other)) or "boshqa filial"
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"Bu raqam bilan o'qituvchi allaqachon bor ({where}). Uni o'z filialingizga qo'shing.",
        )


async def _refuse_twin(conn, *, name: str, phone: str | None, branch_id: int, except_id: int | None = None) -> None:
    """One person is one teacher. A number that already belongs to a teacher
    (in any branch) is refused with where they work, and a name that already
    exists in this branch too -- the front desk should add the existing
    teacher to their branch instead of making a twin."""
    if phone:
        await _refuse_phone_twin(conn, phone, except_id=except_id)
    if await conn.fetchval(
        """
        select 1 from teachers t join teacher_branches tb on tb.teacher_id = t.id
        where tb.branch_id = $1 and lower(t.full_name) = lower($2) and ($3::bigint is null or t.id <> $3)
        """,
        branch_id,
        name,
        except_id,
    ):
        raise HTTPException(status.HTTP_409_CONFLICT, "Bu filialda shu ismli o'qituvchi allaqachon bor.")


@router.get("/lookup", response_model=list[TeacherMatch])
async def lookup_teachers(phone: str | None = None, name: str | None = None, scope: Scope = Depends(get_scope)):
    """Who might this be? Teachers with the same number or the same name, in
    any branch -- shown while a teacher is being added, so the same person is
    joined to this branch instead of being made again. Only the name and the
    branches are shown for a teacher of another branch."""
    number = _clean_phone(phone)
    wanted = (name or "").strip()
    if not number and not wanted:
        return []
    rows = await db.pool().fetch(
        """
        select t.id, t.full_name, t.phone,
               coalesce((select array_agg(b.name order by b.name) from teacher_branches tb
                         join branches b on b.id = tb.branch_id where tb.teacher_id = t.id), '{}') as branch_names,
               ($3::bigint[] is null or exists (select 1 from teacher_branches tb
                                                where tb.teacher_id = t.id and tb.branch_id = any($3))) as in_scope
        from teachers t
        where t.is_active and (($1::text is not null and t.phone = $1) or ($2 <> '' and lower(t.full_name) = lower($2)))
        order by t.id
        """,
        number,
        wanted,
        scope.ids,
    )
    return [
        TeacherMatch(
            teacher_id=r["id"],
            full_name=r["full_name"],
            branch_names=r["branch_names"],
            in_scope=r["in_scope"],
            same_phone=bool(number and r["phone"] == number),
        )
        for r in rows
    ]


@router.post("/{teacher_id}/join-branch", response_model=Teacher)
async def join_branch(
    teacher_id: int,
    payload: JoinTeacherRequest,
    user: CurrentUser = Depends(get_current_user),
    scope: Scope = Depends(get_scope),
):
    """"Shu o'qituvchini mening filialimga qo'shish": the same person teaches
    here too. An admin must give the teacher's number (so an id alone is not
    enough); the owner need not."""
    branch_id = scope.write_branch()
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            row = await conn.fetchrow("select id, phone from teachers where id = $1 and is_active", teacher_id)
            if row is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "O'qituvchi topilmadi.")
            if not user.is_owner and (not row["phone"] or _clean_phone(payload.phone) != row["phone"]):
                raise HTTPException(status.HTTP_404_NOT_FOUND, "O'qituvchi topilmadi.")
            await link_teacher(conn, teacher_id, branch_id)
            await money.audit(conn, user.id, "teacher", teacher_id, "join_branch", after={"branch_id": branch_id})
            return await _teacher(conn, scope, teacher_id)


@router.post("", response_model=Teacher, status_code=status.HTTP_201_CREATED)
async def create_teacher(
    payload: CreateTeacherRequest, user: CurrentUser = Depends(get_current_user), scope: Scope = Depends(get_scope)
):
    name = payload.full_name.strip()
    if not name:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Ism kiritilishi shart.")
    branch_id = scope.write_branch()
    phone = _clean_phone(payload.phone)
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            await _refuse_twin(conn, name=name, phone=phone, branch_id=branch_id)
            try:
                row = await conn.fetchrow(
                    """
                    insert into teachers (full_name, phone, note, created_by, telegram_user_id)
                    values ($1, $2, $3, $4, $5)
                    returning id
                    """,
                    name,
                    _clean_phone(payload.phone),
                    payload.note,
                    user.id,
                    payload.telegram_user_id,
                )
            except asyncpg.UniqueViolationError:
                raise HTTPException(status.HTTP_409_CONFLICT, "Bu Telegram ID boshqa o'qituvchiga biriktirilgan.")
            await link_teacher(conn, row["id"], branch_id)
            return await _teacher(conn, scope, row["id"])


@router.put("/{teacher_id}/branches", response_model=Teacher)
async def set_teacher_branches(
    teacher_id: int, payload: SetTeacherBranchesRequest, user: CurrentUser = Depends(require_owner)
):
    """OWNER ONLY: which branches this teacher works in (at least one)."""
    ids = sorted(set(payload.branch_ids))
    if not ids:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Kamida bitta filialni tanlang.")
    everything = Scope(user, None, 0)
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            await require_teacher(conn, everything, teacher_id)
            if await conn.fetchval("select count(*) from branches where id = any($1::bigint[])", ids) != len(ids):
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Filial topilmadi.")
            # A teacher cannot be taken out of a branch where they still teach a group.
            blocked = await conn.fetchval(
                """
                select b.name from groups g join branches b on b.id = g.branch_id
                where g.teacher_id = $1 and g.is_active and g.branch_id <> all($2::bigint[]) limit 1
                """,
                teacher_id, ids,
            )
            if blocked:
                raise HTTPException(
                    status.HTTP_409_CONFLICT, f"{blocked} filialida hali guruhi bor: avval guruhni boshqa o'qituvchiga bering."
                )
            await conn.execute("delete from teacher_branches where teacher_id = $1 and branch_id <> all($2::bigint[])", teacher_id, ids)
            for branch_id in ids:
                await link_teacher(conn, teacher_id, branch_id)
            return await _teacher(conn, everything, teacher_id)


@router.patch("/{teacher_id}", response_model=Teacher)
async def update_teacher(teacher_id: int, payload: UpdateTeacherRequest, scope: Scope = Depends(get_scope)):
    existing = await require_teacher(db.pool(), scope, teacher_id)

    updates = payload.model_dump(exclude_unset=True)
    if not updates:
        return await _teacher(db.pool(), scope, teacher_id)
    if "full_name" in updates:
        if not (updates["full_name"] or "").strip():
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Ism kiritilishi shart.")
        updates["full_name"] = updates["full_name"].strip()
    if "is_active" in updates and updates["is_active"] is None:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "is_active bo'sh bo'lishi mumkin emas.")
    if "phone" in updates:
        updates["phone"] = _clean_phone(updates["phone"])
    if updates.get("phone") and updates["phone"] != existing["phone"]:
        await _refuse_phone_twin(db.pool(), updates["phone"], except_id=teacher_id)

    fields = list(updates.keys())
    values = list(updates.values())
    set_clause = ", ".join(f"{field} = ${i + 2}" for i, field in enumerate(fields))
    try:
        await db.pool().execute(f"update teachers set {set_clause} where id = $1", teacher_id, *values)
    except asyncpg.UniqueViolationError:
        raise HTTPException(status.HTTP_409_CONFLICT, "Bu Telegram ID boshqa o'qituvchiga biriktirilgan.")
    return await _teacher(db.pool(), scope, teacher_id)


@router.post("/{teacher_id}/merge", response_model=Teacher)
async def merge_teachers(
    teacher_id: int, payload: MergeTeachersRequest, user: CurrentUser = Depends(require_owner)
):
    """OWNER ONLY: the same person was made twice. Folds [teacher_id] into
    [into_id]: their groups, lessons, pay and history move over, the branches
    are added up, and the duplicate is switched off (kept, so nothing is
    lost). Refused when both already have a pay run for the same month, or the
    two would teach at the same hour."""
    into_id = payload.into_id
    if into_id == teacher_id:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Bir xil o'qituvchini birlashtirib bo'lmaydi.")
    everything = Scope(user, None, 0)
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            source = await require_teacher(conn, everything, teacher_id)
            target = await require_teacher(conn, everything, into_id)
            await conn.execute("select id from teachers where id = any($1::bigint[]) order by id for update", [teacher_id, into_id])
            clash = await conn.fetchval(
                "select min(a.month) from salary_runs a join salary_runs b on b.month = a.month "
                "where a.teacher_id = $1 and b.teacher_id = $2",
                teacher_id,
                into_id,
            )
            if clash:
                raise HTTPException(
                    status.HTTP_409_CONFLICT,
                    f"Ikkalasida ham {clash:%Y-%m} oyi uchun oylik hisob bor: birlashtirib bo'lmaydi.",
                )
            # They must not end up teaching two groups at the same hour.
            for group_id in await conn.fetchval("select coalesce(array_agg(id), '{}') from groups where teacher_id = $1", teacher_id):
                slots = await schedule.load_slots(conn, group_ids=[group_id], active_only=False)
                await schedule.check_clashes(conn, group_id=group_id, teacher_id=into_id, slots=slots)
            for table in (
                "groups",
                "lessons",
                "trial_sessions",
                "transactions",
                "expenses",
                "payment_allocations",
                "salary_runs",
                "salary_payouts",
            ):
                await conn.execute(f"update {table} set teacher_id = $2 where teacher_id = $1", teacher_id, into_id)
            await conn.execute(
                "insert into teacher_branches (teacher_id, branch_id) "
                "select $2, branch_id from teacher_branches where teacher_id = $1 on conflict do nothing",
                teacher_id,
                into_id,
            )
            await conn.execute("delete from teacher_branches where teacher_id = $1", teacher_id)
            note = f"Birlashtirildi: #{into_id} {target['full_name']}"
            await conn.execute(
                "update teachers set is_active = false, note = concat_ws(E'\n', note, $2::text) where id = $1",
                teacher_id,
                note,
            )
            await money.audit(
                conn, user.id, "teacher", into_id, "merge", before={"merged_id": teacher_id, "name": source["full_name"]}
            )
            return await _teacher(conn, everything, into_id)


def _months_back(month: date, count: int) -> list[date]:
    months = [month]
    for _ in range(count - 1):
        months.insert(0, rules.month_start(months[0] - timedelta(days=1)))
    return months


@router.get("/{teacher_id}/profile", response_model=TeacherProfile)
async def teacher_profile(
    teacher_id: int,
    month: date | None = None,
    user: CurrentUser = Depends(get_current_user),
    scope: Scope = Depends(get_scope),
):
    """The teacher's page: their groups (name, students, days, times), what
    they earn this month, today and tomorrow, and six months of pay. The pay is
    the share of what ALL their groups collected (or their fixed amount), worked
    out by the same calculation as the Finance page, so the two always agree."""
    today = clock.today()
    month = rules.month_start(month or today)
    async with db.pool().acquire() as conn:
        teacher = await require_teacher(conn, scope, teacher_id)
        teacher_out = await _teacher(conn, scope, teacher_id)

        groups = await conn.fetch(
            f"""
            select g.id, g.name, g.level, g.capacity, s.name as subject_name, b.name as branch_name,
                   (select count(*) from enrollments e where e.group_id = g.id and e.status = 'active') as students
            from groups g
            left join subjects s on s.id = g.subject_id
            left join branches b on b.id = g.branch_id
            where g.teacher_id = $1 and g.is_active and {branch_filter('g.branch_id', 2)}
            order by g.name
            """,
            teacher_id,
            scope.ids,
        )
        slots = await schedule.load_slots(conn, group_ids=[g["id"] for g in groups], active_only=False)
        lessons = await _timetable(conn, today, today + timedelta(days=1), teacher_id=teacher_id, ids=scope.ids)

        # Pay is the owner's alone: an admin's request never even computes it.
        report, mine, history = None, None, []
        if user.is_owner:
            report = await money.salary_month(conn, month, scope.ids)
            mine = next((t for t in report["teachers"] if t["teacher_id"] == teacher_id), None)
            for m in _months_back(month, 6):
                r = report if m == month else await money.salary_month(conn, m, scope.ids)
                row = next((t for t in r["teachers"] if t["teacher_id"] == teacher_id), None)
                history.append(
                    TeacherMonthPoint(
                        month=m,
                        collected=row["collected"] if row else 0,
                        earned=row["earned"] if row else 0,
                        paid=row["paid"] if row else 0,
                        closed=r["closed"],
                    )
                )

    cards = [
        TeacherGroupCard(
            group_id=g["id"],
            name=g["name"],
            subject_name=g["subject_name"],
            level=g["level"],
            student_count=g["students"],
            capacity=g["capacity"],
            branch_name=g["branch_name"],
            schedule=[
                ScheduleSlot(weekday=sl.weekday, starts_at=sl.starts_at, ends_at=sl.ends_at, room=sl.room)
                for sl in slots
                if sl.group_id == g["id"]
            ],
        )
        for g in groups
    ]
    return TeacherProfile(
        teacher=teacher_out,
        salary_visible=user.is_owner,
        salary_method=teacher["salary_method"] if user.is_owner else None,
        salary_percent=(
            float(teacher["salary_percent"]) if user.is_owner and teacher["salary_percent"] is not None else None
        ),
        salary_fixed=teacher["salary_fixed"] if user.is_owner else None,
        groups=cards,
        student_total=sum(g["students"] for g in groups),
        month=month,
        month_closed=report["closed"] if report else False,
        collected=mine["collected"] if mine else 0,
        earned=mine["earned"] if mine else 0,
        paid=mine["paid"] if mine else 0,
        remaining=mine["remaining"] if mine else 0,
        lessons=lessons,
        history=history,
    )
