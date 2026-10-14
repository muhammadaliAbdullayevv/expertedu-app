from fastapi import APIRouter, Depends, HTTPException, status

from .. import db
from ..deps import CurrentUser, get_current_user
from ..phone import normalize
from ..schemas import CreateInquiryRequest, Inquiry, Student, UpdateInquiryRequest

router = APIRouter(prefix="/inquiries", tags=["inquiries"], dependencies=[Depends(get_current_user)])

_SELECT = """
select i.*, s.name as subject_name
from inquiries i
left join subjects s on s.id = i.subject_id
"""


@router.get("", response_model=list[Inquiry])
async def list_inquiries(status_filter: str | None = None):
    if status_filter:
        rows = await db.pool().fetch(f"{_SELECT} where i.status = $1 order by i.created_at desc", status_filter)
    else:
        rows = await db.pool().fetch(f"{_SELECT} order by i.created_at desc")
    return [Inquiry(**row) for row in rows]


@router.post("", response_model=Inquiry, status_code=status.HTTP_201_CREATED)
async def create_inquiry(payload: CreateInquiryRequest, user: CurrentUser = Depends(get_current_user)):
    row = await db.pool().fetchrow(
        """
        insert into inquiries (full_name, phone, note, subject_id, trial_date, created_by)
        values ($1, $2, $3, $4, $5, $6)
        returning *, null as subject_name
        """,
        payload.full_name.strip(),
        normalize(payload.phone),
        payload.note,
        payload.subject_id,
        payload.trial_date,
        user.id,
    )
    if payload.subject_id is not None:
        subject_name = await db.pool().fetchval("select name from subjects where id = $1", payload.subject_id)
        row = dict(row)
        row["subject_name"] = subject_name
    return Inquiry(**row)


@router.patch("/{inquiry_id}", response_model=Inquiry)
async def update_inquiry(inquiry_id: int, payload: UpdateInquiryRequest):
    existing = await db.pool().fetchval("select 1 from inquiries where id = $1", inquiry_id)
    if not existing:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "So'rov topilmadi.")

    updates = payload.model_dump(exclude_unset=True)
    if updates:
        fields = list(updates.keys())
        values = list(updates.values())
        set_clause = ", ".join(f"{field} = ${i + 2}" for i, field in enumerate(fields))
        await db.pool().execute(f"update inquiries set {set_clause} where id = $1", inquiry_id, *values)

    row = await db.pool().fetchrow(f"{_SELECT} where i.id = $1", inquiry_id)
    return Inquiry(**row)


@router.post("/{inquiry_id}/convert", response_model=Student, status_code=status.HTTP_201_CREATED)
async def convert_inquiry(inquiry_id: int):
    """Turns an inquiry into a real Student record and marks it converted --
    used once someone has actually shown up and committed, rather than
    every logged call becoming a Student immediately."""
    inquiry = await db.pool().fetchrow("select * from inquiries where id = $1", inquiry_id)
    if inquiry is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "So'rov topilmadi.")
    if inquiry["converted_student_id"] is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, "Bu so'rov allaqachon talabaga aylantirilgan.")

    async with db.pool().acquire() as conn:
        async with conn.transaction():
            student = await conn.fetchrow(
                "insert into students (full_name, phone, note) values ($1, $2, $3) returning *",
                inquiry["full_name"],
                inquiry["phone"],
                inquiry["note"],
            )
            await conn.execute(
                "update inquiries set status = 'converted', converted_student_id = $2 where id = $1",
                inquiry_id,
                student["id"],
            )
    return Student(**student)
