from datetime import date

from fastapi import APIRouter, Depends, HTTPException, status

from .. import clock, db, student_events
from ..scope import branch_filter, link_student, require_enrollment, require_group, require_student
from ..money import rules, service as money
from ..deps import CurrentUser, Scope, get_current_user, get_scope
from ..schemas import CreateEnrollmentRequest, Enrollment, FirstChargePreview, StudentEnrollment

router = APIRouter(prefix="/enrollments", tags=["enrollments"], dependencies=[Depends(get_current_user)])

_DISCOUNT_KINDS = ("amount", "percent")


def validate_discount(kind: str | None, value: int | None, fee_amount: int) -> tuple[str | None, int | None]:
    """(kind, value) to store -- both None for "no discount". Checked here,
    not just in the dialog: a percent is 0-100, an amount never more than
    the group's fee."""
    if kind is None and not value:
        return None, None
    if kind not in _DISCOUNT_KINDS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Chegirma turi noto'g'ri.")
    if not value:
        return None, None
    if value < 0:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Chegirma manfiy bo'lishi mumkin emas.")
    if kind == "percent" and value > 100:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Chegirma 0 dan 100 foizgacha bo'lishi kerak.")
    if kind == "amount" and value > fee_amount:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Chegirma guruh narxidan oshmasligi kerak.")
    return kind, value


async def enroll(
    conn,
    *,
    student_id: int,
    group_id: int,
    joined_at: date,
    created_by: int,
    first_month: str | None = None,
    discount_kind: str | None = None,
    discount_value: int | None = None,
    log_event: bool = True,
) -> tuple[dict, int]:
    """Creates an enrollment and its first charge on `conn`, inside the
    caller's transaction; returns (enrollment row, first charge amount).

    Locks the group row first, so two people adding the last free seat at
    the same moment can't both get it."""
    group = await conn.fetchrow("select * from groups where id = $1 for update", group_id)
    if group is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Guruh topilmadi.")

    existing = await conn.fetchval(
        "select 1 from enrollments where student_id = $1 and group_id = $2 and status = 'active'",
        student_id,
        group_id,
    )
    if existing:
        raise HTTPException(status.HTTP_409_CONFLICT, "Bu o'quvchi allaqachon shu guruhda.")

    # A full group still takes the student: the center decides, the seat count
    # simply goes over the capacity and the group stays full.

    discount_kind, discount_value = validate_discount(discount_kind, discount_value, group["fee_amount"])
    row = await conn.fetchrow(
        """
        insert into enrollments (student_id, group_id, joined_at, discount_kind, discount_value, created_by)
        values ($1, $2, $3, $4, $5, $6)
        returning *
        """,
        student_id,
        group_id,
        joined_at,
        discount_kind,
        discount_value,
        created_by,
    )
    amount = await money.issue_first_charge(conn, dict(row), dict(group), created_by, first_month)
    # Joining a group takes him out of the archive; coming back to a group he
    # had left is "activated", any other is "added".
    if await link_student(conn, student_id, group["branch_id"]):
        await student_events.log(
            conn, student_id, "unarchived", created_by, branch_id=group["branch_id"], note="Guruhga qaytdi"
        )
    if log_event:
        came_back = await conn.fetchval(
            "select 1 from enrollments where student_id = $1 and group_id = $2 and id <> $3", student_id, group_id, row["id"]
        )
        await student_events.log(
            conn, student_id, "activated" if came_back else "added", created_by,
            group_id=group_id, enrollment_id=row["id"],
        )
    return row, amount


@router.post("", response_model=Enrollment, status_code=status.HTTP_201_CREATED)
async def create_enrollment(
    payload: CreateEnrollmentRequest,
    user: CurrentUser = Depends(get_current_user),
    scope: Scope = Depends(get_scope),
):
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            await require_student(conn, scope, payload.student_id)
            await require_group(conn, scope, payload.group_id)
            row, _ = await enroll(
                conn,
                student_id=payload.student_id,
                group_id=payload.group_id,
                joined_at=payload.joined_at,
                created_by=user.id,
            )
    return Enrollment(**row)


@router.get("/first-charge-preview", response_model=FirstChargePreview)
async def first_charge_preview(
    group_id: int,
    joined_at: date,
    discount_kind: str | None = None,
    discount_value: int | None = None,
    scope: Scope = Depends(get_scope),
):
    """Both possible first charges for a student starting in a group on
    joined_at -- shown in the dialog before the user chooses."""
    # The owner may be looking at a group of another branch than the one in view.
    lookup = Scope(scope.user, None, scope.write_branch()) if scope.user.is_owner else scope
    group = await require_group(db.pool(), lookup, group_id)
    kind, value = validate_discount(discount_kind, discount_value, group["fee_amount"])
    fee = rules.discounted_fee(group["fee_amount"], kind, value)
    first = rules.billing_periods(group["billing_mode"], group["billing_day"], joined_at, joined_at)[0]
    # Days from the start to the next billing day, over the days of the
    # full cycle it falls in (a fixed-day group); anniversary groups never prorate.
    cycle_days = first.cycle_days if first.cycle_days else (first.end - first.start).days
    return FirstChargePreview(
        monthly_fee=group["fee_amount"],
        discounted_fee=fee,
        period_start=first.end - rules.timedelta(days=cycle_days),
        period_end=first.end,
        days_left=(first.end - joined_at).days,
        days_in_period=cycle_days,
        prorated_amount=first.amount(fee),
        full_amount=fee,
        is_mid_cycle=first.prorated,
    )


async def withdraw(conn, enrollment: dict, user_id: int | None, reason: str) -> int:
    """Ends an enrollment (inside the caller's transaction) and returns what
    he still owes on it. Nothing is deleted: the lessons, charges and payments
    stay, and months after the one he left in are cancelled with a reason."""
    ended_at = clock.today()
    await conn.execute(
        "update enrollments set status = 'withdrawn', ended_at = $2 where id = $1", enrollment["id"], ended_at
    )
    # Months after the one they left in aren't owed -- cancelled with
    # a reason (never deleted), so the history still explains itself.
    await money.cancel_charges_after(conn, enrollment["id"], ended_at, reason, user_id)
    return await conn.fetchval("select owed from enrollment_balances where enrollment_id = $1", enrollment["id"])


@router.post("/{enrollment_id}/withdraw", response_model=Enrollment)
async def withdraw_enrollment(
    enrollment_id: int, user: CurrentUser = Depends(get_current_user), scope: Scope = Depends(get_scope)
):
    """Plain withdrawal. The app uses the student's own "remove from group" /
    "archive" (which ask for a comment); this stays for anything else."""
    existing = await require_enrollment(db.pool(), scope, enrollment_id)
    if existing["status"] == "withdrawn":
        return Enrollment(**existing)

    async with db.pool().acquire() as conn:
        async with conn.transaction():
            debt = await withdraw(conn, dict(existing), user.id, "O'quvchi guruhdan chiqdi")
            await student_events.log(
                conn, existing["student_id"], "removed", user.id,
                group_id=existing["group_id"], enrollment_id=enrollment_id, debt=debt,
            )
            row = await conn.fetchrow("select * from enrollments where id = $1", enrollment_id)
    return Enrollment(**row)


@router.get("/by-student/{student_id}", response_model=list[StudentEnrollment])
async def list_student_enrollments(student_id: int, scope: Scope = Depends(get_scope)):
    """`balance` is what this enrollment still owes (never negative); a
    student's credit lives on the student, see money.student_balance."""
    rows = await db.pool().fetch(
        """
        select e.id as enrollment_id, e.group_id, g.name as group_name, e.joined_at, e.status,
               eb.owed as balance
        from enrollments e
        join groups g on g.id = e.group_id
        join enrollment_balances eb on eb.enrollment_id = e.id
        where e.student_id = $1 and """ + branch_filter("g.branch_id", 2) + """
        order by e.joined_at desc
        """,
        student_id,
        scope.ids,
    )
    due = await money.next_due_dates(db.pool(), [row["enrollment_id"] for row in rows])
    return [StudentEnrollment(**row, next_due_date=due.get(row["enrollment_id"])) for row in rows]
