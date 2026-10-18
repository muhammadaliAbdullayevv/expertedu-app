from datetime import date, timedelta

from fastapi import APIRouter, Depends

from .. import clock, db, funnel
from ..money import service as money
from ..config import settings
from ..deps import Scope, get_current_user, get_scope, require_owner
from ..schemas import BranchStats, DashboardSummary, MonthlyRevenue, RecentPayment, TrialToday
from .debtors import list_debtors
from .timetable import _timetable

router = APIRouter(prefix="/dashboard", tags=["dashboard"], dependencies=[Depends(get_current_user)])

_REVENUE_MONTHS = 6
_RECENT_PAYMENTS = 8
_TOP_DEBTORS = 6


def _month_starts(today: date, count: int) -> list[date]:
    """First day of each of the last `count` months, oldest first, ending
    with today's month."""
    index = today.year * 12 + today.month - 1
    return [date((index - back) // 12, (index - back) % 12 + 1, 1) for back in range(count - 1, -1, -1)]


async def _attendance_rate_7d(conn, today: date, ids: list[int] | None) -> float | None:
    """present+late out of the marks that count (excused ones do not), over the
    lessons of the last 7 days in these branches."""
    row = await conn.fetchrow(
        """
        select count(*) filter (where a.status in ('present', 'late')) as came,
               count(*) filter (where a.status <> 'excused') as expected
        from attendance a
        join lessons l on l.id = a.lesson_id
        join groups g on g.id = l.group_id
        where l.status = 'active' and (l.starts_at at time zone $1)::date between $2 and $3
          and ($4::bigint[] is null or g.branch_id = any($4::bigint[]))
        """,
        settings.center_timezone,
        today - timedelta(days=6),
        today,
        ids,
    )
    return round(row["came"] / row["expected"], 4) if row["expected"] else None


async def _collected_this_month(conn, month_start: date, ids: list[int] | None) -> int:
    return await conn.fetchval(
        """
        select coalesce(sum(case when kind = 'payment' then amount else -amount end), 0)::bigint from payments
        where (received_at at time zone $1)::date >= $2 and ($3::bigint[] is null or branch_id = any($3::bigint[]))
        """,
        settings.center_timezone,
        month_start,
        ids,
    )


async def _debt(conn, ids: list[int] | None) -> tuple[int, int]:
    row = await conn.fetchrow(
        """
        select coalesce(sum(eb.owed), 0)::bigint as total_debt, count(distinct eb.student_id) as debtor_count
        from enrollment_balances eb
        join enrollments e on e.id = eb.enrollment_id join groups g on g.id = e.group_id
        where eb.owed > 0 and ($1::bigint[] is null or g.branch_id = any($1::bigint[]))
        """,
        ids,
    )
    return row["total_debt"], row["debtor_count"]


@router.get("/branches", response_model=list[BranchStats], dependencies=[Depends(require_owner)])
async def branch_stats():
    """OWNER ONLY: every branch side by side -- students, what it collected this
    month, what is owed, how lessons are attended, today's lessons, open requests."""
    today = clock.today()
    result = []
    async with db.pool().acquire() as conn:
        for b in await conn.fetch("select id, name, is_headquarters from branches where is_active order by is_headquarters desc, name"):
            ids = [b["id"]]
            students = await funnel.student_counts(conn, today, ids)
            leads = await funnel.lead_counts(conn, ids)
            debt, debtors = await _debt(conn, ids)
            lessons = await _timetable(conn, today, today, ids=ids)
            result.append(
                BranchStats(
                    branch_id=b["id"],
                    name=b["name"],
                    is_headquarters=b["is_headquarters"],
                    active_students=students["active_students"],
                    active_groups=await conn.fetchval(
                        "select count(*) from groups where is_active and branch_id = $1", b["id"]
                    ),
                    collected_this_month=await _collected_this_month(conn, today.replace(day=1), ids),
                    total_debt=debt,
                    debtor_count=debtors,
                    attendance_rate_7d=await _attendance_rate_7d(conn, today, ids),
                    lessons_today=sum(1 for l in lessons if l.status != "cancelled"),
                    open_leads=leads["open_leads"],
                )
            )
    return result


@router.get("", response_model=DashboardSummary)
async def get_dashboard(scope: Scope = Depends(get_scope)):
    today = clock.today()
    month_start = today.replace(day=1)
    months = _month_starts(today, _REVENUE_MONTHS)
    # Timestamps are bucketed into the center's calendar days, not UTC ones
    # -- a payment at 02:00 on the 1st in Tashkent belongs to the new month.
    tz = settings.center_timezone

    money_visible = scope.user.is_owner
    async with db.pool().acquire() as conn:
        counts = {
            "active_groups": await conn.fetchval(
                "select count(*) from groups where is_active and ($1::bigint[] is null or branch_id = any($1::bigint[]))",
                scope.ids,
            ),
            # What the center collects is the owner's to see; an admin only
            # collects from students (debts, who pays today).
            "collected_this_month": await _collected_this_month(conn, month_start, scope.ids) if money_visible else 0,
        }

        total_debt, debtor_count = await _debt(conn, scope.ids)
        debt = {"total_debt": total_debt, "debtor_count": debtor_count}
        monthly_plan = await money.monthly_plan(conn, month_start, scope.ids) if money_visible else 0
        attendance_7d = await _attendance_rate_7d(conn, today, scope.ids)
        tasks_due_today = await conn.fetchval(
            """
            select count(*) from follow_up_tasks t join leads l on l.id = t.lead_id
            where t.status = 'open' and (t.due_at at time zone $1)::date <= $2
              and ($3::bigint[] is null or l.branch_id = any($3::bigint[]))
            """,
            tz,
            today,
            scope.ids,
        )

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

        revenue_rows = [] if not money_visible else await conn.fetch(
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

        recent = [] if not money_visible else await conn.fetch(
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
        revenue_by_month=(
            [MonthlyRevenue(month=month, amount=revenue.get(month, 0)) for month in months] if money_visible else []
        ),
        recent_payments=[RecentPayment(**row) for row in recent],
        top_debtors=await list_debtors(limit=_TOP_DEBTORS, ids=scope.ids),
        money_visible=money_visible,
        attendance_rate_7d=attendance_7d,
        tasks_due_today=tasks_due_today,
    )
