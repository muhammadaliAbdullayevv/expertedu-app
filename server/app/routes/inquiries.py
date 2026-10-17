"""The pre-admissions inquiries API, kept for app builds older than 1.7
(phones update on their own schedule). It reads and writes leads -- see
routes/leads.py -- through the old shape:

    status 'new'       <- stage new
           'contacted' <- contacted, decision_pending, follow_up_later
           'scheduled' <- trial_scheduled, trial_completed
           'converted' <- enrolled
           'lost'      <- not_interested, unreachable

Old builds can't book a real trial (that needs a time and a teacher), so
their "Sinovga yozildi" leaves a task to book one instead; and their
"convert" -- which made a student with no group -- is refused, since only
the explicit enrollment step may turn a lead into a student now.
"""

from fastapi import APIRouter, Depends, HTTPException, status

from .. import admissions, db
from ..config import settings
from ..deps import CurrentUser, get_current_user
from ..schemas import CreateInquiryRequest, CreateLeadRequest, Inquiry, UpdateInquiryRequest
from .leads import duplicate_lead_error, lock_phone, open_lead_for, create_lead, move_to_stage

router = APIRouter(prefix="/inquiries", tags=["inquiries"], dependencies=[Depends(get_current_user)])

_LEGACY_STAGES = {
    "new": ("new",),
    "contacted": ("contacted", "decision_pending", "follow_up_later"),
    "scheduled": ("trial_scheduled", "trial_completed"),
    "converted": ("enrolled",),
    "lost": admissions.CLOSED_STAGES,
}

_SELECT = """
select l.id, l.full_name, l.phone, l.note, l.subject_id, s.name as subject_name, l.created_at,
       coalesce((nt.starts_at at time zone $1)::date, l.preferred_trial_date) as trial_date,
       case
         when l.stage = 'new' then 'new'
         when l.stage in ('trial_scheduled', 'trial_completed') then 'scheduled'
         when l.stage = 'enrolled' then 'converted'
         when l.stage in ('not_interested', 'unreachable') then 'lost'
         else 'contacted'
       end as status,
       case when l.stage = 'enrolled' then l.student_id end as converted_student_id
from leads l
left join subjects s on s.id = l.subject_id
left join lateral (
  select ts.starts_at from trial_bookings b join trial_sessions ts on ts.id = b.session_id
  where b.lead_id = l.id and b.status = 'scheduled' limit 1
) nt on true
"""


async def _fetch(conn, lead_id: int) -> Inquiry:
    row = await conn.fetchrow(f"{_SELECT} where l.id = $2", settings.center_timezone, lead_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "So'rov topilmadi.")
    return Inquiry(**row)


@router.get("", response_model=list[Inquiry])
async def list_inquiries(status_filter: str | None = None):
    async with db.pool().acquire() as conn:
        if status_filter:
            if status_filter not in _LEGACY_STAGES:
                return []
            rows = await conn.fetch(
                f"{_SELECT} where l.stage = any($2::text[]) order by l.created_at desc",
                settings.center_timezone,
                list(_LEGACY_STAGES[status_filter]),
            )
        else:
            rows = await conn.fetch(f"{_SELECT} order by l.created_at desc", settings.center_timezone)
    return [Inquiry(**row) for row in rows]


@router.post("", response_model=Inquiry, status_code=status.HTTP_201_CREATED)
async def create_inquiry(payload: CreateInquiryRequest, user: CurrentUser = Depends(get_current_user)):
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            lead = await create_lead(
                conn,
                CreateLeadRequest(
                    full_name=payload.full_name,
                    phone=payload.phone,
                    note=payload.note,
                    subject_id=payload.subject_id,
                    preferred_trial_date=payload.trial_date,
                ),
                user,
            )
            return await _fetch(conn, lead.id)


@router.patch("/{inquiry_id}", response_model=Inquiry)
async def update_inquiry(inquiry_id: int, payload: UpdateInquiryRequest, user: CurrentUser = Depends(get_current_user)):
    changes = payload.model_dump(exclude_unset=True)
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            lead = await admissions.lock_lead(conn, inquiry_id)
            if lead["stage"] == "enrolled":
                raise HTTPException(status.HTTP_409_CONFLICT, "O'quvchi bo'lgan so'rovni o'zgartirib bo'lmaydi.")

            fields = {}
            if "note" in changes:
                fields["note"] = (changes["note"] or "").strip() or None
            if "subject_id" in changes:
                fields["subject_id"] = changes["subject_id"]
            if "trial_date" in changes:
                fields["preferred_trial_date"] = changes["trial_date"]
            fields = {field: value for field, value in fields.items() if value != lead[field]}
            if "subject_id" in fields and lead["stage"] in admissions.OPEN_STAGES:
                await lock_phone(conn, lead["phone"])
                existing = await open_lead_for(conn, lead["phone"], fields["subject_id"], exclude_id=inquiry_id)
                if existing is not None:
                    raise duplicate_lead_error(existing)
            if fields:
                set_clause = ", ".join(f"{field} = ${i + 2}" for i, field in enumerate(fields))
                await conn.execute(
                    f"update leads set {set_clause}, version = version + 1, updated_at = now() where id = $1",
                    inquiry_id,
                    *fields.values(),
                )
                await admissions.log(conn, inquiry_id, "O'zgartirildi (eski ilova)", user_id=user.id)
                lead = await admissions.lock_lead(conn, inquiry_id)

            legacy_status = changes.get("status")
            if legacy_status in ("contacted", "scheduled"):
                if lead["stage"] == "new" or lead["stage"] in admissions.CLOSED_STAGES:
                    await move_to_stage(conn, lead, "contacted", user=user)
                    lead = await admissions.lock_lead(conn, inquiry_id)
                if legacy_status == "scheduled" and lead["stage"] not in ("trial_scheduled", "trial_completed"):
                    await admissions.add_task(
                        conn, lead, "Sinov darsini rejalashtiring (eski ilovadan)", admissions.tomorrow_morning(),
                        user_id=user.id,
                    )
            elif legacy_status == "lost":
                await move_to_stage(conn, lead, "not_interested", user=user)
            elif legacy_status is not None:
                raise HTTPException(status.HTTP_400_BAD_REQUEST, "Bu holatni tanlab bo'lmaydi.")
            return await _fetch(conn, inquiry_id)


@router.post("/{inquiry_id}/convert", status_code=status.HTTP_410_GONE)
async def convert_inquiry(inquiry_id: int):
    raise HTTPException(
        status.HTTP_410_GONE,
        "Ilovani yangilang: o'quvchi endi kompyuterdagi \"Guruhga yozish\" orqali qo'shiladi.",
    )
