from datetime import date, timedelta

from fastapi import APIRouter, Depends, HTTPException, status

from .. import admissions, clock, db, funnel
from ..config import settings
from ..deps import get_current_user
from ..schemas import AdmissionsBoard, AdmissionsReport, CountByKey

router = APIRouter(prefix="/admissions", tags=["admissions"], dependencies=[Depends(get_current_user)])


def _rate(part: int, whole: int) -> float | None:
    return round(part / whole, 4) if whole else None


def _range(date_from: date | None, date_to: date | None) -> tuple[date, date]:
    today = clock.today()
    date_from = date_from or today.replace(day=1)
    date_to = date_to or today
    if date_to < date_from:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Sana oralig'i noto'g'ri.")
    if date_to - date_from > timedelta(days=366):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Oraliq bir yildan oshmasin.")
    return date_from, date_to


@router.get("/board", response_model=AdmissionsBoard)
async def admissions_board(date_from: date | None = None, date_to: date | None = None):
    """Qabul: the KPI strip and a column per V2 stage, all from app/funnel.py
    -- the same numbers Bugun and O'quvchilar show."""
    date_from, date_to = _range(date_from, date_to)
    async with db.pool().acquire() as conn:
        return AdmissionsBoard(**await funnel.board(conn, date_from, date_to))


@router.get("/report", response_model=AdmissionsReport)
async def admissions_report(date_from: date | None = None, date_to: date | None = None):
    """date_from..date_to, both inclusive, in the center's calendar;
    defaults to this month so far. A booked trial never counts as an
    enrollment -- enrollments are leads that went through the explicit
    enroll step."""
    today = clock.today()
    date_from, date_to = _range(date_from, date_to)
    tz = settings.center_timezone
    open_stages = list(admissions.OPEN_STAGES)

    async with db.pool().acquire() as conn:
        # People and enrollments come from app/funnel.py -- the same figures as
        # the Qabul board, Bugun and O'quvchilar.
        period = await funnel.period_counts(conn, date_from, date_to)
        trials = await conn.fetchrow(
            """
            select
              count(*) filter (where b.status <> 'rescheduled') as trials_booked,
              count(*) filter (where b.status = 'attended') as trials_attended,
              count(*) filter (where b.status = 'absent') as trials_absent,
              count(*) filter (where b.status = 'cancelled') as trials_cancelled,
              count(distinct b.lead_id) filter (where b.status = 'attended') as trial_cohort_size,
              count(distinct b.lead_id) filter (where b.status = 'attended' and l.stage = 'enrolled')
                as trial_cohort_enrolled
            from trial_bookings b
            join trial_sessions ts on ts.id = b.session_id
            join leads l on l.id = b.lead_id
            where (ts.starts_at at time zone $1)::date between $2 and $3
            """,
            tz,
            date_from,
            date_to,
        )
        now = await conn.fetchrow(
            """
            select
              (select count(*) from trial_bookings b join trial_sessions ts on ts.id = b.session_id
                where b.status = 'scheduled' and ts.starts_at >= now()
                  and ts.starts_at < now() + interval '7 days') as upcoming_trials,
              (select count(*) from follow_up_tasks where status = 'open' and due_at < now())
                as follow_ups_overdue,
              (select count(*) from follow_up_tasks where status = 'open' and due_at >= now()
                  and (due_at at time zone $1)::date = $2) as follow_ups_due_today
            """,
            tz,
            today,
        )
        by_stage = await conn.fetch(
            "select stage as key, count(*) from leads where stage = any($1::text[]) group by stage", open_stages
        )
        by_source = await conn.fetch(
            """
            select coalesce(source, 'unknown') as key, count(*),
                   count(*) filter (where stage = 'enrolled') as enrolled
            from leads
            where (created_at at time zone $1)::date between $2 and $3
            group by 1
            order by 2 desc, 1
            """,
            tz,
            date_from,
            date_to,
        )

    stage_counts = {row["key"]: row["count"] for row in by_stage}
    return AdmissionsReport(
        date_from=date_from,
        date_to=date_to,
        new_inquiries=period["leads"],
        trials_booked=trials["trials_booked"],
        trials_attended=trials["trials_attended"],
        trials_absent=trials["trials_absent"],
        trials_cancelled=trials["trials_cancelled"],
        show_rate=_rate(trials["trials_attended"], trials["trials_attended"] + trials["trials_absent"]),
        enrollments=period["joined"],
        cohort_size=period["cohort_size"],
        cohort_enrolled=period["cohort_joined"],
        lead_conversion_rate=period["conversion_rate"],
        trial_cohort_size=trials["trial_cohort_size"],
        trial_cohort_enrolled=trials["trial_cohort_enrolled"],
        trial_conversion_rate=_rate(trials["trial_cohort_enrolled"], trials["trial_cohort_size"]),
        upcoming_trials=now["upcoming_trials"],
        follow_ups_overdue=now["follow_ups_overdue"],
        follow_ups_due_today=now["follow_ups_due_today"],
        # Every open stage, zeros included, in pipeline order.
        open_by_stage=[CountByKey(key=stage, count=stage_counts.get(stage, 0)) for stage in open_stages],
        cohort_by_source=[CountByKey(**row) for row in by_source],
    )
