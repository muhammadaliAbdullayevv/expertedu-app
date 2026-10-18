from fastapi import APIRouter, Depends

from .. import clock, db
from ..deps import Scope, get_current_user, get_scope
from ..money import rules
from ..schemas import Debtor

router = APIRouter(prefix="/debtors", tags=["debtors"], dependencies=[Depends(get_current_user)])


async def list_debtors(limit: int | None = None, ids: list[int] | None = None) -> list[Debtor]:
    """Enrollments that still owe money, biggest first. Shared with the
    dashboard's top-debtors panel. Withdrawn enrollments still appear:
    leaving doesn't clear a debt. A student's credit from another group is
    not netted here -- see money.student_balance for the whole student."""
    rows = await db.pool().fetch(
        """
        select e.id as enrollment_id, e.student_id, s.full_name as student_full_name,
               s.phone as student_phone, e.group_id, g.name as group_name, e.status,
               eb.owed as balance,
               (select min(cb.due_date) from charge_balances cb
                 where cb.enrollment_id = e.id and cb.status = 'active' and cb.owed > 0) as oldest_unpaid_due
        from enrollment_balances eb
        join enrollments e on e.id = eb.enrollment_id
        join students s on s.id = e.student_id
        join groups g on g.id = e.group_id
        where eb.owed > 0 and ($2::bigint[] is null or g.branch_id = any($2::bigint[]))
        order by eb.owed desc, s.full_name asc
        limit $1
        """,
        limit,
        ids,
    )
    today = clock.today()
    debtors = []
    for row in rows:
        days = max((today - row["oldest_unpaid_due"]).days, 0) if row["oldest_unpaid_due"] else 0
        debtors.append(Debtor(**row, days_overdue=days, age_bucket=rules.debt_bucket(days)))
    return debtors


@router.get("", response_model=list[Debtor])
async def get_debtors(scope: Scope = Depends(get_scope)):
    return await list_debtors(ids=scope.ids)
