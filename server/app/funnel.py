"""The one definition of every Qabul and student count.

Bugun (the dashboard), Qabul (the board and its KPI strip), O'quvchilar
(the student list's summary) and the sidebar badges all call the functions
here -- nothing else counts leads or students -- so one person is counted
the same way on every screen.

Definitions
-----------
Stages. The app keeps nine lead stages (admissions.ALL_STAGES); people see
seven (V2 names), grouped by STAGE_TO_V2 below:

    Yangi              new
    Bog'lanildi        contacted
    Sinov darsi        trial_scheduled
    To'lov kutilmoqda  trial_completed, decision_pending
    Guruhga qo'shildi  enrolled
    Keyinroq           follow_up_later
    Rad etildi         not_interested, unreachable

Open lead: a lead in any stage except Guruhga qo'shildi and Rad etildi --
Yangi, Bog'lanildi, Sinov darsi, To'lov kutilmoqda, Keyinroq. Someone who
has not decided yet is still a lead, so Keyinroq counts.

Lead (so'rov): one inquiry; a person asking about two subjects is two. The
phone number identifies the person.

Student: a person with a students row. An *active* student has at least one
active enrollment. A lead -- including one with a trial lesson booked or
attended -- is never a student until "Guruhga qo'shish" (enrollment) makes
them one: that one step moves them from the open leads to Guruhga
qo'shildi and into the active students, in the same transaction.

Period figures (a day range in the center's calendar, "this month so far"
by default):
  leads        leads created in the range
  trial_people people (leads) who attended a trial lesson whose date is in the range
  joined       leads that enrolled (enrolled_at) in the range
  cohort       the leads created in the range, and how many of those are now
               enrolled -- the conversion rate is cohort_joined / cohort_size
Bookings (a person booked, moved and attended is three bookings, one person)
are a different thing and are counted only where they are named bookings.
"""

from datetime import date

from . import admissions, clock
from .config import settings
from .scope import branch_filter, student_filter, teacher_filter

STAGE_TO_V2 = {
    "new": "new",
    "contacted": "contacted",
    "trial_scheduled": "trial",
    "trial_completed": "awaiting_decision",
    "decision_pending": "awaiting_decision",
    "enrolled": "joined",
    "follow_up_later": "later",
    "not_interested": "rejected",
    "unreachable": "rejected",
}

# Board order, left to right.
V2_STAGES = ("new", "contacted", "trial", "awaiting_decision", "joined", "later", "rejected")
V2_LABELS = {
    "new": "Yangi",
    "contacted": "Bog'lanildi",
    "trial": "Sinov darsi",
    "awaiting_decision": "To'lov kutilmoqda",
    "joined": "Guruhga qo'shildi",
    "later": "Keyinroq",
    "rejected": "Rad etildi",
}
OPEN_V2 = ("new", "contacted", "trial", "awaiting_decision", "later")

assert set(STAGE_TO_V2) == set(admissions.ALL_STAGES), "every stage must map to a V2 stage"
assert {STAGE_TO_V2[s] for s in admissions.OPEN_STAGES} == set(OPEN_V2), "open V2 stages must be the open stages"


def v2_stage(stage: str) -> str:
    return STAGE_TO_V2[stage]


def v2_case(alias: str = "l") -> str:
    """The same grouping as SQL, so queries never restate it."""
    whens = " ".join(f"when '{stage}' then '{v2}'" for stage, v2 in STAGE_TO_V2.items())
    return f"case {alias}.stage {whens} end"


_TZ = settings.center_timezone


def _day(column: str) -> str:
    return f"({column} at time zone '{_TZ}')::date"


# --- Leads ---------------------------------------------------------------------------------------


# Every function below takes `ids`, the branches in scope (None = all); a
# person is counted in the branch they asked in.


async def open_leads_by_stage(conn, ids=None) -> dict[str, int]:
    """{v2 stage: how many open leads are there right now}, every open stage present."""
    rows = await conn.fetch(
        f"select {v2_case()} as v2, count(*) as n from leads l "
        f"where l.stage = any($1::text[]) and {branch_filter('l.branch_id', 2)} group by 1",
        list(admissions.OPEN_STAGES),
        ids,
    )
    found = {row["v2"]: row["n"] for row in rows}
    return {stage: found.get(stage, 0) for stage in OPEN_V2}


async def lead_counts(conn, ids=None) -> dict:
    """The numbers about leads that are true right now."""
    by_stage = await open_leads_by_stage(conn, ids)
    unanswered = await conn.fetchval(
        "select count(*) from leads l where l.stage = 'new' and l.created_at < now() - interval '24 hours' "
        f"and {branch_filter('l.branch_id', 1)}",
        ids,
    )
    return {
        "open_leads": sum(by_stage.values()),
        "open_by_stage": by_stage,
        "unanswered_leads": unanswered,
    }


async def period_counts(conn, date_from: date, date_to: date, ids=None) -> dict:
    """What happened to leads between two days (inclusive)."""
    created = await conn.fetchrow(
        f"""
        select
          count(*) filter (where {_day('created_at')} between $1 and $2) as leads,
          count(*) filter (where {_day('created_at')} between $1 and $2 and stage = 'enrolled') as cohort_joined,
          count(*) filter (where stage = 'enrolled' and {_day('enrolled_at')} between $1 and $2) as joined,
          count(*) filter (where stage = any($3::text[]) and {_day('closed_at')} between $1 and $2) as rejected
        from leads l
        where {branch_filter('l.branch_id', 4)}
        """,
        date_from,
        date_to,
        [s for s, v in STAGE_TO_V2.items() if v == "rejected"],
        ids,
    )
    trial_people = await conn.fetchval(
        f"""
        select count(distinct b.lead_id)
        from trial_bookings b join trial_sessions ts on ts.id = b.session_id
        where b.status = 'attended' and {_day('ts.starts_at')} between $1 and $2
          and {branch_filter('ts.branch_id', 3)}
        """,
        date_from,
        date_to,
        ids,
    )
    cohort_size = created["leads"]
    return {
        "date_from": date_from,
        "date_to": date_to,
        "leads": cohort_size,
        "trial_people": trial_people,
        "joined": created["joined"],
        "rejected": created["rejected"],
        "cohort_size": cohort_size,
        "cohort_joined": created["cohort_joined"],
        "conversion_rate": round(created["cohort_joined"] / cohort_size, 4) if cohort_size else None,
    }


_BOARD_SELECT = f"""
select l.id, l.full_name, l.phone, l.stage, {v2_case()} as v2_stage, l.source, l.lost_reason,
       s.name as subject_name, u.full_name as assigned_to_name,
       l.created_at, l.enrolled_at, l.closed_at,
       coalesce(sc.at, l.created_at) as stage_changed_at,
       nt.starts_at as next_trial_at, lt.starts_at as last_trial_at, g.name as group_name
from leads l
left join subjects s on s.id = l.subject_id
left join users u on u.id = l.assigned_to
left join lateral (
  select max(created_at) as at from lead_interactions where lead_id = l.id and new_stage is not null
) sc on true
left join lateral (
  select ts.starts_at from trial_bookings b join trial_sessions ts on ts.id = b.session_id
  where b.lead_id = l.id and b.status = 'scheduled' limit 1
) nt on true
left join lateral (
  select ts.starts_at from trial_bookings b join trial_sessions ts on ts.id = b.session_id
  where b.lead_id = l.id and b.status = 'attended' order by ts.starts_at desc limit 1
) lt on true
left join enrollments e on e.id = l.enrollment_id
left join groups g on g.id = e.group_id
"""

_COLUMN_CARDS = 150


async def board(conn, date_from: date, date_to: date, ids=None) -> dict:
    """Qabul: the KPI strip and one column per V2 stage. The open columns
    show everyone there now; Guruhga qo'shildi and Rad etildi show what
    happened in the range -- the same numbers as the KPI strip."""
    period = await period_counts(conn, date_from, date_to, ids)
    open_counts = await open_leads_by_stage(conn, ids)
    rejected = [s for s, v in STAGE_TO_V2.items() if v == "rejected"]
    columns = []
    for key in V2_STAGES:
        if key in OPEN_V2:
            count = open_counts[key]
            where = f"where {v2_case()} = $1 and l.stage = any($2::text[]) and {branch_filter('l.branch_id', 3)}"
            args = [key, list(admissions.OPEN_STAGES), ids]
        elif key == "joined":
            count = period["joined"]
            where = (
                f"where l.stage = 'enrolled' and {_day('l.enrolled_at')} between $1 and $2 "
                f"and {branch_filter('l.branch_id', 3)}"
            )
            args = [date_from, date_to, ids]
        else:
            count = period["rejected"]
            where = (
                f"where l.stage = any($1::text[]) and {_day('l.closed_at')} between $2 and $3 "
                f"and {branch_filter('l.branch_id', 4)}"
            )
            args = [rejected, date_from, date_to, ids]
        rows = await conn.fetch(
            f"{_BOARD_SELECT} {where} order by stage_changed_at desc, l.id desc limit {_COLUMN_CARDS}", *args
        )
        columns.append({"key": key, "label": V2_LABELS[key], "count": count, "leads": [dict(r) for r in rows]})
    return {"date_from": date_from, "date_to": date_to, "kpi": period, "columns": columns}


# --- Students ------------------------------------------------------------------------------------


async def student_counts(conn, today: date | None = None, ids=None) -> dict:
    """The numbers about students. Only people who joined a group are here:
    leads, with or without a trial, are not."""
    today = today or clock.today()
    month_start = today.replace(day=1)
    row = await conn.fetchrow(
        f"""
        select
          (select count(distinct e.student_id) from enrollments e join groups g on g.id = e.group_id
            where e.status = 'active' and {branch_filter('g.branch_id', 2)}) as active_students,
          (select count(*) from students s where {student_filter('s', 2)}) as total_students,
          (select count(distinct sb.student_id) from student_branches sb
            where {_day('sb.linked_at')} >= $1 and {branch_filter('sb.branch_id', 2)}) as new_students_this_month,
          (select count(distinct eb.student_id) from enrollment_balances eb
            join enrollments e on e.id = eb.enrollment_id join groups g on g.id = e.group_id
            where eb.owed > 0 and {branch_filter('g.branch_id', 2)}) as students_with_debt
        """,
        month_start,
        ids,
    )
    return dict(row)


async def shell_counts(conn, ids=None) -> dict:
    """The badges beside the sidebar's Qabul, O'quvchilar, Guruhlar and
    O'qituvchilar."""
    leads = await lead_counts(conn, ids)
    students = await student_counts(conn, None, ids)
    row = await conn.fetchrow(
        f"select (select count(*) from groups g where g.is_active and {branch_filter('g.branch_id', 1)}) "
        "as active_groups, "
        f"(select count(*) from teachers t where t.is_active and {teacher_filter('t', 1)}) as active_teachers",
        ids,
    )
    return {
        "open_leads": leads["open_leads"],
        "active_students": students["active_students"],
        "active_groups": row["active_groups"],
        "active_teachers": row["active_teachers"],
    }
