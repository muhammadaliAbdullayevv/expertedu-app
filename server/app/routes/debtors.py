from fastapi import APIRouter, Depends

from .. import billing, db
from ..deps import get_current_user
from ..schemas import Debtor

router = APIRouter(prefix="/debtors", tags=["debtors"], dependencies=[Depends(get_current_user)])

_BALANCE_EXPR = """
coalesce(sum(case when t.kind = 'charge' then t.amount when t.kind = 'payment' then -t.amount else 0 end), 0)
"""


async def list_debtors(limit: int | None = None) -> list[Debtor]:
    """Biggest debt first. Shared with the dashboard's top-debtors panel."""
    rows = await db.pool().fetch(
        f"""
        select e.id as enrollment_id, e.student_id, s.full_name as student_full_name,
               s.phone as student_phone, e.group_id, g.name as group_name, e.status,
               {_BALANCE_EXPR} as balance
        from enrollments e
        join students s on s.id = e.student_id
        join groups g on g.id = e.group_id
        join transactions t on t.enrollment_id = e.id
        group by e.id, s.full_name, s.phone, g.name
        having {_BALANCE_EXPR} > 0
        order by balance desc, s.full_name asc
        limit $1
        """,
        limit,
    )
    if not rows:
        return []

    enrollment_ids = [row["enrollment_id"] for row in rows]
    charges = await db.pool().fetch(
        """
        select enrollment_id, due_date, amount from transactions
        where kind = 'charge' and enrollment_id = any($1::bigint[])
        order by enrollment_id, due_date, id
        """,
        enrollment_ids,
    )
    paid = await db.pool().fetch(
        """
        select enrollment_id, sum(amount) as total from transactions
        where kind = 'payment' and enrollment_id = any($1::bigint[])
        group by enrollment_id
        """,
        enrollment_ids,
    )

    charges_by_enrollment: dict[int, list] = {}
    for charge in charges:
        charges_by_enrollment.setdefault(charge["enrollment_id"], []).append((charge["due_date"], charge["amount"]))
    paid_by_enrollment = {row["enrollment_id"]: row["total"] for row in paid}

    return [
        Debtor(
            **row,
            oldest_unpaid_due=billing.oldest_unpaid_due(
                charges_by_enrollment.get(row["enrollment_id"], []),
                paid_by_enrollment.get(row["enrollment_id"], 0),
            ),
        )
        for row in rows
    ]


@router.get("", response_model=list[Debtor])
async def get_debtors():
    return await list_debtors()
