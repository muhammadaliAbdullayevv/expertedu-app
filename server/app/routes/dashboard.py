from datetime import date, timedelta

from fastapi import APIRouter, Depends

from .. import clock, db, funnel
from ..money import service as money
from ..config import settings
from ..deps import Scope, get_current_user, get_scope
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
async def get_dashboard(scope: Scope = Depends(get_scope)):
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
              (select count(*) from groups where is_active and ($3::bigint[] is null or branch_id = any($3::bigint[])))
                as active_groups,
              (select coalesce(sum(case when kind = 'payment' then amount else -amount end), 0) from payments
                where (received_at at time zone $1)::date >= $2
                  and ($3::bigint[] is null or branch_id = any($3::bigint[]))) as collected_this_month
            """,
            tz,
            month_start,
            scope.ids,
        )

        debt = await conn.fetchrow(
            """
            select coalesce(sum(eb.owed), 0)::bigint as total_debt, count(distinct eb.student_id) as debtor_count
            from enrollment_balances eb
            join enrollments e on e.id = eb.enrollment_id join groups g on g.id = e.group_id
            where eb.owed > 0 and ($1::bigint[] is null or g.branch_id = any($1::bigint[]))
            """,
            scope.ids,
        )
        monthly_plan = await money.monthly_plan(conn, month_start, scope.ids)

        # Every lead and student number comes from app/funnel.py -- the same
        # definitions Qabul and O'quvchilar use.
        lead_numbers = await funnel.lead_counts(conn, scope.ids)
        week = await funnel.period_counts(conn, today - timedelta(days=6), today, scope.ids)
        student_numbers = await funnel.student_counts(conn, today, scope.ids)
        leads = {
            "new_leads_this_week": week["leads"],
            "open_leads": lead_numbers["open_leads"],
            "unanswered_leads": lead_numbers["unanswered_leads"],
        }
        students = {
            "active_students": student_numbers["active_students"],
            "new_students_this_month": student_numbers["new_students_this_month"],
        }

        # Students whose next charge falls due today (a student joining today
        # isn't a due day, it's a new student).
        due = await money.next_due_dates(
            conn,
            [
                r["id"]
                for r in await conn.fetch(
                    "select e.id from enrollments e join groups g on g.id = e.group_id "
                    "where e.status = 'active' and e.joined_at < $1 "
                    "and ($2::bigint[] is null or g.branch_id = any($2::bigint[]))",
                    today, scope.ids,
                )
            ],
            today,
        )
        due_today_ids = [i for i, d in due.items() if d == today]
        due_today = {
            "due_today_count": len(due_today_ids),
            "due_today_amount": await conn.fetchval(
                "select coalesce(sum(amount), 0)::bigint from charges "
                "where status = 'active' and due_date = $1 and enrollment_id = any($2::bigint[])",
                today, due_today_ids,
            ),
        }

        trials = await conn.fetch(
            """
            select l.id as inquiry_id, l.full_name, l.phone, s.name as subject_name, ts.starts_at
            from trial_bookings b
            join trial_sessions ts on ts.id = b.session_id
            join leads l on l.id = b.lead_id
            left join subjects s on s.id = coalesce(ts.subject_id, l.subject_id)
            where b.status = 'scheduled' and (ts.starts_at at time zone $1)::date = $2
              and ($3::bigint[] is null or ts.branch_id = any($3::bigint[]))
            order by ts.starts_at, l.full_name
            """,
            tz,
            today,
            scope.ids,
        )

        revenue_rows = await conn.fetch(
            """
            select date_trunc('month', received_at at time zone $1)::date as month,
                   sum(case when kind = 'payment' then amount else -amount end)::bigint as amount
            from payments
            where (received_at at time zone $1)::date >= $2
              and ($3::bigint[] is null or branch_id = any($3::bigint[]))
            group by 1
            """,
            tz,
            months[0],
            scope.ids,
        )

        recent = await conn.fetch(
            """
            select p.id, e.id as enrollment_id, s.full_name as student_full_name, g.name as group_name,
                   p.amount, p.received_at as occurred_at
            from payments p
            join students s on s.id = p.student_id
            join enrollments e on e.id = coalesce(p.enrollment_id,
                                                  (select min(id) from enrollments where student_id = p.student_id))
            join groups g on g.id = e.group_id
            where p.kind = 'payment' and p.status = 'valid'
              and ($2::bigint[] is null or p.branch_id = any($2::bigint[]))
            order by p.received_at desc
            limit $1
            """,
            _RECENT_PAYMENTS,
            scope.ids,
        )

    revenue = {row["month"]: row["amount"] for row in revenue_rows}
    return DashboardSummary(
        today=today,
        **counts,
        **students,
        monthly_plan=monthly_plan,
        **debt,
        **leads,
        **due_today,
        trials_today=[TrialToday(**row) for row in trials],
        # Zero-filled so the chart always shows every month, quiet ones too.
        revenue_by_month=[MonthlyRevenue(month=month, amount=revenue.get(month, 0)) for month in months],
        recent_payments=[RecentPayment(**row) for row in recent],
        top_debtors=await list_debtors(limit=_TOP_DEBTORS, ids=scope.ids),
    )
