from fastapi import APIRouter, Depends, HTTPException, status

from .. import db
from ..deps import get_current_user
from ..schemas import CreateSubjectRequest, GroupWithStudentCount, Subject, SubjectWithCount

router = APIRouter(prefix="/subjects", tags=["subjects"], dependencies=[Depends(get_current_user)])


@router.get("", response_model=list[SubjectWithCount])
async def list_subjects():
    rows = await db.pool().fetch(
        """
        select s.id, s.name, s.created_at, count(g.id) as group_count
        from subjects s
        left join groups g on g.subject_id = s.id and g.is_active
        group by s.id
        order by s.name asc
        """
    )
    return [SubjectWithCount(**row) for row in rows]


@router.post("", response_model=Subject, status_code=status.HTTP_201_CREATED)
async def create_subject(payload: CreateSubjectRequest):
    existing = await db.pool().fetchval("select 1 from subjects where lower(name) = lower($1)", payload.name.strip())
    if existing:
        raise HTTPException(status.HTTP_409_CONFLICT, "Bu fan allaqachon mavjud.")
    row = await db.pool().fetchrow(
        "insert into subjects (name) values ($1) returning *", payload.name.strip()
    )
    return Subject(**row)


@router.get("/{subject_id}/groups", response_model=list[GroupWithStudentCount])
async def list_groups_for_subject(subject_id: int):
    rows = await db.pool().fetch(
        """
        select g.*, count(e.id) filter (where e.status = 'active') as student_count
        from groups g
        left join enrollments e on e.group_id = g.id
        where g.subject_id = $1 and g.is_active
        group by g.id
        order by g.name asc
        """,
        subject_id,
    )
    return [GroupWithStudentCount(**row) for row in rows]
