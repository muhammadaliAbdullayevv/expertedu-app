from fastapi import APIRouter, Depends, HTTPException, status

from .. import db
from ..deps import CurrentUser, get_current_user
from ..phone import normalize
from ..schemas import CreateTeacherRequest, Teacher, TeacherListItem, UpdateTeacherRequest

router = APIRouter(prefix="/teachers", tags=["teachers"], dependencies=[Depends(get_current_user)])


def _clean_phone(phone: str | None) -> str | None:
    return normalize(phone) if phone and phone.strip() else None


@router.get("", response_model=list[TeacherListItem])
async def list_teachers(include_inactive: bool = False):
    where = "" if include_inactive else "where t.is_active"
    rows = await db.pool().fetch(
        f"""
        select t.*, count(g.id) filter (where g.is_active) as group_count
        from teachers t
        left join groups g on g.teacher_id = t.id
        {where}
        group by t.id
        order by t.full_name asc
        """
    )
    return [TeacherListItem(**row) for row in rows]


@router.post("", response_model=Teacher, status_code=status.HTTP_201_CREATED)
async def create_teacher(payload: CreateTeacherRequest, user: CurrentUser = Depends(get_current_user)):
    name = payload.full_name.strip()
    if not name:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Ism kiritilishi shart.")
    row = await db.pool().fetchrow(
        """
        insert into teachers (full_name, phone, note, created_by)
        values ($1, $2, $3, $4)
        returning *
        """,
        name,
        _clean_phone(payload.phone),
        payload.note,
        user.id,
    )
    return Teacher(**row)


@router.patch("/{teacher_id}", response_model=Teacher)
async def update_teacher(teacher_id: int, payload: UpdateTeacherRequest):
    existing = await db.pool().fetchrow("select * from teachers where id = $1", teacher_id)
    if existing is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "O'qituvchi topilmadi.")

    updates = payload.model_dump(exclude_unset=True)
    if not updates:
        return Teacher(**existing)
    if "full_name" in updates:
        if not (updates["full_name"] or "").strip():
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Ism kiritilishi shart.")
        updates["full_name"] = updates["full_name"].strip()
    if "is_active" in updates and updates["is_active"] is None:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "is_active bo'sh bo'lishi mumkin emas.")
    if "phone" in updates:
        updates["phone"] = _clean_phone(updates["phone"])

    fields = list(updates.keys())
    values = list(updates.values())
    set_clause = ", ".join(f"{field} = ${i + 2}" for i, field in enumerate(fields))
    row = await db.pool().fetchrow(
        f"update teachers set {set_clause} where id = $1 returning *", teacher_id, *values
    )
    return Teacher(**row)
