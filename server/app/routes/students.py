from datetime import datetime, time

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, status

from .. import clock, db, funnel, schedule, student_events
from ..deps import CurrentUser, get_current_user
from ..phone import is_valid_uzbek_phone, normalize
from ..schemas import (
    CreateStudentRequest,
    CreateStudentWithEnrollmentRequest,
    PhoneCheck,
    PhoneOwner,
    ActivityItem,
    AddedToGroup,
    ActionResult,
    AddToGroupRequest,
    ArchiveRequest,
    RemoveFromGroupRequest,
    StudentEvent,
    TransferNotice,
    TransferRequest,
    TransferResult,
    UnarchiveRequest,
    ProfileAttendance,
    ProfileGroup,
    ProfileMark,
    ProfilePayment,
    ScheduleSlot,
    Student,
    StudentGroupRef,
    StudentProfile,
    StudentSummary,
    StudentEnrolled,
    StudentListItem,
    UpdateStudentRequest,
)
from ..money import service as money
from .enrollments import enroll, withdraw

router = APIRouter(prefix="/students", tags=["students"], dependencies=[Depends(get_current_user)])

HEARD_FROM = ("instagram", "telegram", "referral", "walk_in", "other")
PAYMENT_METHODS = money.PAYMENT_METHODS


def valid_phone(raw: str | None, label: str = "Telefon") -> str:
    """Digits only, 998 + 9 digits -- how every phone is compared and stored,
    so "+998 90 100 00 70" and "998901000070" are the same number."""
    phone = normalize(raw or "")
    if not is_valid_uzbek_phone(phone):
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            f"{label} noto'g'ri: +998 dan keyin 9 ta raqam bo'lishi kerak.",
        )
    return phone


def optional_phone(raw: str | None, label: str) -> str | None:
    return valid_phone(raw, label) if raw and raw.strip() else None


def heard_from_value(value: str | None) -> str | None:
    if value is None:
        return None
    if value not in HEARD_FROM:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "\"Qayerdan eshitdi\" qiymati noto'g'ri.")
    return value


async def phone_owner(conn, phone: str) -> PhoneOwner | None:
    """The student who already has this (normalized) phone, with the groups
    they're active in -- one student per number, see uq_students_phone."""
    row = await conn.fetchrow(
        """
        select s.id, s.full_name, s.phone,
               coalesce(array_agg(g.name order by g.name) filter (where g.id is not null), '{}') as group_names
        from students s
        left join enrollments e on e.student_id = s.id and e.status = 'active'
        left join groups g on g.id = e.group_id
        where s.phone = $1
        group by s.id
        """,
        phone,
    )
    if row is None:
        return None
    return PhoneOwner(
        student_id=row["id"], full_name=row["full_name"], phone=row["phone"], group_names=list(row["group_names"])
    )


def duplicate_phone_error(owner: PhoneOwner) -> HTTPException:
    groups = ", ".join(owner.group_names) or "guruhsiz"
    return HTTPException(
        status.HTTP_409_CONFLICT,
        f"Bu raqam allaqachon mavjud: {owner.full_name} ({groups})",
    )


async def _raise_if_taken(conn, phone: str, *, except_student_id: int | None = None) -> None:
    owner = await phone_owner(conn, phone)
    if owner is not None and owner.student_id != except_student_id:
        raise duplicate_phone_error(owner)


_RECENT_MARKS = """
coalesce((
  select array_agg(m.status order by m.starts_at)
  from (
    select a.status, l.starts_at
    from attendance a
    join lessons l on l.id = a.lesson_id
    join enrollments e2 on e2.id = a.enrollment_id
    where e2.student_id = s.id
    order by l.starts_at desc
    limit 10
  ) m
), '{}')
"""


@router.get("", response_model=list[StudentListItem])
async def list_students(q: str | None = None):
    where = "where s.full_name ilike $1 or s.phone ilike $1" if q else ""
    args = [f"%{q.strip()}%"] if q else []
    rows = await db.pool().fetch(
        f"""
        select s.*, -sb.balance as balance,
               coalesce((
                 select array_agg(g.name order by g.name)
                 from enrollments e join groups g on g.id = e.group_id
                 where e.student_id = s.id and e.status = 'active'
               ), '{{}}') as group_names,
               {_RECENT_MARKS} as attendance_recent,
               s.created_at > now() - interval '14 days' as is_new
        from students s
        join student_balances sb on sb.student_id = s.id
        {where}
        order by s.full_name asc
        """,
        *args,
    )
    refs = await _group_refs(db.pool(), [row["id"] for row in rows])
    items = []
    for row in rows:
        data = dict(row)
        marks = list(data["attendance_recent"])
        attendance = _attendance(marks)
        mine = refs.get(row["id"], [])
        data.update(
            groups=mine,
            attendance_rate=attendance.rate,
            is_debtor=row["balance"] > 0,
            is_active=bool(mine),
            is_archived=row["archived_at"] is not None,
            is_at_risk=bool(mine) and attendance.rate is not None and attendance.total >= 3 and attendance.rate < AT_RISK_BELOW,
        )
        items.append(StudentListItem(**data))
    return items


# Below this share of lessons attended (of the last ten marked), a student is "Xavf ostida".
AT_RISK_BELOW = 0.75


async def _group_refs(conn, student_ids: list[int]) -> dict[int, list[StudentGroupRef]]:
    """The active groups of each student, with teacher and weekly days."""
    if not student_ids:
        return {}
    rows = await conn.fetch(
        """
        select e.student_id, g.id as group_id, g.name, g.subject_id, sub.name as subject_name,
               g.teacher_id, t.full_name as teacher_name
        from enrollments e
        join groups g on g.id = e.group_id
        left join subjects sub on sub.id = g.subject_id
        left join teachers t on t.id = g.teacher_id
        where e.status = 'active' and e.student_id = any($1::bigint[])
        order by g.name
        """,
        student_ids,
    )
    slots = await schedule.load_slots(conn, group_ids=list({r["group_id"] for r in rows}), active_only=False)
    refs: dict[int, list[StudentGroupRef]] = {}
    for row in rows:
        refs.setdefault(row["student_id"], []).append(
            StudentGroupRef(
                **{k: v for k, v in row.items() if k != "student_id"},
                schedule=[
                    ScheduleSlot(weekday=sl.weekday, starts_at=sl.starts_at, ends_at=sl.ends_at, room=sl.room)
                    for sl in slots
                    if sl.group_id == row["group_id"]
                ],
            )
        )
    return refs


# Declared before "/{student_id}" so the path isn't read as a student id.
@router.get("/summary", response_model=StudentSummary)
async def students_summary():
    """The O'quvchilar header, from app/funnel.py -- leads, trials included,
    are not students."""
    async with db.pool().acquire() as conn:
        return StudentSummary(**await funnel.student_counts(conn))


@router.get("/phone-check", response_model=PhoneCheck)
async def check_phone(phone: str):
    """Live duplicate check while the number is being typed. Anything that
    isn't a complete number yet simply has no owner."""
    normalized = normalize(phone)
    if not is_valid_uzbek_phone(normalized):
        return PhoneCheck(owner=None)
    return PhoneCheck(owner=await phone_owner(db.pool(), normalized))


@router.post("", response_model=Student, status_code=status.HTTP_201_CREATED)
async def create_student(payload: CreateStudentRequest):
    full_name = payload.full_name.strip()
    if not full_name:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "F.I.Sh. kiritilishi shart.")
    phone = valid_phone(payload.phone)
    await _raise_if_taken(db.pool(), phone)
    try:
        row = await db.pool().fetchrow(
            """
            insert into students (full_name, phone, telegram_username, note, parent_phone, heard_from)
            values ($1, $2, $3, $4, $5, $6)
            returning *
            """,
            full_name,
            phone,
            payload.telegram_username,
            payload.note,
            optional_phone(payload.parent_phone, "Ota-ona telefoni"),
            heard_from_value(payload.heard_from),
        )
    except asyncpg.UniqueViolationError:
        # Someone saved the same number between the check and the insert.
        raise duplicate_phone_error(await phone_owner(db.pool(), phone))
    return Student(**row)


@router.post("/with-enrollment", response_model=StudentEnrolled, status_code=status.HTTP_201_CREATED)
async def create_student_with_enrollment(
    payload: CreateStudentWithEnrollmentRequest, user: CurrentUser = Depends(get_current_user)
):
    """The "Yangi o'quvchi" dialog: student, enrollment, first charge and the
    optional first payment are saved together or not at all -- a failure
    can never leave a student without a group."""
    full_name = payload.full_name.strip()
    if not full_name:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "F.I.Sh. kiritilishi shart.")
    phone = valid_phone(payload.phone)
    parent_phone = optional_phone(payload.parent_phone, "Ota-ona telefoni")
    heard_from = heard_from_value(payload.heard_from)
    note = (payload.note or "").strip() or None

    first_payment = payload.first_payment_amount or 0
    if first_payment < 0:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "To'lov summasi manfiy bo'lishi mumkin emas.")
    if first_payment and payload.first_payment_method not in PAYMENT_METHODS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "To'lov usulini tanlang.")

    async with db.pool().acquire() as conn:
        await _raise_if_taken(conn, phone)
        try:
            async with conn.transaction():
                student = await conn.fetchrow(
                    """
                    insert into students (full_name, phone, note, parent_phone, heard_from, created_by)
                    values ($1, $2, $3, $4, $5, $6)
                    returning *
                    """,
                    full_name,
                    phone,
                    note,
                    parent_phone,
                    heard_from,
                    user.id,
                )
                enrollment, first_charge = await enroll(
                    conn,
                    student_id=student["id"],
                    group_id=payload.group_id,
                    joined_at=payload.joined_at,
                    created_by=user.id,
                    first_month=payload.first_month,
                    discount_kind=payload.discount_kind,
                    discount_value=payload.discount_value,
                )
                if first_payment:
                    await money.record_payment(
                        conn,
                        student_id=student["id"],
                        enrollment_id=enrollment["id"],
                        amount=first_payment,
                        method=payload.first_payment_method,
                        user_id=user.id,
                    )
        except asyncpg.UniqueViolationError:
            raise duplicate_phone_error(await phone_owner(conn, phone))

    return StudentEnrolled(
        student=Student(**student),
        enrollment_id=enrollment["id"],
        first_charge=first_charge,
        first_payment=first_payment,
    )


def _attendance(marks: list[str]) -> ProfileAttendance:
    """Counts and the rate from a list of marks, oldest first."""
    counts = {key: marks.count(key) for key in ("present", "late", "absent", "excused")}
    # Excused lessons are not held against the student: the rate is over the
    # lessons they were expected at.
    expected = len(marks) - counts["excused"]
    came = counts["present"] + counts["late"]
    return ProfileAttendance(
        **counts,
        total=len(marks),
        rate=round(came / expected, 4) if expected else None,
        recent=marks[-10:],
    )


@router.get("/{student_id}/profile", response_model=StudentProfile)
async def student_profile(student_id: int):
    """The student's profile panel in one answer: who they are, every group
    with its balance and attendance, the payments taken (cancelled ones marked)."""
    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(
            "select s.*, s.created_at > now() - interval '14 days' as is_new, -sb.balance as owed "
            "from students s join student_balances sb on sb.student_id = s.id where s.id = $1",
            student_id,
        )
        if row is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "O'quvchi topilmadi.")
        enrollments = await conn.fetch(
            """
            select e.id as enrollment_id, e.group_id, g.name as group_name, sub.name as subject_name,
                   t.full_name as teacher_name, g.fee_amount, e.joined_at, e.status, e.ended_at,
                   eb.owed as balance
            from enrollments e
            join groups g on g.id = e.group_id
            left join subjects sub on sub.id = g.subject_id
            left join teachers t on t.id = g.teacher_id
            join enrollment_balances eb on eb.enrollment_id = e.id
            where e.student_id = $1
            order by (e.status = 'active') desc, e.joined_at desc, e.id desc
            """,
            student_id,
        )
        marks = await conn.fetch(
            """
            select a.enrollment_id, a.status, l.starts_at as at, g.name as group_name, g.id as group_id
            from attendance a join lessons l on l.id = a.lesson_id
            join enrollments e on e.id = a.enrollment_id
            join groups g on g.id = e.group_id
            where e.student_id = $1
            order by l.starts_at, a.id
            """,
            student_id,
        )
        by_enrollment: dict[int, list[str]] = {}
        for mark in marks:
            by_enrollment.setdefault(mark["enrollment_id"], []).append(mark["status"])
        slots = await schedule.load_slots(conn, group_ids=[e["group_id"] for e in enrollments], active_only=False)
        due = await money.next_due_dates(conn, [e["enrollment_id"] for e in enrollments])
        debt_since = await conn.fetchval(
            "select min(due_date) from charge_balances where student_id = $1 and status = 'active' and owed > 0",
            student_id,
        )
        debt_since_by_enrollment = {
            r["enrollment_id"]: r["since"]
            for r in await conn.fetch(
                "select enrollment_id, min(due_date) as since from charge_balances "
                "where student_id = $1 and status = 'active' and owed > 0 group by enrollment_id",
                student_id,
            )
        }
        charges = await conn.fetch(
            """
            select c.created_at as at, c.amount, c.period_start, g.name as group_name, g.id as group_id
            from charges c join enrollments e on e.id = c.enrollment_id join groups g on g.id = e.group_id
            where e.student_id = $1 and c.status = 'active'
            order by c.created_at desc limit 10
            """,
            student_id,
        )
        missed = await conn.fetch(
            """
            select l.starts_at as at, a.status, g.name as group_name, g.id as group_id
            from attendance a join lessons l on l.id = a.lesson_id
            join enrollments e on e.id = a.enrollment_id join groups g on g.id = e.group_id
            where e.student_id = $1 and a.status in ('absent', 'late')
            order by l.starts_at desc limit 10
            """,
            student_id,
        )
        payments = await conn.fetch(
            """
            select p.id, p.enrollment_id, g.id as group_id, g.name as group_name, p.amount, p.method, p.received_at,
                   u.full_name as received_by_name, p.receipt_no, p.note, p.status, p.cancel_reason
            from payments p
            left join enrollments e on e.id = p.enrollment_id
            left join groups g on g.id = e.group_id
            left join users u on u.id = p.received_by
            where p.student_id = $1 and p.kind = 'payment'
            order by p.received_at desc, p.id desc
            limit 100
            """,
            student_id,
        )
        events = await conn.fetch(
            """
            select ev.id, ev.kind, ev.group_id, ev.group_name, ev.to_group_id, ev.to_group_name, ev.note, ev.debt,
                   u.full_name as by_name, ev.created_at as at
            from student_events ev left join users u on u.id = ev.created_by
            where ev.student_id = $1
            order by ev.created_at desc, ev.id desc
            limit 100
            """,
            student_id,
        )
        # A move whose old group is still owed and whose new group has not
        # had a payment yet: reminded until the first payment on the new one.
        notices = await conn.fetch(
            """
            select ev.group_id as from_group_id, ev.group_name as from_group_name,
                   ev.to_group_id, ev.to_group_name, eb.owed as debt, ev.created_at as at
            from student_events ev
            join enrollment_balances eb on eb.enrollment_id = ev.enrollment_id
            where ev.student_id = $1 and ev.kind = 'transferred' and eb.owed > 0
              and not exists (
                select 1 from payments p
                where p.enrollment_id = ev.to_enrollment_id and p.kind = 'payment' and p.status = 'valid'
              )
            order by ev.created_at desc
            """,
            student_id,
        )
    activity = _activity(enrollments, charges, missed, payments)
    today = clock.today()
    student = Student(**{k: v for k, v in row.items() if k not in ("is_new", "owed")})
    groups = [
        ProfileGroup(
            **e,
            next_due_date=due.get(e["enrollment_id"]),
            debt_since=debt_since_by_enrollment.get(e["enrollment_id"]),
            schedule=[
                ScheduleSlot(weekday=sl.weekday, starts_at=sl.starts_at, ends_at=sl.ends_at, room=sl.room)
                for sl in slots
                if sl.group_id == e["group_id"]
            ],
            attendance=_attendance(by_enrollment.get(e["enrollment_id"], [])),
        )
        for e in enrollments
    ]
    return StudentProfile(
        student=student,
        is_new=row["is_new"],
        balance=row["owed"],
        paid_total=sum(p["amount"] for p in payments if p["status"] == "valid"),
        groups=groups,
        attendance=_attendance([m["status"] for m in marks]),
        payments=[ProfilePayment(**p) for p in payments],
        debt_since=debt_since,
        overdue_days=max((today - debt_since).days, 0) if debt_since else 0,
        activity=activity,
        marks=[ProfileMark(at=m["at"], group_id=m["group_id"], group_name=m["group_name"], status=m["status"]) for m in reversed(marks)][:30],
        events=[StudentEvent(**e) for e in events],
        transfer_notices=[TransferNotice(**n) for n in notices],
    )


def _activity(enrollments, charges, missed, payments) -> list[ActivityItem]:
    """The latest things that happened to this student, newest first."""
    items: list[ActivityItem] = []
    for e in enrollments:
        items.append(
            ActivityItem(
                at=datetime.combine(e["joined_at"], time(), schedule.center_tz()),
                kind="joined",
                title="Guruhga qo'shildi",
                detail=e["group_name"],
                group_id=e["group_id"],
            )
        )
    for c in charges:
        items.append(
            ActivityItem(
                at=c["at"], kind="charge", title="Hisob chiqdi", detail=c["group_name"],
                amount=c["amount"], group_id=c["group_id"],
            )
        )
    for m in missed:
        items.append(
            ActivityItem(
                at=m["at"],
                kind=m["status"],
                title="Darsga kelmadi" if m["status"] == "absent" else "Darsga kechikdi",
                detail=m["group_name"],
                group_id=m["group_id"],
            )
        )
    for p in payments[:10]:
        cancelled = p["status"] == "cancelled"
        items.append(
            ActivityItem(
                at=p["received_at"],
                kind="payment_cancelled" if cancelled else "payment",
                title="To'lov bekor qilindi" if cancelled else "To'lov qabul qilindi",
                detail=p["group_name"],
                amount=p["amount"],
                group_id=p["group_id"],
            )
        )
    items.sort(key=lambda i: i.at, reverse=True)
    return items[:12]


def _need_note(note: str, what: str) -> str:
    note = (note or "").strip()
    if not note:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, f"{what} sababini (izoh) yozing.")
    return note


async def _student_for_update(conn, student_id: int):
    row = await conn.fetchrow("select * from students where id = $1 for update", student_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "O'quvchi topilmadi.")
    return row


@router.post("/{student_id}/archive", response_model=ActionResult)
async def archive_student(student_id: int, payload: ArchiveRequest, user: CurrentUser = Depends(get_current_user)):
    """"Arxivga o'tkazish": he leaves every group he is in -- with a comment --
    and is marked archived. His lessons, attendance, charges and payments all
    stay; what he still owes is reported back."""
    note = _need_note(payload.note, "Arxivga o'tkazish")
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            student = await _student_for_update(conn, student_id)
            if student["archived_at"] is not None:
                raise HTTPException(status.HTTP_409_CONFLICT, "O'quvchi allaqachon arxivda.")
            active = await conn.fetch(
                "select * from enrollments where student_id = $1 and status = 'active' order by id", student_id
            )
            for e in active:
                debt = await withdraw(conn, dict(e), user.id, "O'quvchi arxivga o'tkazildi")
                await student_events.log(
                    conn, student_id, "removed", user.id,
                    group_id=e["group_id"], enrollment_id=e["id"], note=note, debt=debt,
                )
            total = await conn.fetchval("select coalesce(sum(owed), 0)::bigint from enrollment_balances eb "
                                        "join enrollments e on e.id = eb.enrollment_id where e.student_id = $1", student_id)
            await conn.execute("update students set archived_at = now() where id = $1", student_id)
            await student_events.log(conn, student_id, "archived", user.id, note=note, debt=total)
            await money.audit(conn, user.id, "student", student_id, "archive", reason=note, after={"owed": total})
    return ActionResult(debt=total)


@router.post("/{student_id}/unarchive", response_model=ActionResult)
async def unarchive_student(
    student_id: int, payload: UnarchiveRequest, user: CurrentUser = Depends(get_current_user)
):
    """Takes him out of the archive. He is in no group yet: the groups he had
    are on his profile, faded, each with a button to put him back."""
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            student = await _student_for_update(conn, student_id)
            if student["archived_at"] is None:
                raise HTTPException(status.HTTP_409_CONFLICT, "O'quvchi arxivda emas.")
            await conn.execute("update students set archived_at = null where id = $1", student_id)
            await student_events.log(conn, student_id, "unarchived", user.id, note=payload.note)
            await money.audit(conn, user.id, "student", student_id, "unarchive", reason=payload.note)
            owed = -await conn.fetchval("select balance from student_balances where student_id = $1", student_id)
    return ActionResult(debt=max(owed or 0, 0))


@router.post("/{student_id}/remove-from-group", response_model=ActionResult)
async def remove_from_group(
    student_id: int, payload: RemoveFromGroupRequest, user: CurrentUser = Depends(get_current_user)
):
    """He leaves this one group (with a comment); everything he did there stays.
    Returns what he still owes on it, so the app can say whether he paid up."""
    note = _need_note(payload.note, "Guruhdan chiqarish")
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            await _student_for_update(conn, student_id)
            e = await conn.fetchrow(
                "select * from enrollments where student_id = $1 and group_id = $2 and status = 'active'",
                student_id, payload.group_id,
            )
            if e is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "O'quvchi bu guruhda emas.")
            debt = await withdraw(conn, dict(e), user.id, "O'quvchi guruhdan chiqarildi")
            await student_events.log(
                conn, student_id, "removed", user.id,
                group_id=payload.group_id, enrollment_id=e["id"], note=note, debt=debt,
            )
            await money.audit(
                conn, user.id, "student", student_id, "remove_from_group", reason=note,
                after={"group_id": payload.group_id, "owed": debt},
            )
    return ActionResult(debt=debt)


@router.post("/{student_id}/transfer", response_model=TransferResult)
async def transfer_student(
    student_id: int, payload: TransferRequest, user: CurrentUser = Depends(get_current_user)
):
    """"Guruhni almashtirish": he leaves one group and joins another in one
    step. The new group bills him by its own price and rule from today; what he
    owed on the old one stays owed (and is shown on his profile until he makes
    his first payment on the new group)."""
    if payload.from_group_id == payload.to_group_id:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Boshqa guruhni tanlang.")
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            await _student_for_update(conn, student_id)
            old = await conn.fetchrow(
                "select * from enrollments where student_id = $1 and group_id = $2 and status = 'active'",
                student_id, payload.from_group_id,
            )
            if old is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "O'quvchi eski guruhda emas.")
            new, first_charge = await enroll(
                conn, student_id=student_id, group_id=payload.to_group_id, joined_at=clock.today(),
                created_by=user.id, log_event=False,
            )
            debt = await withdraw(conn, dict(old), user.id, "O'quvchi boshqa guruhga o'tdi")
            await student_events.log(
                conn, student_id, "transferred", user.id,
                group_id=payload.from_group_id, to_group_id=payload.to_group_id,
                enrollment_id=old["id"], to_enrollment_id=new["id"], note=payload.note, debt=debt,
            )
            await money.audit(
                conn, user.id, "student", student_id, "transfer", reason=(payload.note or None),
                after={"from_group_id": payload.from_group_id, "to_group_id": payload.to_group_id, "owed": debt},
            )
            group_name = await conn.fetchval("select name from groups where id = $1", payload.to_group_id)
    return TransferResult(enrollment_id=new["id"], group_name=group_name, first_charge=first_charge, old_debt=debt)


@router.post("/{student_id}/add-to-group", response_model=AddedToGroup, status_code=status.HTTP_201_CREATED)
async def add_to_group(student_id: int, payload: AddToGroupRequest, user: CurrentUser = Depends(get_current_user)):
    """"Boshqa guruhga qo'shish": the student takes another subject. The
    enrollment, its first bill by the group's own rule and the optional first
    payment are done together or not at all. A full group still takes them."""
    first_payment = payload.first_payment_amount or 0
    if first_payment < 0:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "To'lov summasi manfiy bo'lishi mumkin emas.")
    if first_payment and payload.first_payment_method not in money.PAYMENT_METHODS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "To'lov usulini tanlang.")
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            if not await conn.fetchval("select 1 from students where id = $1", student_id):
                raise HTTPException(status.HTTP_404_NOT_FOUND, "O'quvchi topilmadi.")
            enrollment, first_charge = await enroll(
                conn, student_id=student_id, group_id=payload.group_id, joined_at=payload.joined_at,
                created_by=user.id,
            )
            if first_payment:
                await money.record_payment(
                    conn, student_id=student_id, enrollment_id=enrollment["id"], amount=first_payment,
                    method=payload.first_payment_method, user_id=user.id,
                )
            await money.audit(
                conn, user.id, "student", student_id, "add_to_group",
                after={"group_id": payload.group_id, "enrollment_id": enrollment["id"]},
            )
            group_name = await conn.fetchval("select name from groups where id = $1", payload.group_id)
    return AddedToGroup(
        enrollment_id=enrollment["id"], group_name=group_name, first_charge=first_charge, first_payment=first_payment
    )


@router.get("/{student_id}", response_model=Student)
async def get_student(student_id: int):
    row = await db.pool().fetchrow("select * from students where id = $1", student_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "O'quvchi topilmadi.")
    return Student(**row)


@router.patch("/{student_id}", response_model=Student)
async def update_student(
    student_id: int, payload: UpdateStudentRequest, user: CurrentUser = Depends(get_current_user)
):
    """Edit the profile: name, phone, parent phone, address, note. Every change
    is written to the audit log with what it was and what it became."""
    existing = await db.pool().fetchrow("select * from students where id = $1", student_id)
    if existing is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "O'quvchi topilmadi.")

    updates = payload.model_dump(exclude_unset=True)
    if "full_name" in updates:
        updates["full_name"] = (updates["full_name"] or "").strip()
        if not updates["full_name"]:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "F.I.Sh. kiritilishi shart.")
    if "phone" in updates:
        updates["phone"] = valid_phone(updates["phone"])
        await _raise_if_taken(db.pool(), updates["phone"], except_student_id=student_id)
    if "parent_phone" in updates:
        updates["parent_phone"] = optional_phone(updates["parent_phone"], "Ota-ona telefoni")
    for field in ("address", "note", "telegram_username"):
        if field in updates:
            updates[field] = (updates[field] or "").strip() or None
    updates = {field: value for field, value in updates.items() if value != existing[field]}
    if not updates:
        return Student(**existing)

    fields = list(updates)
    set_clause = ", ".join(f"{field} = ${i + 2}" for i, field in enumerate(fields))
    try:
        async with db.pool().acquire() as conn:
            async with conn.transaction():
                row = await conn.fetchrow(
                    f"update students set {set_clause} where id = $1 returning *", student_id, *updates.values()
                )
                await money.audit(
                    conn, user.id, "student", student_id, "update",
                    before={f: existing[f] for f in fields}, after=updates,
                )
    except asyncpg.UniqueViolationError:
        raise duplicate_phone_error(await phone_owner(db.pool(), updates["phone"]))
    return Student(**row)
