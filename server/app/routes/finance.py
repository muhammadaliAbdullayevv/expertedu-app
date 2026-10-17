"""The center's finances -- owner only. Income is payments received;
teachers earn a percentage of the payments for their groups (counted by
the teacher recorded on each payment, see migration 0011); paying them
is an expense in the 'salary' category; profit is income minus expenses.
All months are the center's calendar months."""

from datetime import date
from decimal import Decimal, ROUND_HALF_UP

from fastapi import APIRouter, Depends, HTTPException, Query, status

from .. import clock, db
from ..config import settings
from ..deps import CurrentUser, require_owner
from ..schemas import (
    CreateExpenseRequest,
    Expense,
    FinanceMonth,
    FinanceSummary,
    SalaryMonth,
    SetSalaryPercentRequest,
    TeacherSalary,
    VoidExpenseRequest,
)

router = APIRouter(tags=["finance"], dependencies=[Depends(require_owner)])

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


def _share(collected: int, percent: Decimal | None) -> int:
    if percent is None:
        return 0
    return int((Decimal(collected) * percent / 100).quantize(Decimal(1), rounding=ROUND_HALF_UP))


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
async def create_expense(payload: CreateExpenseRequest, user: CurrentUser = Depends(require_owner)):
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
async def void_expense(expense_id: int, payload: VoidExpenseRequest, user: CurrentUser = Depends(require_owner)):
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
        row = await conn.fetchrow(f"{_EXPENSE_SELECT} where x.id = $1", expense_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Xarajat topilmadi.")
    if updated is None and row["voided_at"] is None:
        raise HTTPException(status.HTTP_409_CONFLICT, "Xarajatni bekor qilib bo'lmadi.")
    return Expense(**row)


# --- Salaries ---------------------------------------------------------------------


@router.put("/finance/teachers/{teacher_id}/percent", response_model=TeacherSalary)
async def set_salary_percent(teacher_id: int, payload: SetSalaryPercentRequest):
    percent = payload.salary_percent
    if percent is not None and not 0 <= percent <= 100:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Foiz 0 dan 100 gacha bo'lsin.")
    async with db.pool().acquire() as conn:
        updated = await conn.fetchval(
            "update teachers set salary_percent = $2 where id = $1 returning id",
            teacher_id,
            None if percent is None else Decimal(str(percent)),
        )
        if updated is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "O'qituvchi topilmadi.")
        month = await _salary_month(conn, _month_start(clock.today()))
    return next(t for t in month.teachers if t.teacher_id == teacher_id)


async def _salary_month(conn, month: date) -> SalaryMonth:
    rows = await conn.fetch(
        """
        with collected as (
          select teacher_id, sum(amount) as collected
          from transactions
          where kind = 'payment' and teacher_id is not null
            and (occurred_at at time zone $1)::date >= $2 and (occurred_at at time zone $1)::date < $3
          group by teacher_id
        ), paid as (
          select teacher_id, sum(amount) as paid
          from expenses
          where category = 'salary' and voided_at is null and salary_month = $2
          group by teacher_id
        )
        select t.id as teacher_id, t.full_name, t.is_active, t.salary_percent,
               coalesce(c.collected, 0) as collected, coalesce(p.paid, 0) as paid
        from teachers t
        left join collected c on c.teacher_id = t.id
        left join paid p on p.teacher_id = t.id
        where t.is_active or c.collected is not null or p.paid is not null
        order by t.full_name
        """,
        settings.center_timezone,
        month,
        _next_month(month),
    )
    teachers = []
    for row in rows:
        earned = _share(row["collected"], row["salary_percent"])
        teachers.append(
            TeacherSalary(
                teacher_id=row["teacher_id"],
                full_name=row["full_name"],
                is_active=row["is_active"],
                salary_percent=None if row["salary_percent"] is None else float(row["salary_percent"]),
                collected=row["collected"],
                earned=earned,
                paid=row["paid"],
                remaining=earned - row["paid"],
            )
        )
    return SalaryMonth(
        month=month,
        teachers=teachers,
        total_earned=sum(t.earned for t in teachers),
        total_paid=sum(t.paid for t in teachers),
        total_remaining=sum(t.remaining for t in teachers),
    )


@router.get("/finance/salaries", response_model=SalaryMonth)
async def salaries(month: date | None = None):
    """Each teacher's share of their groups' payments in the month (any
    day of it), and what's been paid out for that month."""
    async with db.pool().acquire() as conn:
        return await _salary_month(conn, _month_start(month or clock.today()))


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
            select date_trunc('month', occurred_at at time zone $1)::date as month, sum(amount) as amount
            from transactions
            where kind = 'payment' and (occurred_at at time zone $1)::date >= $2
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
