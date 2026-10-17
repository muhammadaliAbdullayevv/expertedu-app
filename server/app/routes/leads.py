"""Leads: people who asked about a course. A lead is never a student and
never in a group until POST /leads/{id}/enroll -- the one explicit
enrollment step, done once per lead however many times it's retried.
"""

from uuid import UUID

import asyncpg
from fastapi import APIRouter, Depends, Header, HTTPException, Query, status

from .. import admissions, db, idempotency
from ..deps import CurrentUser, get_current_user
from ..money import service as money
from ..phone import is_valid_uzbek_phone, normalize
from ..schemas import (
    ChangeLeadStageRequest,
    CreateInteractionRequest,
    CreateLeadRequest,
    CreateTrialSessionRequest,
    DuplicateCheck,
    SimilarLead,
    EnrollLeadRequest,
    Lead,
    LeadDetail,
    LeadEnrolled,
    LeadInteraction,
    LeadPage,
    UndoLeadRequest,
    UndoLeadResult,
    PhoneLookup,
    Student,
    UpdateLeadRequest,
)
from .enrollments import enroll
from .follow_ups import fetch_tasks
from .students import PAYMENT_METHODS, heard_from_value, optional_phone, phone_owner, valid_phone
from .groups import upcoming_trial_dates
from .trials import add_trial_reminder, book, create_session, fetch_bookings

router = APIRouter(prefix="/leads", tags=["leads"], dependencies=[Depends(get_current_user)])

_FIELD_LABELS = {
    "full_name": "Ism",
    "phone": "Telefon",
    "parent_phone": "Ota-ona telefoni",
    "subject_id": "Fan",
    "source": "Manba",
    "note": "Izoh",
    "assigned_to": "Mas'ul",
    "preferred_trial_date": "Sinov uchun qulay sana",
    "desired_weekdays": "Qulay kunlar",
    "desired_time_of_day": "Qulay vaqt",
    "level": "Daraja",
}


async def fetch_lead(conn, lead_id: int, *, merged: bool = False) -> Lead:
    row = await conn.fetchrow(f"{admissions.LEAD_SELECT} where l.id = $1", lead_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "So'rov topilmadi.")
    return Lead(**row, merged=merged)


TIMES_OF_DAY = ("morning", "afternoon", "evening")


def _desired(weekdays: list[int] | None, time_of_day: str | None, level: str | None):
    """The cleaned (weekdays, time of day, level) a client asked for."""
    if weekdays is not None:
        if any(not 1 <= day <= 7 for day in weekdays):
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Hafta kunlari 1 dan 7 gacha bo'lishi kerak.")
        weekdays = sorted(set(weekdays)) or None
    if time_of_day is not None and time_of_day not in TIMES_OF_DAY:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Qulay vaqt noto'g'ri.")
    return weekdays, time_of_day, (level or "").strip() or None


def _source(value: str | None) -> str | None:
    if value is not None and value not in admissions.SOURCES:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Manba noto'g'ri.")
    return value


async def _require_subject(conn, subject_id: int | None) -> None:
    if subject_id is not None and not await conn.fetchval("select 1 from subjects where id = $1", subject_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Fan topilmadi.")


async def _require_user(conn, user_id: int | None) -> None:
    if user_id is not None and not await conn.fetchval(
        "select 1 from users where id = $1 and is_active", user_id
    ):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Mas'ul xodim topilmadi.")


async def lock_phone(conn, phone: str) -> None:
    """Serializes everything that decides whether a phone already has an
    open lead, so two operators taking calls from the same number at the
    same moment can't both open one."""
    await conn.execute("select pg_advisory_xact_lock(hashtext('lead-phone:' || $1::text))", phone)


async def open_lead_for(conn, phone: str, subject_id: int | None, *, exclude_id: int | None = None):
    return await conn.fetchrow(
        """
        select l.*, s.name as subject_name
        from leads l left join subjects s on s.id = l.subject_id
        where l.phone = $1 and coalesce(l.subject_id, 0) = coalesce($2::bigint, 0)
          and l.stage = any($3::text[]) and l.id is distinct from $4
        """,
        phone,
        subject_id,
        list(admissions.OPEN_STAGES),
        exclude_id,
    )


def duplicate_lead_error(existing) -> HTTPException:
    subject = existing["subject_name"] or "fan tanlanmagan"
    return HTTPException(
        status.HTTP_409_CONFLICT,
        f"Bu raqam bilan ochiq so'rov bor: {existing['full_name']} ({subject}). Yangisini ochmasdan o'shani davom ettiring.",
    )


@router.get("", response_model=LeadPage)
async def list_leads(
    q: str | None = None,
    stage: list[str] | None = Query(default=None),
    scope: str = "open",
    assigned_to: int | None = None,
    subject_id: int | None = None,
    group_id: int | None = None,
    groupless: bool = False,
    with_trial: bool = False,
    archive: bool = False,
    limit: int = Query(default=100, ge=1, le=500),
    offset: int = Query(default=0, ge=0),
):
    """scope: 'open' (default), 'closed' (incl. enrolled) or 'all'; an
    explicit stage list overrides it. q matches name or phone digits.

    Qabul's list: group_id / groupless pick the group, with_trial keeps the
    people with a booked trial, archive shows the archived ones (closed, not
    enrolled) instead of the open ones."""
    conditions: list[str] = []
    args: list = []

    def arg(value) -> str:
        args.append(value)
        return f"${len(args)}"

    if archive:
        conditions.append(f"l.stage = any({arg(list(admissions.CLOSED_STAGES))}::text[])")
    elif stage:
        unknown = set(stage) - set(admissions.ALL_STAGES)
        if unknown:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Bosqich noto'g'ri.")
        conditions.append(f"l.stage = any({arg(stage)}::text[])")
    elif scope == "open":
        conditions.append(f"l.stage = any({arg(list(admissions.OPEN_STAGES))}::text[])")
    elif scope == "closed":
        conditions.append(f"not (l.stage = any({arg(list(admissions.OPEN_STAGES))}::text[]))")
    elif scope != "all":
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "scope noto'g'ri.")
    if q and q.strip():
        term = q.strip()
        digits = "".join(ch for ch in term if ch.isdigit())
        name_like = arg(f"%{term}%")
        if digits:
            conditions.append(f"(l.full_name ilike {name_like} or l.phone like {arg(f'%{digits}%')})")
        else:
            conditions.append(f"l.full_name ilike {name_like}")
    if assigned_to is not None:
        conditions.append(f"l.assigned_to = {arg(assigned_to)}")
    if subject_id is not None:
        conditions.append(f"l.subject_id = {arg(subject_id)}")
    if groupless:
        conditions.append("l.group_id is null")
    elif group_id is not None:
        conditions.append(f"l.group_id = {arg(group_id)}")
    if with_trial:
        conditions.append(
            "exists (select 1 from trial_bookings b where b.lead_id = l.id and b.status = 'scheduled')"
        )

    where = f"where {' and '.join(conditions)}" if conditions else ""
    async with db.pool().acquire() as conn:
        total = await conn.fetchval(f"select count(*) from leads l {where}", *args)
        rows = await conn.fetch(
            f"{admissions.LEAD_SELECT} {where} order by l.created_at desc, l.id desc "
            f"limit {arg(limit)} offset {arg(offset)}",
            *args,
        )
    return LeadPage(items=[Lead(**row) for row in rows], total=total)


def _name_key(name: str) -> str:
    return " ".join(name.lower().split())


# Declared before "/{lead_id}" so the path isn't read as an id.
@router.get("/duplicates", response_model=DuplicateCheck)
async def check_duplicates(phone: str = "", full_name: str = ""):
    """The warning under the Qabul form: who already has this phone, or exactly
    this name (a name counts once it has two words). Never blocks anything."""
    normalized = normalize(phone)
    name = _name_key(full_name)
    check = DuplicateCheck()
    async with db.pool().acquire() as conn:

        async def open_leads(where: str, *args) -> list[SimilarLead]:
            rows = await conn.fetch(
                f"{admissions.LEAD_SELECT} where l.stage = any($1::text[]) and {where} "
                "order by l.created_at desc limit 5",
                list(admissions.OPEN_STAGES),
                *args,
            )
            return [
                SimilarLead(
                    id=r["id"], full_name=r["full_name"], phone=r["phone"], group_name=r["group_name"],
                    subject_name=r["subject_name"], created_at=r["created_at"],
                )
                for r in rows
            ]

        if is_valid_uzbek_phone(normalized):
            check.phone_student = await phone_owner(conn, normalized)
            check.phone_leads = await open_leads("l.phone = $2", normalized)
        if len(name.split()) >= 2:
            students = await conn.fetch(
                "select phone from students where lower(regexp_replace(trim(full_name), '\\s+', ' ', 'g')) = $1 limit 5",
                name,
            )
            for row in students:
                owner = await phone_owner(conn, row["phone"])
                if owner is not None and (check.phone_student is None or owner.student_id != check.phone_student.student_id):
                    check.name_students.append(owner)
            check.name_leads = [
                lead
                for lead in await open_leads(
                    "lower(regexp_replace(trim(l.full_name), '\\s+', ' ', 'g')) = $2", name
                )
                if lead.phone != normalized
            ]
    return check


@router.get("/lookup", response_model=PhoneLookup)
async def lookup_phone(phone: str):
    """Step 1 of "Yangi so'rov": who is this number already? An incomplete
    number simply matches nothing."""
    normalized = normalize(phone)
    if not is_valid_uzbek_phone(normalized):
        return PhoneLookup(phone=normalized, student=None, leads=[])
    async with db.pool().acquire() as conn:
        rows = await conn.fetch(
            f"{admissions.LEAD_SELECT} where l.phone = $1 order by l.created_at desc", normalized
        )
        return PhoneLookup(
            phone=normalized, student=await phone_owner(conn, normalized), leads=[Lead(**row) for row in rows]
        )


async def create_lead(conn, payload: CreateLeadRequest, user: CurrentUser) -> Lead:
    full_name = payload.full_name.strip()
    if not full_name:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Ism kiritilishi shart.")
    phone = valid_phone(payload.phone)
    parent_phone = optional_phone(payload.parent_phone, "Ota-ona telefoni")
    source = _source(payload.source)
    note = (payload.note or "").strip() or None
    if payload.on_duplicate not in ("reject", "merge"):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "on_duplicate noto'g'ri.")
    group = None
    subject_id = payload.subject_id
    if payload.group_id is not None:
        group = await conn.fetchrow("select id, subject_id, is_active from groups where id = $1", payload.group_id)
        if group is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Guruh topilmadi.")
        if not group["is_active"]:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Bu guruh faol emas.")
        subject_id = subject_id or group["subject_id"]
    if payload.trial_starts_at is not None and group is None:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Sinov darsi uchun guruhni tanlang.")
    await _require_subject(conn, subject_id)
    assigned_to = payload.assigned_to if payload.assigned_to is not None else user.id
    await _require_user(conn, assigned_to)
    weekdays, time_of_day, level = _desired(payload.desired_weekdays, payload.desired_time_of_day, payload.level)

    if payload.client_id is not None:
        existing_id = await conn.fetchval("select id from leads where client_id = $1", payload.client_id)
        if existing_id is not None:
            return await fetch_lead(conn, existing_id)

    await lock_phone(conn, phone)
    existing = await open_lead_for(conn, phone, subject_id)
    if existing is not None:
        if payload.on_duplicate == "reject":
            raise duplicate_lead_error(existing)
        body = "Qayta murojaat qildi"
        if note:
            body += f": {note}"
        await admissions.log(conn, existing["id"], body, user_id=user.id, kind="call_in")
        if group is not None:
            await conn.execute(
                "update leads set group_id = $2, version = version + 1, updated_at = now() where id = $1",
                existing["id"],
                group["id"],
            )
        await _book_group_trial(conn, existing["id"], payload, user)
        return await fetch_lead(conn, existing["id"], merged=True)

    # The contact: an existing student with this phone is linked, not copied.
    student_id = await conn.fetchval("select id from students where phone = $1", phone)
    try:
        async with conn.transaction():
            lead_id = await conn.fetchval(
                """
                insert into leads
                    (client_id, full_name, phone, parent_phone, subject_id, source, note, assigned_to,
                     preferred_trial_date, student_id, created_by, desired_weekdays, desired_time_of_day, level,
                     group_id, address)
                values (coalesce($1, gen_random_uuid()), $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16)
                returning id
                """,
                payload.client_id,
                full_name,
                phone,
                parent_phone,
                subject_id,
                source,
                note,
                assigned_to,
                payload.preferred_trial_date,
                student_id,
                user.id,
                weekdays,
                time_of_day,
                level,
                group["id"] if group else None,
                (payload.address or "").strip() or None,
            )
    except asyncpg.UniqueViolationError:
        # The phone lock above should make this unreachable; the index is
        # the backstop.
        raise HTTPException(status.HTTP_409_CONFLICT, "Bu raqam bilan ochiq so'rov bor. Ro'yxatni yangilang.")
    await admissions.log(conn, lead_id, "So'rov yaratildi", user_id=user.id, new_stage="new")
    await _book_group_trial(conn, lead_id, payload, user)
    return await fetch_lead(conn, lead_id)


async def _book_group_trial(conn, lead_id: int, payload: CreateLeadRequest, user: CurrentUser) -> None:
    """The optional free trial of the fast form: a guest seat at one of the
    group's next lessons. Done in the same transaction as the lead, so a
    refused trial (full, second trial) saves nothing and the form can say so."""
    if payload.trial_starts_at is None:
        return
    dates = await upcoming_trial_dates(conn, payload.group_id, 10)
    lesson = next((d for d in dates if d.starts_at == payload.trial_starts_at), None)
    if lesson is None:
        raise HTTPException(status.HTTP_409_CONFLICT, "Bu dars endi mavjud emas. Boshqa sanani tanlang.")
    session_id = await conn.fetchval(
        "select id from trial_sessions where group_id = $1 and starts_at = $2 and status = 'scheduled'",
        payload.group_id,
        lesson.starts_at,
    )
    if session_id is None:
        session_id = await create_session(
            conn,
            CreateTrialSessionRequest(
                kind="group_lesson",
                group_id=payload.group_id,
                starts_at=lesson.starts_at,
                ends_at=lesson.ends_at,
                capacity=lesson.suggested_capacity,
            ),
            user.id,
        )
    await book(conn, lead_id=lead_id, session_id=session_id, user_id=user.id, is_owner=user.role == "owner")
    if payload.remind:
        await add_trial_reminder(conn, lead_id, session_id, user.id)


@router.post("", response_model=Lead, status_code=status.HTTP_201_CREATED)
async def create_lead_route(
    payload: CreateLeadRequest,
    user: CurrentUser = Depends(get_current_user),
    idempotency_key: UUID | None = Header(default=None),
):
    """Creates a lead -- no student, no enrollment, no charge."""

    async def work(conn):
        return await create_lead(conn, payload, user)

    return await idempotency.run(key=idempotency_key, user=user, endpoint="POST /leads", payload=payload, work=work)


@router.post("/undo", response_model=UndoLeadResult)
async def undo_lead(payload: UndoLeadRequest, user: CurrentUser = Depends(get_current_user)):
    """"Qaytarish" right after a save: archives the lead that save created
    (found by its client_id), cancelling its trial. Nothing is deleted. A save
    that was folded into an existing lead created nothing, so there is nothing
    to undo and that lead is left alone."""
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            lead_id = await conn.fetchval("select id from leads where client_id = $1", payload.client_id)
            if lead_id is None:
                return UndoLeadResult(undone=False)
            lead = await admissions.lock_lead(conn, lead_id)
            if lead["stage"] not in admissions.OPEN_STAGES:
                return UndoLeadResult(undone=False, lead=await fetch_lead(conn, lead_id))
            await move_to_stage(conn, lead, "not_interested", user=user, reason="Qaytarildi")
            return UndoLeadResult(undone=True, lead=await fetch_lead(conn, lead_id))


@router.get("/{lead_id}", response_model=LeadDetail)
async def get_lead(lead_id: int):
    """The lead with its whole history -- kept after it's enrolled."""
    async with db.pool().acquire() as conn:
        lead = await fetch_lead(conn, lead_id)
        interactions = await conn.fetch(
            """
            select i.*, u.full_name as created_by_name
            from lead_interactions i left join users u on u.id = i.created_by
            where i.lead_id = $1
            order by i.created_at desc, i.id desc
            """,
            lead_id,
        )
        return LeadDetail(
            lead=lead,
            interactions=[LeadInteraction(**row) for row in interactions],
            bookings=list(reversed(await fetch_bookings(conn, "where b.lead_id = $1", lead_id))),
            tasks=await fetch_tasks(conn, "where t.lead_id = $1", lead_id),
            student=await phone_owner(conn, lead.phone),
        )


@router.patch("/{lead_id}", response_model=Lead)
async def update_lead(lead_id: int, payload: UpdateLeadRequest, user: CurrentUser = Depends(get_current_user)):
    changes = payload.model_dump(exclude_unset=True)
    changes.pop("version")
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            lead = await admissions.lock_lead(conn, lead_id)
            admissions.check_version(lead["version"], payload.version)
            if lead["stage"] == "enrolled":
                raise HTTPException(status.HTTP_409_CONFLICT, "O'quvchi bo'lgan so'rovni o'zgartirib bo'lmaydi.")

            if "full_name" in changes:
                changes["full_name"] = (changes["full_name"] or "").strip()
                if not changes["full_name"]:
                    raise HTTPException(status.HTTP_400_BAD_REQUEST, "Ism kiritilishi shart.")
            if "phone" in changes:
                changes["phone"] = valid_phone(changes["phone"])
            if "parent_phone" in changes:
                changes["parent_phone"] = optional_phone(changes["parent_phone"], "Ota-ona telefoni")
            if "source" in changes:
                _source(changes["source"])
            if "note" in changes:
                changes["note"] = (changes["note"] or "").strip() or None
            if "subject_id" in changes:
                await _require_subject(conn, changes["subject_id"])
            if "assigned_to" in changes:
                await _require_user(conn, changes["assigned_to"])
            if {"desired_weekdays", "desired_time_of_day", "level"} & changes.keys():
                days, time_of_day, level = _desired(
                    changes.get("desired_weekdays", lead["desired_weekdays"]),
                    changes.get("desired_time_of_day", lead["desired_time_of_day"]),
                    changes.get("level", lead["level"]),
                )
                for field, value in (("desired_weekdays", days), ("desired_time_of_day", time_of_day), ("level", level)):
                    if field in changes:
                        changes[field] = value

            changes = {field: value for field, value in changes.items() if value != lead[field]}
            if not changes:
                return await fetch_lead(conn, lead_id)

            if ("phone" in changes or "subject_id" in changes) and lead["stage"] in admissions.OPEN_STAGES:
                phone = changes.get("phone", lead["phone"])
                await lock_phone(conn, phone)
                existing = await open_lead_for(
                    conn, phone, changes.get("subject_id", lead["subject_id"]), exclude_id=lead_id
                )
                if existing is not None:
                    raise duplicate_lead_error(existing)
            if "phone" in changes:
                changes["student_id"] = await conn.fetchval(
                    "select id from students where phone = $1", changes["phone"]
                )

            fields = list(changes)
            set_clause = ", ".join(f"{field} = ${i + 2}" for i, field in enumerate(fields))
            await conn.execute(
                f"update leads set {set_clause}, version = version + 1, updated_at = now() where id = $1",
                lead_id,
                *changes.values(),
            )
            labels = [_FIELD_LABELS[field] for field in fields if field in _FIELD_LABELS]
            await admissions.log(conn, lead_id, f"O'zgartirildi: {', '.join(labels)}", user_id=user.id)
            return await fetch_lead(conn, lead_id)


async def move_to_stage(
    conn, lead: dict, stage: str, *, user: CurrentUser, reason: str | None = None, follow_up_at=None
) -> None:
    """A stage picked by hand, on a locked lead. Closing a lead cancels its
    booked trial and open tasks (kept, marked cancelled); reopening is a
    move from a closed stage back to an open one."""
    if stage not in admissions.MANUAL_STAGES:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Bu bosqichni qo'lda tanlab bo'lmaydi.")
    if lead["stage"] == "enrolled":
        raise HTTPException(status.HTTP_409_CONFLICT, "O'quvchi bo'lgan so'rovni o'zgartirib bo'lmaydi.")
    if stage == "follow_up_later" and follow_up_at is None:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Qachon bog'lanishni tanlang.")
    lead_id = lead["id"]

    if lead["stage"] in admissions.CLOSED_STAGES and stage in admissions.OPEN_STAGES:
        await lock_phone(conn, lead["phone"])
        existing = await open_lead_for(conn, lead["phone"], lead["subject_id"], exclude_id=lead_id)
        if existing is not None:
            raise duplicate_lead_error(existing)

    if stage in admissions.CLOSED_STAGES:
        bookings = await conn.fetch(
            "select id from trial_bookings where lead_id = $1 and status = 'scheduled' for update", lead_id
        )
        for booking in bookings:
            await conn.execute(
                "update trial_bookings set status = 'cancelled', cancel_reason = 'So''rov yopildi', "
                "version = version + 1, updated_at = now() where id = $1",
                booking["id"],
            )
            await admissions.log(
                conn, lead_id, "Sinov bekor qilindi: so'rov yopildi", user_id=user.id, booking_id=booking["id"]
            )
        await conn.execute(
            "update follow_up_tasks set status = 'cancelled', completed_at = now(), completed_by = $2, "
            "version = version + 1 where lead_id = $1 and status = 'open'",
            lead_id,
            user.id,
        )

    await admissions.set_stage(conn, lead, stage, user_id=user.id, reason=reason)
    if stage == "follow_up_later":
        lead = await admissions.lock_lead(conn, lead_id)
        await admissions.add_task(
            conn, lead, reason or "Qayta bog'lanish", admissions.aware(follow_up_at), user_id=user.id
        )


@router.post("/{lead_id}/stage", response_model=Lead)
async def change_stage(lead_id: int, payload: ChangeLeadStageRequest, user: CurrentUser = Depends(get_current_user)):
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            lead = await admissions.lock_lead(conn, lead_id)
            admissions.check_version(lead["version"], payload.version)
            await move_to_stage(
                conn,
                lead,
                payload.stage,
                user=user,
                reason=(payload.reason or "").strip() or None,
                follow_up_at=payload.follow_up_at,
            )
            return await fetch_lead(conn, lead_id)


@router.post("/{lead_id}/interactions", response_model=LeadInteraction, status_code=status.HTTP_201_CREATED)
async def add_interaction(
    lead_id: int,
    payload: CreateInteractionRequest,
    user: CurrentUser = Depends(get_current_user),
    idempotency_key: UUID | None = Header(default=None),
):
    """Logs a call, message, visit or note. The first real contact with a
    new lead moves it to 'contacted'."""
    if payload.kind not in admissions.INTERACTION_KINDS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Turi noto'g'ri.")
    body = payload.body.strip()
    if not body:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Matnni yozing.")

    async def work(conn):
        lead = await admissions.lock_lead(conn, lead_id)
        interaction_id = await conn.fetchval(
            "insert into lead_interactions (lead_id, kind, body, created_by) values ($1, $2, $3, $4) returning id",
            lead_id,
            payload.kind,
            body,
            user.id,
        )
        if lead["stage"] == "new" and payload.kind != "note":
            await admissions.set_stage(conn, lead, "contacted", user_id=user.id)
        row = await conn.fetchrow(
            """
            select i.*, u.full_name as created_by_name
            from lead_interactions i left join users u on u.id = i.created_by
            where i.id = $1
            """,
            interaction_id,
        )
        return LeadInteraction(**row)

    return await idempotency.run(
        key=idempotency_key, user=user, endpoint=f"POST /leads/{lead_id}/interactions", payload=payload, work=work
    )


@router.post("/{lead_id}/enroll", response_model=LeadEnrolled, status_code=status.HTTP_201_CREATED)
async def enroll_lead(
    lead_id: int,
    payload: EnrollLeadRequest,
    user: CurrentUser = Depends(get_current_user),
    idempotency_key: UUID | None = Header(default=None),
):
    """The explicit "Guruhga yozish" step. In one transaction: reuse the
    student who has this phone (or create one), enroll them with the first
    charge, record the optional first payment, and link it all to the lead.
    A failure anywhere undoes all of it. A retry with the same
    Idempotency-Key -- required here -- returns the first result."""
    if idempotency_key is None:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Idempotency-Key sarlavhasi kerak.")
    first_payment = payload.first_payment_amount or 0
    if first_payment < 0:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "To'lov summasi manfiy bo'lishi mumkin emas.")
    if first_payment and payload.first_payment_method not in PAYMENT_METHODS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "To'lov usulini tanlang.")

    async def work(conn):
        lead = await admissions.lock_lead(conn, lead_id)
        if lead["stage"] == "enrolled":
            raise HTTPException(status.HTTP_409_CONFLICT, "Bu so'rov bo'yicha o'quvchi allaqachon yozilgan.")

        phone = valid_phone(payload.phone)
        student = None
        if lead["student_id"] is not None:
            student = await conn.fetchrow("select * from students where id = $1", lead["student_id"])
        if student is None:
            student = await conn.fetchrow("select * from students where phone = $1", phone)
        reused = student is not None
        if student is None:
            full_name = payload.full_name.strip()
            if not full_name:
                raise HTTPException(status.HTTP_400_BAD_REQUEST, "F.I.Sh. kiritilishi shart.")
            try:
                async with conn.transaction():
                    student = await conn.fetchrow(
                        """
                        insert into students (full_name, phone, note, parent_phone, heard_from, created_by, address)
                        values ($1, $2, $3, $4, $5, $6, $7)
                        returning *
                        """,
                        full_name,
                        phone,
                        (payload.note or "").strip() or None,
                        optional_phone(payload.parent_phone or lead["parent_phone"], "Ota-ona telefoni"),
                        heard_from_value(payload.heard_from or lead["source"]),
                        user.id,
                        lead["address"],
                    )
            except asyncpg.UniqueViolationError:
                # Someone saved a student with this phone a moment ago.
                student = await conn.fetchrow("select * from students where phone = $1", phone)
                reused = True

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

        # Whatever was still pending for the prospect is done now.
        scheduled = await conn.fetch(
            "select id from trial_bookings where lead_id = $1 and status = 'scheduled' for update", lead_id
        )
        for booking in scheduled:
            await conn.execute(
                "update trial_bookings set status = 'cancelled', cancel_reason = 'O''quvchi bo''ldi', "
                "version = version + 1, updated_at = now() where id = $1",
                booking["id"],
            )
        await conn.execute(
            "update follow_up_tasks set status = 'cancelled', completed_at = now(), completed_by = $2, "
            "version = version + 1 where lead_id = $1 and status = 'open'",
            lead_id,
            user.id,
        )

        group_name = await conn.fetchval("select name from groups where id = $1", payload.group_id)
        await conn.execute(
            """
            update leads
            set stage = 'enrolled', student_id = $2, enrollment_id = $3, enrolled_at = now(),
                closed_at = now(), version = version + 1, updated_at = now()
            where id = $1
            """,
            lead_id,
            student["id"],
            enrollment["id"],
        )
        await admissions.log(
            conn,
            lead_id,
            f"Guruhga yozildi: {group_name}, {payload.joined_at.strftime('%d.%m.%Y')}",
            user_id=user.id,
            old_stage=lead["stage"],
            new_stage="enrolled",
        )
        return LeadEnrolled(
            lead_id=lead_id,
            student=Student(**student),
            reused_student=reused,
            enrollment_id=enrollment["id"],
            first_charge=first_charge,
            first_payment=first_payment,
        )

    return await idempotency.run(
        key=idempotency_key, user=user, endpoint=f"POST /leads/{lead_id}/enroll", payload=payload, work=work
    )
