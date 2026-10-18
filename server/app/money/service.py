"""Everything that changes or reads money, in one place.

Routes call these; widgets never compute money. Functions take an asyncpg
connection and, for writes, expect to run inside the caller's transaction
(each opens its own nested one where it needs to be atomic on its own).

Money rules in short -- see docs/DOMAIN.md:
- billing is a per-group rule: everyone on a fixed day, or each enrollment
  on its own start day. One charge per enrollment per billing period.
- charges are cancelled with a reason, never deleted
- payments are cancelled by a reversal row with a reason, never deleted
- allocation: a student's payments pay their oldest unpaid charge first;
  what is left is credit. Allocations are append-only and signed.
- balance = valid payments - active charges (negative = debt), computed
- teacher pay: per teacher, with an optional per-group override, either a
  percent of the payments allocated in the month or a fixed monthly amount
"""

import json
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from fastapi import HTTPException, status

from .. import clock
from ..config import settings as app_config
from . import rules

PAYMENT_METHODS = ("cash", "card", "click_payme")
SALARY_METHODS = ("percent", "fixed")
FIXED_SALARY_LABEL = "Qat'iy oylik"

_LOCK_STUDENT = 7001
_LOCK_MONTHS = 7002
_LOCK_PAYOUT = 7003


# --- Settings and audit ---------------------------------------------------------------


@dataclass
class MoneySettings:
    trial_limit_per_person: int = 1


async def get_settings(conn) -> MoneySettings:
    row = await conn.fetchrow("select * from app_settings")
    if row is None:
        return MoneySettings()
    return MoneySettings(row["trial_limit_per_person"])


async def audit(conn, user_id, entity: str, entity_id, action: str, reason=None, before=None, after=None) -> None:
    await conn.execute(
        "insert into audit_log (user_id, entity, entity_id, action, reason, before, after) "
        "values ($1, $2, $3, $4, $5, $6::jsonb, $7::jsonb)",
        user_id,
        entity,
        entity_id,
        action,
        reason,
        None if before is None else json.dumps(before, default=str),
        None if after is None else json.dumps(after, default=str),
    )


async def update_settings(conn, user_id: int, *, trial_limit_per_person: int | None = None) -> MoneySettings:
    current = await get_settings(conn)
    new = MoneySettings(
        trial_limit_per_person if trial_limit_per_person is not None else current.trial_limit_per_person
    )
    if new.trial_limit_per_person < 1:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Sinov darslari soni kamida 1 bo'lsin.")
    async with conn.transaction():
        await conn.execute(
            """
            insert into app_settings (id, trial_limit_per_person, updated_by, updated_at)
            values (true, $1, $2, now())
            on conflict (id) do update set trial_limit_per_person = $1, updated_by = $2, updated_at = now()
            """,
            new.trial_limit_per_person,
            user_id,
        )
        await audit(conn, user_id, "settings", None, "update", before=current.__dict__, after=new.__dict__)
    return new


# --- Locks and months -----------------------------------------------------------------------


async def _lock_student(conn, student_id: int) -> None:
    """One money change per student at a time -- allocation reads then writes."""
    await conn.execute("select pg_advisory_xact_lock($1, $2)", _LOCK_STUDENT, student_id)


def _center_month(moment: datetime) -> date:
    return rules.month_start(moment.astimezone(ZoneInfo(app_config.center_timezone)).date())


async def _open_month(conn, month: date) -> date:
    """`month`, or the first later month that isn't closed -- closed months
    never change, so money that would land in one counts in the next open
    month. Shares a lock with closing, so a month can't close halfway
    through an allocation."""
    await conn.execute("select pg_advisory_xact_lock_shared($1, 0)", _LOCK_MONTHS)
    while await conn.fetchval("select 1 from salary_months where month = $1", month):
        month = rules.next_month(month)
    return month


# --- Charges -----------------------------------------------------------------------------------


async def _student_of(conn, enrollment_id: int) -> int:
    student_id = await conn.fetchval("select student_id from enrollments where id = $1", enrollment_id)
    if student_id is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Yozilish topilmadi.")
    return student_id


async def create_charge(
    conn, *, enrollment_id: int, period_start: date, period_end: date, amount: int, base_fee: int,
    discount_amount: int = 0, is_prorated: bool = False, user_id: int | None = None, note: str | None = None,
) -> int | None:
    """The charge for one enrollment and billing period; None (nothing
    happens) if that period already has one. Pays itself from any credit
    the student has."""
    student_id = await _student_of(conn, enrollment_id)
    async with conn.transaction():
        await _lock_student(conn, student_id)
        charge_id = await conn.fetchval(
            """
            insert into charges (enrollment_id, period_start, period_end, due_date, amount, base_fee,
                                 discount_amount, is_prorated, note, created_by)
            select $1, $2, $3, $2, $4, $5, $6, $7, $8, $9
            where not exists (select 1 from charges where enrollment_id = $1 and period_start = $2)
            returning id
            """,
            enrollment_id, period_start, period_end, amount, base_fee, discount_amount, is_prorated, note, user_id,
        )
        if charge_id is not None:
            await apply_credit(conn, student_id)
    return charge_id


def _fee_parts(group, enrollment) -> tuple[int, int]:
    """(discounted fee, discount amount) for one enrollment of a group."""
    fee = rules.discounted_fee(group["fee_amount"], enrollment["discount_kind"], enrollment["discount_value"])
    return fee, group["fee_amount"] - fee


async def issue_first_charge(conn, enrollment: dict, group: dict, user_id: int | None, mode: str | None = None) -> int:
    """The charge for the first billing period of a new enrollment; returns
    its amount. `mode` 'full' or 'prorated' is the person's choice for this
    student; None follows the group's prorate_first_period."""
    if mode not in (None, "prorated", "full"):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Birinchi oy turi noto'g'ri.")
    prorate = group["prorate_first_period"] if mode is None else mode == "prorated"
    period = rules.billing_periods(
        group["billing_mode"], group["billing_day"], enrollment["joined_at"], enrollment["joined_at"],
        prorate_first=prorate,
    )[0]
    fee, discount = _fee_parts(group, enrollment)
    amount = period.amount(fee)
    await create_charge(
        conn,
        enrollment_id=enrollment["id"],
        period_start=period.start,
        period_end=period.end,
        amount=amount,
        base_fee=group["fee_amount"],
        discount_amount=discount,
        is_prorated=period.prorated,
        user_id=user_id,
    )
    return amount


async def generate_charges(conn, as_of: date) -> int:
    """Creates every charge due on or before `as_of` that doesn't exist yet;
    returns how many. Safe to run any number of times, from any number of
    workers. A cancelled charge is not made again."""
    rows = await conn.fetch(
        """
        select e.id, e.joined_at, e.ended_at, e.discount_kind, e.discount_value,
               g.fee_amount, g.billing_mode, g.billing_day, g.prorate_first_period
        from enrollments e join groups g on g.id = e.group_id
        where e.status = 'active' or e.ended_at is not null
        """
    )
    have = {
        (r["enrollment_id"], r["period_start"])
        for r in await conn.fetch("select enrollment_id, period_start from charges")
    }
    # Billing resumes where the last charge ended, whatever the grid says:
    # a group's rule never makes old periods bill again.
    covered_until = {
        r["enrollment_id"]: r["last_end"]
        for r in await conn.fetch("select enrollment_id, max(period_end) as last_end from charges group by 1")
    }
    created = 0
    for row in rows:
        fee, discount = _fee_parts(row, row)
        periods = rules.billing_periods(
            row["billing_mode"], row["billing_day"], row["joined_at"], as_of, row["ended_at"],
            row["prorate_first_period"],
        )
        for period in periods:
            if (row["id"], period.start) in have or period.start > as_of:
                continue
            if period.start < covered_until.get(row["id"], date.min):
                continue
            charge_id = await create_charge(
                conn,
                enrollment_id=row["id"],
                period_start=period.start,
                period_end=period.end,
                amount=period.amount(fee),
                base_fee=row["fee_amount"],
                discount_amount=discount,
                is_prorated=period.prorated,
            )
            if charge_id is not None:
                created += 1
    return created


async def next_due_dates(conn, enrollment_ids: list[int], today: date | None = None) -> dict[int, date | None]:
    """When each enrollment's next charge falls due (today counts), or None
    once it has ended -- from the group's billing rule."""
    today = today or clock.today()
    rows = await conn.fetch(
        """
        select e.id, e.joined_at, e.ended_at, g.billing_mode, g.billing_day, g.prorate_first_period
        from enrollments e join groups g on g.id = e.group_id
        where e.id = any($1::bigint[])
        """,
        enrollment_ids,
    )
    return {
        r["id"]: rules.next_due_date(
            r["billing_mode"], r["billing_day"], r["joined_at"], today, r["ended_at"], r["prorate_first_period"]
        )
        for r in rows
    }


async def cancel_charge(conn, charge_id: int, reason: str, user_id: int | None) -> None:
    """Cancels a charge. Anything already paid towards it goes back to the
    student as credit (and pays their next debt, if any)."""
    reason = (reason or "").strip()
    if not reason:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Sababini yozing.")
    student_id = await conn.fetchval(
        "select e.student_id from charges c join enrollments e on e.id = c.enrollment_id where c.id = $1",
        charge_id,
    )
    if student_id is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "To'lov talabi topilmadi.")
    async with conn.transaction():
        await _lock_student(conn, student_id)
        changed = await conn.fetchval(
            "update charges set status = 'cancelled', cancelled_at = now(), cancelled_by = $2, cancel_reason = $3 "
            "where id = $1 and status = 'active' returning id",
            charge_id, user_id, reason,
        )
        if changed is None:
            raise HTTPException(status.HTTP_409_CONFLICT, "To'lov talabi allaqachon bekor qilingan.")
        await _reverse_allocations(conn, "charge_id = $1", charge_id)
        await audit(conn, user_id, "charge", charge_id, "cancel", reason=reason)
        await apply_credit(conn, student_id)


async def cancel_charges_after(conn, enrollment_id: int, ended_at: date, reason: str, user_id: int | None) -> int:
    """When a student leaves: cancels the charges for periods that start on
    or after the day they left (so leaving the day you started owes
    nothing). The period they were in stays charged, and old charges stay.
    Returns how many were cancelled."""
    ids = await conn.fetch(
        "select id from charges where enrollment_id = $1 and status = 'active' and period_start >= $2",
        enrollment_id, ended_at,
    )
    for row in ids:
        await cancel_charge(conn, row["id"], reason, user_id)
    return len(ids)


# --- Payments and allocation ----------------------------------------------------------------


async def _reverse_allocations(conn, where: str, *args) -> None:
    """Adds negative allocation rows cancelling out what `where` selects
    (net per payment and charge). They count in the current open month."""
    month = await _open_month(conn, _center_month(datetime.now(ZoneInfo("UTC"))))
    await conn.execute(
        f"""
        insert into payment_allocations (payment_id, charge_id, amount, teacher_id, group_id, counts_in_month)
        select payment_id, charge_id, -sum(amount), (array_agg(teacher_id order by id desc))[1],
               (array_agg(group_id order by id desc))[1], ${len(args) + 1}
        from payment_allocations where {where}
        group by payment_id, charge_id having sum(amount) > 0
        """,
        *args, month,
    )


async def apply_credit(conn, student_id: int) -> None:
    """Pays the student's oldest unpaid charges from whatever their valid
    payments still have unallocated. Run after any payment, charge or
    cancellation; does nothing when there is nothing to pay or nothing to
    pay with.

    Each branch is its own ledger: a payment only ever pays charges of the
    branch it was taken in, and what is left of it waits as that branch's
    credit."""
    await _lock_student(conn, student_id)
    payments = await conn.fetch(
        """
        select p.id, p.branch_id, p.received_at, p.amount - coalesce(sum(a.amount), 0) as available
        from payments p left join payment_allocations a on a.payment_id = p.id
        where p.student_id = $1 and p.kind = 'payment' and p.status = 'valid'
        group by p.id
        having p.amount - coalesce(sum(a.amount), 0) > 0
        order by p.received_at, p.id
        """,
        student_id,
    )
    if not payments:
        return
    unpaid_by_branch: dict[int, list[list]] = {}
    for row in await conn.fetch(
        """
        select cb.charge_id, cb.owed, cb.group_id, g.teacher_id, g.branch_id
        from charge_balances cb join groups g on g.id = cb.group_id
        where cb.student_id = $1 and cb.status = 'active' and cb.owed > 0
        order by cb.period_start, cb.charge_id
        """,
        student_id,
    ):
        unpaid_by_branch.setdefault(row["branch_id"], []).append(
            [row["charge_id"], row["owed"], row["group_id"], row["teacher_id"]]
        )
    for payment in payments:
        unpaid = unpaid_by_branch.get(payment["branch_id"], [])
        spread, _ = rules.allocate(payment["available"], [(u[0], u[1]) for u in unpaid])
        if not spread:
            continue
        month = await _open_month(conn, _center_month(payment["received_at"]))
        for charge_id, amount in spread:
            entry = next(u for u in unpaid if u[0] == charge_id)
            entry[1] -= amount
            await conn.execute(
                "insert into payment_allocations (payment_id, charge_id, amount, teacher_id, group_id, counts_in_month) "
                "values ($1, $2, $3, $4, $5, $6)",
                payment["id"], charge_id, amount, entry[3], entry[2], month,
            )


async def record_payment(
    conn, *, student_id: int, amount: int, method: str, user_id: int | None,
    enrollment_id: int | None = None, received_at: datetime | None = None, note: str | None = None,
    branch_id: int | None = None,
) -> dict:
    """Takes a payment and allocates it. Returns the payment row, with the
    receipt number and how much of it paid charges versus became credit."""
    if amount <= 0:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Summa musbat bo'lishi kerak.")
    if method not in PAYMENT_METHODS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "To'lov usulini tanlang.")
    if not await conn.fetchval("select 1 from students where id = $1", student_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "O'quvchi topilmadi.")
    if enrollment_id is not None:
        # The branch of the group it was handed over for.
        group_branch = await conn.fetchval(
            "select g.branch_id from enrollments e join groups g on g.id = e.group_id "
            "where e.id = $1 and e.student_id = $2",
            enrollment_id, student_id,
        )
        if group_branch is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Yozilish topilmadi.")
        branch_id = group_branch
    elif branch_id is None:
        # No group named and no branch given: the student's own branch
        # (the first one, if he has several), else the headquarters.
        branch_id = await conn.fetchval(
            "select coalesce((select min(branch_id) from student_branches where student_id = $1), "
            "(select id from branches where is_headquarters))",
            student_id,
        )
    await conn.execute(
        "insert into student_branches (student_id, branch_id) values ($1, $2) on conflict do nothing",
        student_id, branch_id,
    )
    async with conn.transaction():
        await _lock_student(conn, student_id)
        payment = await conn.fetchrow(
            """
            insert into payments (student_id, enrollment_id, amount, method, received_by, received_at, receipt_no,
                                  note, branch_id)
            values ($1, $2, $3, $4, $5, coalesce($6, now()),
                    'R-' || lpad(nextval('payment_receipt_seq')::text, 6, '0'), $7, $8)
            returning *
            """,
            student_id, enrollment_id, amount, method, user_id, received_at, (note or "").strip() or None, branch_id,
        )
        await apply_credit(conn, student_id)
        allocated = await conn.fetchval(
            "select coalesce(sum(amount), 0) from payment_allocations where payment_id = $1", payment["id"]
        )
    return {**dict(payment), "allocated": allocated, "credit": amount - allocated}


async def cancel_payment(conn, payment_id: int, reason: str, user_id: int | None) -> dict:
    """Cancels a payment: it is marked cancelled and a reversal row records
    the money going back. What it had paid becomes unpaid again."""
    reason = (reason or "").strip()
    if not reason:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Sababini yozing.")
    payment = await conn.fetchrow("select * from payments where id = $1", payment_id)
    if payment is None or payment["kind"] != "payment":
        raise HTTPException(status.HTTP_404_NOT_FOUND, "To'lov topilmadi.")
    async with conn.transaction():
        await _lock_student(conn, payment["student_id"])
        changed = await conn.fetchval(
            "update payments set status = 'cancelled', cancelled_at = now(), cancelled_by = $2, cancel_reason = $3 "
            "where id = $1 and status = 'valid' returning id",
            payment_id, user_id, reason,
        )
        if changed is None:
            raise HTTPException(status.HTTP_409_CONFLICT, "To'lov allaqachon bekor qilingan.")
        reversal = await conn.fetchrow(
            """
            insert into payments (student_id, enrollment_id, kind, amount, method, received_by, reverses_id, reason,
                                  branch_id)
            values ($1, $2, 'reversal', $3, $4, $5, $6, $7, $8)
            returning *
            """,
            payment["student_id"], payment["enrollment_id"], payment["amount"], payment["method"],
            user_id, payment_id, reason, payment["branch_id"],
        )
        await _reverse_allocations(conn, "payment_id = $1", payment_id)
        await audit(
            conn, user_id, "payment", payment_id, "cancel", reason=reason,
            before={"amount": payment["amount"], "receipt_no": payment["receipt_no"]},
        )
        await apply_credit(conn, payment["student_id"])
    return dict(reversal)


# --- Reading balances --------------------------------------------------------------------------


async def student_balance(conn, student_id: int) -> dict:
    """{'paid', 'charged', 'balance'}: balance = paid - charged, so negative is debt."""
    row = await conn.fetchrow("select paid, charged, balance from student_balances where student_id = $1", student_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "O'quvchi topilmadi.")
    return dict(row)


async def monthly_plan(conn, month: date, ids: list[int] | None = None) -> int:
    """What the center expects to bill in `month`: every active enrollment's
    charges for periods starting in it, as made or -- if not made yet --
    as they will be."""
    month = rules.month_start(month)
    month_end = rules.next_month(month)
    rows = await conn.fetch(
        """
        select e.id, e.joined_at, e.discount_kind, e.discount_value,
               g.fee_amount, g.billing_mode, g.billing_day, g.prorate_first_period
        from enrollments e join groups g on g.id = e.group_id
        where e.status = 'active' and ($1::bigint[] is null or g.branch_id = any($1::bigint[]))
        """,
        ids,
    )
    charged = {
        (r["enrollment_id"], r["period_start"]): r["amount"]
        for r in await conn.fetch(
            "select enrollment_id, period_start, amount from charges "
            "where status = 'active' and period_start >= $1 and period_start < $2",
            month, month_end,
        )
    }
    total = 0
    for row in rows:
        fee = rules.discounted_fee(row["fee_amount"], row["discount_kind"], row["discount_value"])
        for period in rules.billing_periods(
            row["billing_mode"], row["billing_day"], row["joined_at"], month_end - timedelta(days=1),
            None, row["prorate_first_period"],
        ):
            if month <= period.start < month_end:
                total += charged.get((row["id"], period.start), period.amount(fee))
    return total


async def debt_age(conn, student_id: int, today: date | None = None) -> dict | None:
    """The student's oldest unpaid charge: {'due_date', 'days_overdue',
    'bucket'}, or None when nothing is unpaid."""
    due = await conn.fetchval(
        "select min(due_date) from charge_balances where student_id = $1 and status = 'active' and owed > 0",
        student_id,
    )
    if due is None:
        return None
    days = max(((today or clock.today()) - due).days, 0)
    return {"due_date": due, "days_overdue": days, "bucket": rules.debt_bucket(days)}


# --- Teacher pay -----------------------------------------------------------------------------------


def _check_rule(method: str | None, percent, fixed) -> tuple[str | None, object, int | None]:
    """The (method, percent, fixed) to store: only what the method uses."""
    if method is None:
        return None, None, None
    if method not in SALARY_METHODS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Oylik turi noto'g'ri.")
    if method == "percent":
        if percent is None or not 0 <= percent <= 100:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Foiz 0 dan 100 gacha bo'lsin.")
        return method, percent, None
    if fixed is None or fixed < 0:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Qat'iy oylik summasi manfiy bo'lmasin.")
    return method, None, int(fixed)


def _rule_json(row) -> dict:
    return {
        "salary_method": row["salary_method"],
        "salary_percent": None if row["salary_percent"] is None else float(row["salary_percent"]),
        "salary_fixed": row["salary_fixed"],
    }


async def set_teacher_rule(conn, teacher_id: int, method: str | None, percent, fixed, user_id: int | None) -> None:
    """How this teacher is paid: a percent, a fixed monthly amount, or (None)
    not by the center's rules at all. Groups may override it."""
    method, percent, fixed = _check_rule(method, percent, fixed)
    async with conn.transaction():
        before = await conn.fetchrow(
            "select salary_method, salary_percent, salary_fixed from teachers where id = $1", teacher_id
        )
        if before is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "O'qituvchi topilmadi.")
        await conn.execute(
            "update teachers set salary_method = $2, salary_percent = $3, salary_fixed = $4 where id = $1",
            teacher_id, method, percent, fixed,
        )
        await audit(
            conn, user_id, "teacher", teacher_id, "set_salary_rule", before=_rule_json(before),
            after={"salary_method": method, "salary_percent": percent, "salary_fixed": fixed},
        )


async def set_group_rule(conn, group_id: int, method: str | None, percent, fixed, user_id: int | None) -> None:
    """This group's own pay rule, which wins over its teacher's; None goes
    back to following the teacher."""
    method, percent, fixed = _check_rule(method, percent, fixed)
    async with conn.transaction():
        before = await conn.fetchrow(
            "select salary_method, salary_percent, salary_fixed from groups where id = $1", group_id
        )
        if before is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Guruh topilmadi.")
        await conn.execute(
            "update groups set salary_method = $2, salary_percent = $3, salary_fixed = $4 where id = $1",
            group_id, method, percent, fixed,
        )
        await audit(
            conn, user_id, "group", group_id, "set_salary_rule", before=_rule_json(before),
            after={"salary_method": method, "salary_percent": percent, "salary_fixed": fixed},
        )


async def set_teacher_percent(conn, teacher_id: int, percent, user_id: int | None) -> None:
    """Shortcut for the common case: a percent (None = no rule)."""
    await set_teacher_rule(conn, teacher_id, None if percent is None else "percent", percent, None, user_id)


async def set_group_percent(conn, group_id: int, percent, user_id: int | None) -> None:
    await set_group_rule(conn, group_id, None if percent is None else "percent", percent, None, user_id)


def _effective_rule(row) -> tuple[str | None, object, int | None]:
    """The rule that applies to a group's money: the group's own if it has
    one, else its teacher's."""
    if row["g_method"] is not None:
        return row["g_method"], row["g_percent"], row["g_fixed"]
    return row["t_method"], row["t_percent"], row["t_fixed"]


async def _live_lines(conn, month: date) -> list[dict]:
    # Every line carries its branch: a percent line the branch of the group
    # the money was paid for, a fixed salary the teacher's home branch (the
    # first one they are linked to), a group's own fixed pay its group's.
    """The month's pay lines, worked out now: a share of each student's
    payments where the rule is a percent, and the fixed amounts. Fixed pay
    accrues for the month whether or not anyone paid, from the month the
    teacher (or group) existed -- never for months still to come."""
    rows = await conn.fetch(
        """
        select a.teacher_id, e.student_id, s.full_name as student_name, a.group_id, g.name as group_name,
               g.branch_id, sum(a.amount)::bigint as collected,
               g.salary_method as g_method, g.salary_percent as g_percent, g.salary_fixed as g_fixed,
               t.salary_method as t_method, t.salary_percent as t_percent, t.salary_fixed as t_fixed
        from payment_allocations a
        join charges c on c.id = a.charge_id
        join enrollments e on e.id = c.enrollment_id
        join students s on s.id = e.student_id
        join groups g on g.id = a.group_id
        join teachers t on t.id = a.teacher_id
        where a.counts_in_month = $1
        group by a.teacher_id, e.student_id, s.full_name, a.group_id, g.name, g.branch_id,
                 g.salary_method, g.salary_percent, g.salary_fixed,
                 t.salary_method, t.salary_percent, t.salary_fixed
        having sum(a.amount) <> 0
        order by s.full_name, g.name
        """,
        month,
    )
    lines = []
    for r in rows:
        method, percent, _ = _effective_rule(r)
        used = float(percent) if method == "percent" and percent is not None else None
        lines.append({
            "teacher_id": r["teacher_id"], "student_id": r["student_id"], "student_name": r["student_name"],
            "group_id": r["group_id"], "group_name": r["group_name"], "collected": r["collected"],
            "branch_id": r["branch_id"], "percent": used, "method": "percent",
            "share": rules.salary_share(r["collected"], percent) if method == "percent" else 0,
        })

    if month <= rules.month_start(clock.today()):
        month_end = rules.next_month(month)
        # A teacher paid a fixed amount: once a month, whatever their groups.
        for t in await conn.fetch(
            """
            select t.id, t.salary_fixed,
                   coalesce((select min(tb.branch_id) from teacher_branches tb where tb.teacher_id = t.id),
                            (select id from branches where is_headquarters)) as branch_id
            from teachers t
            where t.salary_method = 'fixed' and t.salary_fixed is not null and t.is_active
              and (t.created_at at time zone $2)::date < $1
            """,
            month_end, app_config.center_timezone,
        ):
            lines.append({
                "teacher_id": t["id"], "student_id": None, "student_name": FIXED_SALARY_LABEL,
                "group_id": None, "group_name": "", "collected": 0, "percent": None,
                "branch_id": t["branch_id"], "method": "fixed", "share": t["salary_fixed"],
            })
        # A group paid a fixed amount of its own, to the group's teacher.
        for g in await conn.fetch(
            """
            select id, name, teacher_id, salary_fixed, branch_id from groups
            where salary_method = 'fixed' and salary_fixed is not null and is_active and teacher_id is not null
              and (created_at at time zone $2)::date < $1
            """,
            month_end, app_config.center_timezone,
        ):
            lines.append({
                "teacher_id": g["teacher_id"], "student_id": None, "student_name": FIXED_SALARY_LABEL,
                "group_id": g["id"], "group_name": g["name"], "collected": 0, "percent": None,
                "branch_id": g["branch_id"], "method": "fixed", "share": g["salary_fixed"],
            })
    return lines


async def salary_month(conn, month: date, ids: list[int] | None = None) -> dict:
    """Every teacher's pay for a month: lines, what they earned, what has
    been paid out and what remains. A closed month comes from its frozen
    snapshot; an open one is worked out now. `ids` are the branches to count
    (None = all): each branch's pay is worked out and paid on its own."""
    month = rules.month_start(month)
    closed = await conn.fetchval("select closed_at from salary_months where month = $1", month)
    if closed is not None:
        lines = [
            dict(r)
            for r in await conn.fetch(
                """
                select r.teacher_id, l.student_id, l.student_name, l.group_id, l.group_name, l.collected,
                       l.branch_id, l.percent::float8 as percent, l.method, l.share
                from salary_run_lines l join salary_runs r on r.id = l.run_id
                where r.month = $1 order by l.method, l.student_name, l.group_name
                """,
                month,
            )
        ]
        runs = {r["teacher_id"] for r in await conn.fetch("select teacher_id from salary_runs where month = $1", month)}
    else:
        lines = await _live_lines(conn, month)
        runs = set()
    if ids is not None:
        lines = [l for l in lines if l["branch_id"] in ids]
    paid = {
        r["teacher_id"]: r["total"]
        for r in await conn.fetch(
            "select teacher_id, sum(amount)::bigint as total from salary_payouts "
            "where month = $1 and voided_at is null and ($2::bigint[] is null or branch_id = any($2::bigint[])) "
            "group by teacher_id",
            month, ids,
        )
    }
    teachers = await conn.fetch(
        """
        select t.id, t.full_name, t.is_active, t.salary_method, t.salary_percent, t.salary_fixed from teachers t
        where (t.is_active and ($2::bigint[] is null or exists (
                 select 1 from teacher_branches tb where tb.teacher_id = t.id and tb.branch_id = any($2::bigint[]))))
           or t.id = any($1::bigint[])
        order by t.full_name
        """,
        list({l["teacher_id"] for l in lines} | set(paid) | (runs if ids is None else set())),
        ids,
    )
    result = []
    for teacher in teachers:
        own = [l for l in lines if l["teacher_id"] == teacher["id"]]
        earned = sum(l["share"] for l in own)
        taken = paid.get(teacher["id"], 0)
        result.append({
            "teacher_id": teacher["id"],
            "full_name": teacher["full_name"],
            "is_active": teacher["is_active"],
            "salary_method": teacher["salary_method"],
            "salary_percent": None if teacher["salary_percent"] is None else float(teacher["salary_percent"]),
            "salary_fixed": teacher["salary_fixed"],
            "collected": sum(l["collected"] for l in own),
            "earned": earned,
            "paid": taken,
            "remaining": earned - taken,
            "lines": own,
        })
    return {
        "month": month,
        "closed": closed is not None,
        "teachers": result,
        "total_earned": sum(t["earned"] for t in result),
        "total_paid": sum(t["paid"] for t in result),
        "total_remaining": sum(t["remaining"] for t in result),
    }


async def close_month(conn, month: date, user_id: int | None) -> dict:
    """"Oyni yopish": freezes the month's pay figures -- every line, with
    the rule it used. After this the month is read from the snapshot, and
    money that would land in it counts in the next open month instead."""
    month = rules.month_start(month)
    if month > rules.month_start(clock.today()):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Kelajak oyini yopib bo'lmaydi.")
    async with conn.transaction():
        await conn.execute("select pg_advisory_xact_lock($1, 0)", _LOCK_MONTHS)
        if await conn.fetchval("select 1 from salary_months where month = $1", month):
            raise HTTPException(status.HTTP_409_CONFLICT, "Bu oy allaqachon yopilgan.")
        report = await salary_month(conn, month)
        await conn.execute("insert into salary_months (month, closed_by) values ($1, $2)", month, user_id)
        for teacher in report["teachers"]:
            if not teacher["lines"]:
                continue
            run_id = await conn.fetchval(
                "insert into salary_runs (month, teacher_id, collected, earned) values ($1, $2, $3, $4) returning id",
                month, teacher["teacher_id"], teacher["collected"], teacher["earned"],
            )
            for line in teacher["lines"]:
                await conn.execute(
                    "insert into salary_run_lines (run_id, student_id, student_name, group_id, group_name, collected, "
                    "percent, method, share, branch_id) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
                    run_id, line["student_id"], line["student_name"], line["group_id"], line["group_name"],
                    line["collected"], line["percent"], line["method"], line["share"], line["branch_id"],
                )
        await audit(conn, user_id, "salary_month", None, "close", after={"month": month, "earned": report["total_earned"]})
    return await salary_month(conn, month)


async def record_payout(
    conn, *, teacher_id: int, month: date, amount: int, paid_on: date, method: str | None,
    note: str | None, user_id: int | None, branch_id: int | None = None,
) -> dict:
    """Pays a teacher for a month. Two rules: only against a **closed**
    month (the figures are frozen, so there is a definite amount owed), and
    never more than what is still owed for it. Also writes the expense row,
    so the cash that left shows in the center's profit, and an audit entry.

    Each branch pays its own part: what is still owed is that branch's lines
    minus what that branch already paid."""
    if amount <= 0:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Summa musbat bo'lishi kerak.")
    if method is not None and method not in PAYMENT_METHODS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "To'lov usuli noto'g'ri.")
    if not await conn.fetchval("select 1 from teachers where id = $1", teacher_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "O'qituvchi topilmadi.")
    month = rules.month_start(month)
    if branch_id is None:
        branch_id = await conn.fetchval("select id from branches where is_headquarters")
    async with conn.transaction():
        # Two payouts for the same teacher at once must not both pass the check.
        await conn.execute("select pg_advisory_xact_lock($1, $2)", _LOCK_PAYOUT, teacher_id)
        if not await conn.fetchval("select 1 from salary_months where month = $1", month):
            raise HTTPException(
                status.HTTP_409_CONFLICT, "Oylik faqat yopilgan oy uchun to'lanadi. Avval oyni yoping."
            )
        report = await salary_month(conn, month, [branch_id])
        teacher = next((t for t in report["teachers"] if t["teacher_id"] == teacher_id), None)
        remaining = 0 if teacher is None else teacher["remaining"]
        if amount > remaining:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"To'lov qoldiqdan oshib ketdi: bu oy uchun {max(remaining, 0)} so'm qolgan.",
            )
        expense_id = await conn.fetchval(
            "insert into expenses (category, amount, spent_on, note, method, teacher_id, salary_month, created_by, "
            "branch_id) values ('salary', $1, $2, $3, $4, $5, $6, $7, $8) returning id",
            amount, paid_on, note, method, teacher_id, month, user_id, branch_id,
        )
        payout_id = await conn.fetchval(
            "insert into salary_payouts (teacher_id, month, amount, paid_on, method, note, expense_id, paid_by, "
            "branch_id) values ($1, $2, $3, $4, $5, $6, $7, $8, $9) returning id",
            teacher_id, month, amount, paid_on, method, note, expense_id, user_id, branch_id,
        )
        await audit(
            conn, user_id, "salary_payout", payout_id, "create",
            after={"teacher_id": teacher_id, "month": month, "amount": amount, "remaining_before": remaining},
        )
    return {"id": payout_id, "expense_id": expense_id}


async def void_payout_for_expense(conn, expense_id: int, reason: str, user_id: int | None) -> None:
    payout_id = await conn.fetchval(
        "update salary_payouts set voided_at = now(), voided_by = $2, void_reason = $3 "
        "where expense_id = $1 and voided_at is null returning id",
        expense_id, user_id, reason,
    )
    if payout_id is not None:
        await audit(conn, user_id, "salary_payout", payout_id, "void", reason=reason)
