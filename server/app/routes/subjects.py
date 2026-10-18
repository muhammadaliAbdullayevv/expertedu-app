from fastapi import APIRouter, Depends, HTTPException, status

from .. import db
from ..deps import Scope, get_current_user, get_scope
from ..scope import branch_filter
from ..schemas import CreateSubjectRequest, GroupWithStudentCount, Subject, SubjectWithCount

router = APIRouter(prefix="/subjects", tags=["subjects"], dependencies=[Depends(get_current_user)])


@router.get("", response_model=list[SubjectWithCount])
async def list_subjects(scope: Scope = Depends(get_scope)):
    """Courses are shared by every branch; the group count is the branch in view's."""
    rows = await db.pool().fetch(
        f"""
        select s.id, s.name, s.created_at, count(g.id) as group_count
        from subjects s
        left join groups g on g.subject_id = s.id and g.is_active and {branch_filter('g.branch_id', 1)}
        group by s.id
        order by s.name asc
        """,
        scope.ids,
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
async def list_groups_for_subject(subject_id: int, scope: Scope = Depends(get_scope)):
    rows = await db.pool().fetch(
        f"""
        select g.*, t.full_name as teacher_name, b.name as branch_name,
               count(e.id) filter (where e.status = 'active') as student_count
        from groups g
        left join teachers t on t.id = g.teacher_id
        left join branches b on b.id = g.branch_id
        left join enrollments e on e.group_id = g.id
        where g.subject_id = $1 and g.is_active and {branch_filter('g.branch_id', 2)}
        group by g.id, t.full_name, b.name
        order by g.name asc
        """,
        subject_id,
        scope.ids,
    )
    return [GroupWithStudentCount(**row) for row in rows]
