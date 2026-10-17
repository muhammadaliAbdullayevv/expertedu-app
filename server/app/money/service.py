"""Everything that changes or reads money, in one place.

Routes call these; widgets never compute money. Functions take an asyncpg
connection and, for writes, expect to run inside the caller's transaction
(each opens its own nested one where it needs to be atomic on its own).

Money rules in short -- see docs/DOMAIN.md:
- charges: one per enrollment per month; cancelled with a reason, never deleted
- payments: cancelled by a reversal row with a reason, never deleted
- allocation: a student's payments pay their oldest unpaid charge first;
  what is left is credit. Allocations are append-only and signed.
- balance = valid payments - active charges (negative = debt), computed
- salary: a teacher's percent of the allocations that count in a month
"""

import json
from dataclasses import dataclass
from datetime import date, datetime
from zoneinfo import ZoneInfo

from fastapi import HTTPException, status

from .. import clock
from ..config import settings as app_config
from . import rules

PAYMENT_METHODS = ("cash", "card", "click_payme")

_LOCK_STUDENT = 7001
_LOCK_MONTHS = 7002


# --- Settings and audit ---------------------------------------------------------------


@dataclass
class MoneySettings:
    billing_day: int = 1
    first_month_mode: str = "prorated"
    trial_limit_per_person: int = 1


async def get_settings(conn) -> MoneySettings:
    row = await conn.fetchrow("select * from app_settings")
    if row is None:
        return MoneySettings()
    return MoneySettings(row["billing_day"], row["first_month_mode"], row["trial_limit_per_person"])


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


async def update_settings(
    conn, user_id: int, *, billing_day: int | None = None, first_month_mode: str | None = None,
    trial_limit_per_person: int | None = None,
) -> MoneySettings:
    current = await get_settings(conn)
    new = MoneySettings(
        billing_day if billing_day is not None else current.billing_day,
        first_month_mode if first_month_mode is not None else current.first_month_mode,
        trial_limit_per_person if trial_limit_per_person is not None else current.trial_limit_per_person,
    )
    if not 1 <= new.billing_day <= 28:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Hisob-kitob kuni 1 dan 28 gacha bo'lsin.")
    if new.first_month_mode not in rules.FIRST_MONTH_MODES:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Birinchi oy turi noto'g'ri.")
    if new.trial_limit_per_person < 1:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Sinov darslari soni kamida 1 bo'lsin.")
    async with conn.transaction():
        await conn.execute(
            """
            insert into app_settings (id, billing_day, first_month_mode, trial_limit_per_person, updated_by, updated_at)
            values (true, $1, $2, $3, $4, now())
            on conflict (id) do update set billing_day = $1, first_month_mode = $2,
              trial_limit_per_person = $3, updated_by = $4, updated_at = now()
            """,
            new.billing_day,
            new.first_month_mode,
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
    conn, *, enrollment_id: int, month: date, due_date: date, amount: int, base_fee: int,
    discount_amount: int = 0, is_prorated: bool = False, user_id: int | None = None, note: str | None = None,
) -> int | None:
    """The charge for one enrollment and month; None (nothing happens) if
    that month already has one. Pays itself from any credit the student has."""
    student_id = await _student_of(conn, enrollment_id)
    async with conn.transaction():
        await _lock_student(conn, student_id)
        charge_id = await conn.fetchval(
            """
            insert into charges (enrollment_id, period_month, due_date, amount, base_fee, discount_amount,
                                 is_prorated, note, created_by)
            select $1, $2, $3, $4, $5, $6, $7, $8, $9
            where not exists (select 1 from charges where enrollment_id = $1 and period_month = $2)
            returning id
            """,
            enrollment_id, month, due_date, amount, base_fee, discount_amount, is_prorated, note, user_id,
        )
        if charge_id is not None:
            await apply_credit(conn, student_id)
    return charge_id


async def issue_first_charge(conn, enrollment: dict, group: dict, user_id: int | None, mode: str | None = None) -> int:
    """The charge for the month a student starts in; returns its amount.
    `mode` is 'prorated' or 'full', or None for the center's setting."""
    mode = mode or (await get_settings(conn)).first_month_mode
    if mode not in rules.FIRST_MONTH_MODES:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Birinchi oy turi noto'g'ri.")
    fee = rules.discounted_fee(group["fee_amount"], enrollment["discount_kind"], enrollment["discount_value"])
    amount, prorated = rules.first_month_charge(fee, enrollment["joined_at"], mode)
    await create_charge(
        conn,
        enrollment_id=enrollment["id"],
        month=rules.month_start(enrollment["joined_at"]),
        due_date=enrollment["joined_at"],
        amount=amount,
        base_fee=group["fee_amount"],
        discount_amount=group["fee_amount"] - fee,
        is_prorated=prorated,
        user_id=user_id,
    )
    return amount


async def generate_charges(conn, as_of: date) -> int:
    """Creates every monthly charge due on or before `as_of` that doesn't
    exist yet; returns how many. Safe to run any number of times, from any
    number of workers. A cancelled charge is not made again."""
    config = await get_settings(conn)
    rows = await conn.fetch(
        """
        select e.id, e.student_id, e.joined_at, e.ended_at, e.discount_kind, e.discount_value, g.fee_amount
        from enrollments e join groups g on g.id = e.group_id
        where e.status = 'active' or e.ended_at is not null
        """
    )
    have = {
        (r["enrollment_id"], r["period_month"])
        for r in await conn.fetch("select enrollment_id, period_month from charges")
    }
    created = 0
    for row in rows:
        fee = rules.discounted_fee(row["fee_amount"], row["discount_kind"], row["discount_value"])
        for month in rules.months_to_charge(row["joined_at"], as_of, config.billing_day, row["ended_at"]):
            if (row["id"], month) in have:
                continue
            charge_id = await create_charge(
                conn,
                enrollment_id=row["id"],
                month=month,
                due_date=rules.billing_date(month, config.billing_day),
                amount=fee,
                base_fee=row["fee_amount"],
                discount_amount=row["fee_amount"] - fee,
            )
            if charge_id is not None:
                created += 1
    return created


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
    """When a student leaves: cancels the charges for months after the one
    they left in, and one dated on or after the day they left (starting and
    leaving the same day owes nothing). Returns how many."""
    ids = await conn.fetch(
        "select id from charges where enrollment_id = $1 and status = 'active' "
        "and (period_month > $2 or due_date >= $3)",
        enrollment_id, rules.month_start(ended_at), ended_at,
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
    pay with."""
    await _lock_student(conn, student_id)
    payments = await conn.fetch(
        """
        select p.id, p.received_at, p.amount - coalesce(sum(a.amount), 0) as available
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
    unpaid = [
        [row["charge_id"], row["owed"], row["group_id"], row["teacher_id"]]
        for row in await conn.fetch(
            """
            select cb.charge_id, cb.owed, cb.group_id, g.teacher_id
            from charge_balances cb join groups g on g.id = cb.group_id
            where cb.student_id = $1 and cb.status = 'active' and cb.owed > 0
            order by cb.period_month, cb.charge_id
            """,
            student_id,
        )
    ]
    for payment in payments:
        spread, _ = rules.allocate(payment["available"], [(u[0], u[1]) for u in unpaid])
        if not spread:
            break
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
) -> dict:
    """Takes a payment and allocates it. Returns the payment row, with the
    receipt number and how much of it paid charges versus became credit."""
    if amount <= 0:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Summa musbat bo'lishi kerak.")
    if method not in PAYMENT_METHODS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "To'lov usulini tanlang.")
    if not await conn.fetchval("select 1 from students where id = $1", student_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "O'quvchi topilmadi.")
    if enrollment_id is not None and not await conn.fetchval(
        "select 1 from enrollments where id = $1 and student_id = $2", enrollment_id, student_id
    ):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Yozilish topilmadi.")
    async with conn.transaction():
        await _lock_student(conn, student_id)
        payment = await conn.fetchrow(
            """
            insert into payments (student_id, enrollment_id, amount, method, received_by, received_at, receipt_no, note)
            values ($1, $2, $3, $4, $5, coalesce($6, now()),
                    'R-' || lpad(nextval('payment_receipt_seq')::text, 6, '0'), $7)
            returning *
            """,
            student_id, enrollment_id, amount, method, user_id, received_at, (note or "").strip() or None,
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
            insert into payments (student_id, enrollment_id, kind, amount, method, received_by, reverses_id, reason)
            values ($1, $2, 'reversal', $3, $4, $5, $6, $7)
            returning *
            """,
            payment["student_id"], payment["enrollment_id"], payment["amount"], payment["method"],
            user_id, payment_id, reason,
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


async def monthly_plan(conn, month: date) -> int:
    """What the center expects to bill for `month`: each active enrollment's
    charge for it, or its discounted fee if the charge isn't made yet."""
    rows = await conn.fetch(
        """
        select e.discount_kind, e.discount_value, g.fee_amount, c.amount as charged
        from enrollments e
        join groups g on g.id = e.group_id
        left join charges c on c.enrollment_id = e.id and c.period_month = $1 and c.status = 'active'
        where e.status = 'active'
        """,
        rules.month_start(month),
    )
    return sum(
        r["charged"] if r["charged"] is not None
        else rules.discounted_fee(r["fee_amount"], r["discount_kind"], r["discount_value"])
        for r in rows
    )


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


# --- Teacher salary ------------------------------------------------------------------------------


async def set_teacher_percent(conn, teacher_id: int, percent, user_id: int | None) -> None:
    _check_percent(percent)
    async with conn.transaction():
        before = await conn.fetchval("select salary_percent from teachers where id = $1", teacher_id)
        if not await conn.fetchval("select 1 from teachers where id = $1", teacher_id):
            raise HTTPException(status.HTTP_404_NOT_FOUND, "O'qituvchi topilmadi.")
        await conn.execute("update teachers set salary_percent = $2 where id = $1", teacher_id, percent)
        await audit(conn, user_id, "teacher", teacher_id, "set_salary_percent", before={"percent": before}, after={"percent": percent})


async def set_group_percent(conn, group_id: int, percent, user_id: int | None) -> None:
    _check_percent(percent)
    async with conn.transaction():
        if not await conn.fetchval("select 1 from groups where id = $1", group_id):
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Guruh topilmadi.")
        before = await conn.fetchval("select salary_percent from groups where id = $1", group_id)
        await conn.execute("update groups set salary_percent = $2 where id = $1", group_id, percent)
        await audit(conn, user_id, "group", group_id, "set_salary_percent", before={"percent": before}, after={"percent": percent})


def _check_percent(percent) -> None:
    if percent is not None and not 0 <= percent <= 100:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Foiz 0 dan 100 gacha bo'lsin.")


async def _live_lines(conn, month: date) -> list[dict]:
    rows = await conn.fetch(
        """
        select a.teacher_id, e.student_id, s.full_name as student_name, a.group_id, g.name as group_name,
               sum(a.amount)::bigint as collected, coalesce(g.salary_percent, t.salary_percent) as percent
        from payment_allocations a
        join charges c on c.id = a.charge_id
        join enrollments e on e.id = c.enrollment_id
        join students s on s.id = e.student_id
        join groups g on g.id = a.group_id
        join teachers t on t.id = a.teacher_id
        where a.counts_in_month = $1
        group by a.teacher_id, e.student_id, s.full_name, a.group_id, g.name, g.salary_percent, t.salary_percent
        having sum(a.amount) <> 0
        order by s.full_name, g.name
        """,
        month,
    )
    return [
        {**dict(r), "percent": None if r["percent"] is None else float(r["percent"]),
         "share": rules.salary_share(r["collected"], r["percent"])}
        for r in rows
    ]


async def salary_month(conn, month: date) -> dict:
    """Every teacher's pay for a month: per-student lines, what they earned,
    what has been paid out and what remains. A closed month comes from its
    frozen snapshot; an open one is worked out now."""
    month = rules.month_start(month)
    closed = await conn.fetchval("select closed_at from salary_months where month = $1", month)
    if closed is not None:
        lines = [
            dict(r)
            for r in await conn.fetch(
                """
                select r.teacher_id, l.student_id, l.student_name, l.group_id, l.group_name, l.collected,
                       l.percent::float8 as percent, l.share
                from salary_run_lines l join salary_runs r on r.id = l.run_id
                where r.month = $1 order by l.student_name, l.group_name
                """,
                month,
            )
        ]
        runs = {r["teacher_id"] for r in await conn.fetch("select teacher_id from salary_runs where month = $1", month)}
    else:
        lines = await _live_lines(conn, month)
        runs = set()
    paid = {
        r["teacher_id"]: r["total"]
        for r in await conn.fetch(
            "select teacher_id, sum(amount)::bigint as total from salary_payouts "
            "where month = $1 and voided_at is null group by teacher_id",
            month,
        )
    }
    teachers = await conn.fetch(
        "select id, full_name, is_active, salary_percent from teachers where is_active or id = any($1::bigint[]) order by full_name",
        list({l["teacher_id"] for l in lines} | set(paid) | runs),
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
            "salary_percent": None if teacher["salary_percent"] is None else float(teacher["salary_percent"]),
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
    """"Oyni yopish": freezes the month's salary figures. After this the
    month is read from the snapshot, and money that would land in it counts
    in the next open month instead."""
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
                    "insert into salary_run_lines (run_id, student_id, student_name, group_id, group_name, collected, percent, share) "
                    "values ($1, $2, $3, $4, $5, $6, $7, $8)",
                    run_id, line["student_id"], line["student_name"], line["group_id"], line["group_name"],
                    line["collected"], line["percent"], line["share"],
                )
        await audit(conn, user_id, "salary_month", None, "close", after={"month": month, "earned": report["total_earned"]})
    return await salary_month(conn, month)


async def record_payout(
    conn, *, teacher_id: int, month: date, amount: int, paid_on: date, method: str | None,
    note: str | None, user_id: int | None,
) -> dict:
    """Pays a teacher for a month. Also writes the expense row, so the cash
    that left shows in the center's profit."""
    if amount <= 0:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Summa musbat bo'lishi kerak.")
    if method is not None and method not in PAYMENT_METHODS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "To'lov usuli noto'g'ri.")
    if not await conn.fetchval("select 1 from teachers where id = $1", teacher_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "O'qituvchi topilmadi.")
    month = rules.month_start(month)
    async with conn.transaction():
        expense_id = await conn.fetchval(
            "insert into expenses (category, amount, spent_on, note, method, teacher_id, salary_month, created_by) "
            "values ('salary', $1, $2, $3, $4, $5, $6, $7) returning id",
            amount, paid_on, note, method, teacher_id, month, user_id,
        )
        payout_id = await conn.fetchval(
            "insert into salary_payouts (teacher_id, month, amount, paid_on, method, note, expense_id, paid_by) "
            "values ($1, $2, $3, $4, $5, $6, $7, $8) returning id",
            teacher_id, month, amount, paid_on, method, note, expense_id, user_id,
        )
    return {"id": payout_id, "expense_id": expense_id}


async def void_payout_for_expense(conn, expense_id: int, reason: str, user_id: int | None) -> None:
    await conn.execute(
        "update salary_payouts set voided_at = now(), voided_by = $2, void_reason = $3 "
        "where expense_id = $1 and voided_at is null",
        expense_id, user_id, reason,
    )
