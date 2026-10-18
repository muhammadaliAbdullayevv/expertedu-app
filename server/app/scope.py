"""Branch scope helpers (docs/BRANCHES.md).

Every route that touches branch data builds its SQL with these, so one rule
is written once: a record outside the request's scope does not exist -- the
answer is the same 404 as for a record that was never there.

`n` is the position of the scope's id list among the query's parameters; pass
`scope.ids` there (None = every branch)."""

from fastapi import HTTPException, status

from .deps import Scope, ambient_scope


def branch_filter(col: str, n: int) -> str:
    """`col` (a branch_id column) is in the scope."""
    return f"(${n}::bigint[] is null or {col} = any(${n}::bigint[]))"


def student_filter(alias: str, n: int) -> str:
    """The student `alias` is linked to a branch in the scope."""
    return (
        f"exists (select 1 from student_branches sb_ where sb_.student_id = {alias}.id "
        f"and (${n}::bigint[] is null or sb_.branch_id = any(${n}::bigint[])))"
    )


def teacher_filter(alias: str, n: int) -> str:
    """The teacher `alias` works in a branch in the scope."""
    return (
        f"exists (select 1 from teacher_branches tb_ where tb_.teacher_id = {alias}.id "
        f"and (${n}::bigint[] is null or tb_.branch_id = any(${n}::bigint[])))"
    )


def not_found(what: str) -> HTTPException:
    return HTTPException(status.HTTP_404_NOT_FOUND, f"{what} topilmadi.")


async def require_group(ex, scope: Scope, group_id: int):
    """The group's row, or 404 when it is not in the scope."""
    row = await ex.fetchrow(
        f"select * from groups g where g.id = $1 and {branch_filter('g.branch_id', 2)}", group_id, scope.ids
    )
    if row is None:
        raise not_found("Guruh")
    return row


async def require_student(ex, scope: Scope, student_id: int):
    row = await ex.fetchrow(
        f"select s.* from students s where s.id = $1 and {student_filter('s', 2)}", student_id, scope.ids
    )
    if row is None:
        raise not_found("O'quvchi")
    return row


async def require_enrollment(ex, scope: Scope, enrollment_id: int):
    """An enrollment is in the scope when its group is."""
    row = await ex.fetchrow(
        f"""
        select e.* from enrollments e join groups g on g.id = e.group_id
        where e.id = $1 and {branch_filter('g.branch_id', 2)}
        """,
        enrollment_id, scope.ids,
    )
    if row is None:
        raise not_found("Yozilish")
    return row


async def require_teacher(ex, scope: Scope, teacher_id: int):
    row = await ex.fetchrow(
        f"select t.* from teachers t where t.id = $1 and {teacher_filter('t', 2)}", teacher_id, scope.ids
    )
    if row is None:
        raise not_found("O'qituvchi")
    return row


async def link_student(conn, student_id: int, branch_id: int) -> bool:
    """Puts the student in a branch (a branch sees them only through this
    link). True when it was an archived link that this brings back."""
    await conn.execute(
        "insert into student_branches (student_id, branch_id) values ($1, $2) on conflict do nothing",
        student_id, branch_id,
    )
    return bool(
        await conn.fetchval(
            "update student_branches set archived_at = null where student_id = $1 and branch_id = $2 "
            "and archived_at is not null returning 1",
            student_id, branch_id,
        )
    )


async def link_teacher(conn, teacher_id: int, branch_id: int) -> None:
    await conn.execute(
        "insert into teacher_branches (teacher_id, branch_id) values ($1, $2) on conflict do nothing",
        teacher_id, branch_id,
    )


def ambient_ids() -> list[int] | None:
    """The branches of the request being served (None = all, which is also how
    background jobs run)."""
    scope = ambient_scope()
    return None if scope is None else scope.ids


def current_scope() -> Scope:
    """The scope of the request being served; a request always has one."""
    scope = ambient_scope()
    if scope is None:
        raise RuntimeError("No branch scope: this code must run inside a request.")
    return scope
