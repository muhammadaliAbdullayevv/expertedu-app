"""The center's finances -- owner only. Income is payments received;
teachers earn a percentage of the payments for their groups (counted by
the teacher recorded on each payment, see migration 0011); paying them
is an expense in the 'salary' category; profit is income minus expenses.
All months are the center's calendar months."""

from datetime import date
from decimal import Decimal

from fastapi import APIRouter, Depends, HTTPException, Query, status

from .. import clock, db
from ..money import service as money
from ..config import settings
from ..deps import CurrentUser, get_current_user, require_owner
from ..schemas import (
    CreateExpenseRequest,
    Expense,
    FinanceMonth,
    FinanceSummary,
    SalaryMonth,
    SetSalaryPercentRequest,
    SetSalaryRuleRequest,
    TeacherSalary,
    VoidExpenseRequest,
)

# The owner and the admin both see Moliya, take payments and record
# expenses and payouts. Only the owner closes a salary month or changes how
# anyone is paid (see the endpoints marked require_owner below).
router = APIRouter(tags=["finance"], dependencies=[Depends(get_current_user)])

CATEGORIES = ("salary", "rent", "utilities", "marketing", "supplies", "tax", "other")
_METHODS = ("cash", "card", "click_payme")

_EXPENSE_SELECT = """
select x.*, t.full_name as teacher_name, u.full_name as created_by_name
from expenses x
left join teachers t on t.id = x.teacher_id
left join users u on u.id = x.created_by
"""


def _month_start(value: date) -> date:
    return value.replace(day=1)


def _next_month(value: date) -> date:
    return date(value.year + value.month // 12, value.month % 12 + 1, 1)


# --- Expenses --------------------------------------------------------------------


@router.get("/expenses", response_model=list[Expense])
async def list_expenses(
    date_from: date, date_to: date, category: str | None = None, include_voided: bool = False
):
    if date_to < date_from:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Sana oralig'i noto'g'ri.")
    rows = await db.pool().fetch(
        f"""
        {_EXPENSE_SELECT}
        where x.spent_on between $1 and $2
          and ($3::text is null or x.category = $3)
          and ($4 or x.voided_at is null)
        order by x.spent_on desc, x.id desc
        """,
        date_from,
        date_to,
        category,
        include_voided,
    )
    return [Expense(**row) for row in rows]


@router.post("/expenses", response_model=Expense, status_code=status.HTTP_201_CREATED)
async def create_expense(payload: CreateExpenseRequest, user: CurrentUser = Depends(get_current_user)):
    if payload.category not in CATEGORIES:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Xarajat turi noto'g'ri.")
    if payload.amount <= 0:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Summa musbat bo'lishi kerak.")
    if payload.method is not None and payload.method not in _METHODS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "To'lov usuli noto'g'ri.")
    teacher_id, salary_month = None, None
    if payload.category == "salary":
        if payload.teacher_id is None or payload.salary_month is None:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Oylik uchun o'qituvchi va oyni tanlang.")
        teacher_id, salary_month = payload.teacher_id, _month_start(payload.salary_month)
    async with db.pool().acquire() as conn:
        if teacher_id is not None and not await conn.fetchval("select 1 from teachers where id = $1", teacher_id):
            raise HTTPException(status.HTTP_404_NOT_FOUND, "O'qituvchi topilmadi.")
        if payload.category == "salary":
            # A salary payout is a payout and its expense row, made together.
            expense_id = (
                await money.record_payout(
                    conn, teacher_id=teacher_id, month=salary_month, amount=payload.amount,
                    paid_on=payload.spent_on, method=payload.method, note=(payload.note or "").strip() or None,
                    user_id=user.id,
                )
            )["expense_id"]
            row = await conn.fetchrow(f"{_EXPENSE_SELECT} where x.id = $1", expense_id)
            return Expense(**row)
        expense_id = await conn.fetchval(
            """
            insert into expenses (category, amount, spent_on, note, method, teacher_id, salary_month, created_by)
            values ($1, $2, $3, $4, $5, $6, $7, $8)
            returning id
            """,
            payload.category,
            payload.amount,
            payload.spent_on,
            (payload.note or "").strip() or None,
            payload.method,
            teacher_id,
            salary_month,
            user.id,
        )
        row = await conn.fetchrow(f"{_EXPENSE_SELECT} where x.id = $1", expense_id)
    return Expense(**row)


@router.post("/expenses/{expense_id}/void", response_model=Expense)
async def void_expense(expense_id: int, payload: VoidExpenseRequest, user: CurrentUser = Depends(get_current_user)):
    """Cancels a mistaken expense. It stays on record, marked void."""
    reason = payload.reason.strip()
    if not reason:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Sababini yozing.")
    async with db.pool().acquire() as conn:
        updated = await conn.fetchval(
            """
            update expenses set voided_at = now(), voided_by = $2, void_reason = $3
            where id = $1 and voided_at is null
            returning id
            """,
            expense_id,
            user.id,
            reason,
        )
        if updated is not None:
            await money.void_payout_for_expense(conn, expense_id, reason, user.id)
            await money.audit(conn, user.id, "expense", expense_id, "void", reason=reason)
        row = await conn.fetchrow(f"{_EXPENSE_SELECT} where x.id = $1", expense_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Xarajat topilmadi.")
    if updated is None and row["voided_at"] is None:
        raise HTTPException(status.HTTP_409_CONFLICT, "Xarajatni bekor qilib bo'lmadi.")
    return Expense(**row)


# --- Salaries ---------------------------------------------------------------------


def _decimal(value: float | None) -> Decimal | None:
    return None if value is None else Decimal(str(value))


@router.put("/finance/teachers/{teacher_id}/salary", response_model=TeacherSalary)
async def set_teacher_salary(
    teacher_id: int, payload: SetSalaryRuleRequest, user: CurrentUser = Depends(require_owner)
):
    """OWNER ONLY. How this teacher is paid: percent, fixed, or no rule."""
    async with db.pool().acquire() as conn:
        await money.set_teacher_rule(
            conn, teacher_id, payload.method, _decimal(payload.percent), payload.fixed, user.id
        )
        month = await _salary_month(conn, _month_start(clock.today()))
    return next(t for t in month.teachers if t.teacher_id == teacher_id)


@router.put("/finance/groups/{group_id}/salary", status_code=status.HTTP_204_NO_CONTENT)
async def set_group_salary(group_id: int, payload: SetSalaryRuleRequest, user: CurrentUser = Depends(require_owner)):
    """OWNER ONLY. This group's own pay rule, which wins over its teacher's
    (null method = follow the teacher)."""
    async with db.pool().acquire() as conn:
        await money.set_group_rule(conn, group_id, payload.method, _decimal(payload.percent), payload.fixed, user.id)


@router.put("/finance/teachers/{teacher_id}/percent", response_model=TeacherSalary)
async def set_salary_percent(
    teacher_id: int, payload: SetSalaryPercentRequest, user: CurrentUser = Depends(require_owner)
):
    """OWNER ONLY. Shortcut for a percent rule (null clears the rule)."""
    percent = _decimal(payload.salary_percent)
    async with db.pool().acquire() as conn:
        await money.set_teacher_percent(conn, teacher_id, percent, user.id)
        month = await _salary_month(conn, _month_start(clock.today()))
    return next(t for t in month.teachers if t.teacher_id == teacher_id)


@router.put("/finance/groups/{group_id}/percent", status_code=status.HTTP_204_NO_CONTENT)
async def set_group_salary_percent(
    group_id: int, payload: SetSalaryPercentRequest, user: CurrentUser = Depends(require_owner)
):
    """OWNER ONLY. This group's own percent, instead of its teacher's."""
    async with db.pool().acquire() as conn:
        await money.set_group_percent(conn, group_id, _decimal(payload.salary_percent), user.id)


async def _salary_month(conn, month: date) -> SalaryMonth:
    return SalaryMonth(**await money.salary_month(conn, month))


@router.get("/finance/salaries", response_model=SalaryMonth)
async def salaries(month: date | None = None):
    """Each teacher's share of what their students paid in the month (any
    day of it), per student, and what has been paid out for that month."""
    async with db.pool().acquire() as conn:
        return await _salary_month(conn, _month_start(month or clock.today()))


@router.post("/finance/salaries/close", response_model=SalaryMonth)
async def close_salary_month(month: date, user: CurrentUser = Depends(require_owner)):
    """OWNER ONLY. "Oyni yopish": freezes the month so later changes can't alter it."""
    async with db.pool().acquire() as conn:
        return SalaryMonth(**await money.close_month(conn, month, user.id))


# --- Summary ------------------------------------------------------------------------


@router.get("/finance/summary", response_model=FinanceSummary)
async def finance_summary(months: int = Query(default=6, ge=1, le=24)):
    current = _month_start(clock.today())
    starts = [current]
    for _ in range(months - 1):
        prev = starts[0]
        starts.insert(0, date(prev.year - (prev.month == 1), (prev.month - 2) % 12 + 1, 1))
    first = starts[0]
    tz = settings.center_timezone
    async with db.pool().acquire() as conn:
        income_rows = await conn.fetch(
            """
            select date_trunc('month', received_at at time zone $1)::date as month,
                   sum(case when kind = 'payment' then amount else -amount end)::bigint as amount
            from payments
            where (received_at at time zone $1)::date >= $2
            group by 1
            """,
            tz,
            first,
        )
        expense_rows = await conn.fetch(
            """
            select date_trunc('month', spent_on)::date as month, category, sum(amount) as amount
            from expenses
            where voided_at is null and spent_on >= $1
            group by 1, 2
            """,
            first,
        )
        this_month = await _salary_month(conn, current)

    income = {row["month"]: row["amount"] for row in income_rows}
    by_month: dict[date, dict[str, int]] = {}
    for row in expense_rows:
        by_month.setdefault(row["month"], {})[row["category"]] = row["amount"]
    result = []
    for start in starts:
        categories = by_month.get(start, {})
        spent = sum(categories.values())
        earned = income.get(start, 0)
        result.append(
            FinanceMonth(month=start, income=earned, expenses=spent, profit=earned - spent, by_category=categories)
        )
    return FinanceSummary(
        months=result,
        salaries_unpaid_this_month=sum(max(t.remaining, 0) for t in this_month.teachers),
    )
