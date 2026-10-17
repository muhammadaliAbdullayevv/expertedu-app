from datetime import date

from fastapi import APIRouter, Depends

from .. import clock, db
from ..config import settings
from ..deps import get_current_user
from ..schemas import DashboardSummary, MonthlyRevenue, RecentPayment, TrialToday
from .debtors import list_debtors

router = APIRouter(prefix="/dashboard", tags=["dashboard"], dependencies=[Depends(get_current_user)])

_REVENUE_MONTHS = 6
_RECENT_PAYMENTS = 8
_TOP_DEBTORS = 6


def _month_starts(today: date, count: int) -> list[date]:
    """First day of each of the last `count` months, oldest first, ending
    with today's month."""
    index = today.year * 12 + today.month - 1
    return [date((index - back) // 12, (index - back) % 12 + 1, 1) for back in range(count - 1, -1, -1)]


@router.get("", response_model=DashboardSummary)
async def get_dashboard():
    today = clock.today()
    month_start = today.replace(day=1)
    months = _month_starts(today, _REVENUE_MONTHS)
    # Timestamps are bucketed into the center's calendar days, not UTC ones
    # -- a payment at 02:00 on the 1st in Tashkent belongs to the new month.
    tz = settings.center_timezone

    async with db.pool().acquire() as conn:
        counts = await conn.fetchrow(
            """
            select
              (select count(distinct student_id) from enrollments where status = 'active') as active_students,
              (select count(*) from students where (created_at at time zone $1)::date >= $2) as new_students_this_month,
              (select count(*) from groups where is_active) as active_groups,
              (select coalesce(sum(amount), 0) from transactions
                where kind = 'payment' and (occurred_at at time zone $1)::date >= $2) as collected_this_month,
              (select coalesce(sum(g.fee_amount), 0) from enrollments e
                join groups g on g.id = e.group_id where e.status = 'active') as monthly_plan
            """,
            tz,
            month_start,
        )

        debt = await conn.fetchrow(
            """
            with balances as (
              select e.student_id,
                     sum(case when t.kind = 'charge' then t.amount else -t.amount end) as balance
              from enrollments e
              join transactions t on t.enrollment_id = e.id
              group by e.id
            )
            select coalesce(sum(balance), 0) as total_debt, count(distinct student_id) as debtor_count
            from balances where balance > 0
            """
        )

        leads = await conn.fetchrow(
            """
            select
              count(*) filter (where created_at >= now() - interval '7 days') as new_leads_this_week,
              count(*) filter (where status in ('new', 'contacted', 'scheduled')) as open_leads,
              count(*) filter (where status = 'new' and created_at < now() - interval '24 hours')
                as unanswered_leads
            from inquiries
            """
        )

        # Recurring charges only -- an enrollment created today also has a
        # charge dated today, but that's a new student joining, not a due day.
        due_today = await conn.fetchrow(
            """
            select count(*) as due_today_count, coalesce(sum(t.amount), 0) as due_today_amount
            from transactions t
            join enrollments e on e.id = t.enrollment_id
            where t.kind = 'charge' and t.due_date = $1 and e.joined_at < $1
            """,
            today,
        )

        trials = await conn.fetch(
            """
            select i.id as inquiry_id, i.full_name, i.phone, s.name as subject_name
            from inquiries i
            left join subjects s on s.id = i.subject_id
            where i.trial_date = $1 and i.status not in ('converted', 'lost')
            order by i.full_name asc
            """,
            today,
        )

        revenue_rows = await conn.fetch(
            """
            select date_trunc('month', occurred_at at time zone $1)::date as month, sum(amount) as amount
            from transactions
            where kind = 'payment' and (occurred_at at time zone $1)::date >= $2
            group by 1
            """,
            tz,
            months[0],
        )

        recent = await conn.fetch(
            """
            select t.id, t.enrollment_id, s.full_name as student_full_name, g.name as group_name,
                   t.amount, t.occurred_at
            from transactions t
            join enrollments e on e.id = t.enrollment_id
            join students s on s.id = e.student_id
            join groups g on g.id = e.group_id
            where t.kind = 'payment'
            order by t.occurred_at desc
            limit $1
            """,
            _RECENT_PAYMENTS,
        )

    revenue = {row["month"]: row["amount"] for row in revenue_rows}
    return DashboardSummary(
        today=today,
        **counts,
        **debt,
        **leads,
        **due_today,
        trials_today=[TrialToday(**row) for row in trials],
        # Zero-filled so the chart always shows every month, quiet ones too.
        revenue_by_month=[MonthlyRevenue(month=month, amount=revenue.get(month, 0)) for month in months],
        recent_payments=[RecentPayment(**row) for row in recent],
        top_debtors=await list_debtors(limit=_TOP_DEBTORS),
    )
