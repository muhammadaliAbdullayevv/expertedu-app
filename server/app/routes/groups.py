from fastapi import APIRouter, Depends, HTTPException, status

from .. import db
from ..deps import get_current_user
from ..schemas import CreateGroupRequest, Group, RosterEntry, UpdateGroupRequest

router = APIRouter(prefix="/groups", tags=["groups"], dependencies=[Depends(get_current_user)])


@router.get("", response_model=list[Group])
async def list_groups(include_inactive: bool = False):
    where = "" if include_inactive else "where is_active"
    rows = await db.pool().fetch(f"select * from groups {where} order by name asc")
    return [Group(**row) for row in rows]


@router.post("", response_model=Group, status_code=status.HTTP_201_CREATED)
async def create_group(payload: CreateGroupRequest):
    row = await db.pool().fetchrow(
        """
        insert into groups (name, teacher_name, fee_amount, due_day, note)
        values ($1, $2, $3, $4, $5)
        returning *
        """,
        payload.name.strip(),
        payload.teacher_name.strip() if payload.teacher_name else None,
        payload.fee_amount,
        payload.due_day,
        payload.note,
    )
    return Group(**row)


@router.get("/{group_id}", response_model=Group)
async def get_group(group_id: int):
    row = await db.pool().fetchrow("select * from groups where id = $1", group_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Guruh topilmadi.")
    return Group(**row)


@router.patch("/{group_id}", response_model=Group)
async def update_group(group_id: int, payload: UpdateGroupRequest):
    existing = await db.pool().fetchrow("select * from groups where id = $1", group_id)
    if existing is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Guruh topilmadi.")

    updates = payload.model_dump(exclude_unset=True)
    if not updates:
        return Group(**existing)

    fields = list(updates.keys())
    values = list(updates.values())
    set_clause = ", ".join(f"{field} = ${i + 2}" for i, field in enumerate(fields))
    row = await db.pool().fetchrow(
        f"update groups set {set_clause} where id = $1 returning *",
        group_id,
        *values,
    )
    return Group(**row)


_BALANCE_EXPR = """
coalesce(sum(case when t.kind = 'charge' then t.amount when t.kind = 'payment' then -t.amount else 0 end), 0)
"""


@router.get("/{group_id}/roster", response_model=list[RosterEntry])
async def get_roster(group_id: int, include_withdrawn: bool = False):
    where = "" if include_withdrawn else "and e.status = 'active'"
    rows = await db.pool().fetch(
        f"""
        select e.id as enrollment_id, e.student_id, s.full_name as student_full_name,
               s.phone as student_phone, e.joined_at, e.status, {_BALANCE_EXPR} as balance
        from enrollments e
        join students s on s.id = e.student_id
        left join transactions t on t.enrollment_id = e.id
        where e.group_id = $1 {where}
        group by e.id, s.full_name, s.phone
        order by s.full_name asc
        """,
        group_id,
    )
    return [RosterEntry(**row) for row in rows]
