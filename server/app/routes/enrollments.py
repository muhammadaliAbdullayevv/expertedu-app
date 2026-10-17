from datetime import date

from fastapi import APIRouter, Depends, HTTPException, status

from .. import billing, clock, db
from ..deps import CurrentUser, get_current_user
from ..schemas import CreateEnrollmentRequest, Enrollment, FirstChargePreview, StudentEnrollment

router = APIRouter(prefix="/enrollments", tags=["enrollments"], dependencies=[Depends(get_current_user)])

_BALANCE_EXPR = """
coalesce(sum(case when t.kind = 'charge' then t.amount when t.kind = 'payment' then -t.amount else 0 end), 0)
"""


_DISCOUNT_KINDS = ("amount", "percent")
_FIRST_MONTH_OPTIONS = ("prorated", "full")


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
    first_month: str = "prorated",
    discount_kind: str | None = None,
    discount_value: int | None = None,
) -> tuple[dict, int]:
    """Creates an enrollment and its first charge on `conn`, inside the
    caller's transaction; returns (enrollment row, first charge amount).

    Locks the group row first, so two people adding the last free seat at
    the same moment can't both get it."""
    group = await conn.fetchrow("select * from groups where id = $1 for update", group_id)
    if group is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Guruh topilmadi.")
    if first_month not in _FIRST_MONTH_OPTIONS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Birinchi oy turi noto'g'ri.")

    existing = await conn.fetchval(
        "select 1 from enrollments where student_id = $1 and group_id = $2 and status = 'active'",
        student_id,
        group_id,
    )
    if existing:
        raise HTTPException(status.HTTP_409_CONFLICT, "Bu o'quvchi allaqachon shu guruhda.")

    if group["capacity"] is not None:
        taken = await conn.fetchval(
            "select count(*) from enrollments where group_id = $1 and status = 'active'", group_id
        )
        if taken >= group["capacity"]:
            raise HTTPException(status.HTTP_409_CONFLICT, f"Guruh to'lgan ({taken}/{group['capacity']}).")

    discount_kind, discount_value = validate_discount(discount_kind, discount_value, group["fee_amount"])
    fee = billing.discounted_fee(group["fee_amount"], discount_kind, discount_value)
    amount, is_prorated = billing.first_charge_for_enrollment(
        fee_amount=fee, due_day=group["due_day"], joined_at=joined_at
    )
    if first_month == "full":
        amount, is_prorated = fee, False

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
    await conn.execute(
        """
        insert into transactions
            (enrollment_id, kind, amount, period_start, due_date, is_prorated, source, created_by)
        values ($1, 'charge', $2, $3, $3, $4, 'auto_recurring', $5)
        """,
        row["id"],
        amount,
        joined_at,
        is_prorated,
        created_by,
    )
    return row, amount


@router.post("", response_model=Enrollment, status_code=status.HTTP_201_CREATED)
async def create_enrollment(payload: CreateEnrollmentRequest, user: CurrentUser = Depends(get_current_user)):
    student = await db.pool().fetchval("select 1 from students where id = $1", payload.student_id)
    if not student:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "O'quvchi topilmadi.")

    async with db.pool().acquire() as conn:
        async with conn.transaction():
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
):
    """Both possible first charges for a student starting in a group on
    joined_at -- shown in the dialog before the user chooses."""
    group = await db.pool().fetchrow("select fee_amount, due_day from groups where id = $1", group_id)
    if group is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Guruh topilmadi.")
    kind, value = validate_discount(discount_kind, discount_value, group["fee_amount"])
    fee = billing.discounted_fee(group["fee_amount"], kind, value)
    start, end = billing.first_period(group["due_day"], joined_at)
    prorated, is_prorated = billing.first_charge_for_enrollment(fee, group["due_day"], joined_at)
    return FirstChargePreview(
        monthly_fee=group["fee_amount"],
        discounted_fee=fee,
        period_start=start,
        period_end=end,
        days_left=(end - joined_at).days,
        days_in_period=(end - start).days,
        prorated_amount=prorated,
        full_amount=fee,
        is_mid_cycle=is_prorated,
    )


@router.post("/{enrollment_id}/withdraw", response_model=Enrollment)
async def withdraw_enrollment(enrollment_id: int):
    existing = await db.pool().fetchrow("select * from enrollments where id = $1", enrollment_id)
    if existing is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Yozilish topilmadi.")
    if existing["status"] == "withdrawn":
        return Enrollment(**existing)

    ended_at = clock.today()
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            row = await conn.fetchrow(
                """
                update enrollments set status = 'withdrawn', ended_at = $2
                where id = $1
                returning *
                """,
                enrollment_id,
                ended_at,
            )
            # Same rule the recurring-charge job follows: a period starting
            # on or after the withdrawal date isn't owed. Only today's charge
            # can match -- the job never charges ahead of time -- e.g. the
            # job already billed this morning's due day before the student
            # came in to quit.
            await conn.execute(
                """
                delete from transactions
                where enrollment_id = $1 and kind = 'charge' and source = 'auto_recurring'
                  and due_date >= $2
                """,
                enrollment_id,
                ended_at,
            )
    return Enrollment(**row)


@router.get("/by-student/{student_id}", response_model=list[StudentEnrollment])
async def list_student_enrollments(student_id: int):
    rows = await db.pool().fetch(
        f"""
        select e.id as enrollment_id, e.group_id, g.name as group_name, e.joined_at, e.status,
               {_BALANCE_EXPR} as balance
        from enrollments e
        join groups g on g.id = e.group_id
        left join transactions t on t.enrollment_id = e.id
        where e.student_id = $1
        group by e.id, g.name
        order by e.joined_at desc
        """,
        student_id,
    )
    return [StudentEnrollment(**row) for row in rows]
