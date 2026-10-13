from fastapi import APIRouter, Depends, HTTPException, status

from .. import db
from ..deps import get_current_user
from ..phone import normalize
from ..schemas import CreateStudentRequest, Student, UpdateStudentRequest

router = APIRouter(prefix="/students", tags=["students"], dependencies=[Depends(get_current_user)])


@router.get("", response_model=list[Student])
async def list_students(q: str | None = None):
    if q:
        rows = await db.pool().fetch(
            "select * from students where full_name ilike $1 or phone ilike $1 order by full_name asc",
            f"%{q.strip()}%",
        )
    else:
        rows = await db.pool().fetch("select * from students order by full_name asc")
    return [Student(**row) for row in rows]


@router.post("", response_model=Student, status_code=status.HTTP_201_CREATED)
async def create_student(payload: CreateStudentRequest):
    row = await db.pool().fetchrow(
        """
        insert into students (full_name, phone, telegram_username, note)
        values ($1, $2, $3, $4)
        returning *
        """,
        payload.full_name.strip(),
        normalize(payload.phone),
        payload.telegram_username,
        payload.note,
    )
    return Student(**row)


@router.get("/{student_id}", response_model=Student)
async def get_student(student_id: int):
    row = await db.pool().fetchrow("select * from students where id = $1", student_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "O'quvchi topilmadi.")
    return Student(**row)


@router.patch("/{student_id}", response_model=Student)
async def update_student(student_id: int, payload: UpdateStudentRequest):
    existing = await db.pool().fetchrow("select * from students where id = $1", student_id)
    if existing is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "O'quvchi topilmadi.")

    updates = payload.model_dump(exclude_unset=True)
    if "phone" in updates:
        updates["phone"] = normalize(updates["phone"])
    if not updates:
        return Student(**existing)

    fields = list(updates.keys())
    values = list(updates.values())
    set_clause = ", ".join(f"{field} = ${i + 2}" for i, field in enumerate(fields))
    row = await db.pool().fetchrow(
        f"update students set {set_clause} where id = $1 returning *",
        student_id,
        *values,
    )
    return Student(**row)
