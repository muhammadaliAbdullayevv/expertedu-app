from datetime import date

from fastapi import APIRouter, Depends, HTTPException, status

from .. import db
from ..deps import get_current_user
from ..schemas import CreateEnrollmentRequest, Enrollment, StudentEnrollment

router = APIRouter(prefix="/enrollments", tags=["enrollments"], dependencies=[Depends(get_current_user)])


@router.post("", response_model=Enrollment, status_code=status.HTTP_201_CREATED)
async def create_enrollment(payload: CreateEnrollmentRequest):
    student = await db.pool().fetchval("select 1 from students where id = $1", payload.student_id)
    if not student:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "O'quvchi topilmadi.")
    group = await db.pool().fetchval("select 1 from groups where id = $1", payload.group_id)
    if not group:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Guruh topilmadi.")

    existing = await db.pool().fetchval(
        "select 1 from enrollments where student_id = $1 and group_id = $2 and status = 'active'",
        payload.student_id,
        payload.group_id,
    )
    if existing:
        raise HTTPException(status.HTTP_409_CONFLICT, "Bu o'quvchi allaqachon shu guruhda.")

    row = await db.pool().fetchrow(
        """
        insert into enrollments (student_id, group_id, joined_at)
        values ($1, $2, $3)
        returning *
        """,
        payload.student_id,
        payload.group_id,
        payload.joined_at,
    )
    return Enrollment(**row)


@router.post("/{enrollment_id}/withdraw", response_model=Enrollment)
async def withdraw_enrollment(enrollment_id: int):
    existing = await db.pool().fetchrow("select * from enrollments where id = $1", enrollment_id)
    if existing is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Yozilish topilmadi.")
    if existing["status"] == "withdrawn":
        return Enrollment(**existing)

    row = await db.pool().fetchrow(
        """
        update enrollments set status = 'withdrawn', ended_at = $2
        where id = $1
        returning *
        """,
        enrollment_id,
        date.today(),
    )
    return Enrollment(**row)


@router.get("/by-student/{student_id}", response_model=list[StudentEnrollment])
async def list_student_enrollments(student_id: int):
    rows = await db.pool().fetch(
        """
        select e.id as enrollment_id, e.group_id, g.name as group_name, e.joined_at, e.status
        from enrollments e
        join groups g on g.id = e.group_id
        where e.student_id = $1
        order by e.joined_at desc
        """,
        student_id,
    )
    return [StudentEnrollment(**row) for row in rows]
