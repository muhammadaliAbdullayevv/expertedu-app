from fastapi import APIRouter, Depends, HTTPException, status

from .. import db
from ..deps import CurrentUser, get_current_user
from ..money import service as money
from ..schemas import CreatePaymentRequest, ReasonRequest, Transaction

router = APIRouter(tags=["transactions"], dependencies=[Depends(get_current_user)])

_LEGACY_SHAPE = """
select * from (
  select c.id, c.enrollment_id, 'charge' as kind, c.amount, c.due_date as period_start, c.due_date,
         c.is_prorated, 'auto_recurring' as source, c.note, null::text as method,
         c.created_at as occurred_at, c.status, null::text as receipt_no, c.cancel_reason as reason
  from charges c where c.enrollment_id = $1 and ($2 or c.status = 'active')
  union all
  select p.id, coalesce(p.enrollment_id, (select min(e.id) from enrollments e where e.student_id = p.student_id)),
         'payment', p.amount, null, null, false, 'manual', p.note, p.method,
         p.received_at, p.status, p.receipt_no, p.cancel_reason
  from payments p
  where p.kind = 'payment' and ($2 or p.status = 'valid')
    and p.student_id = (select student_id from enrollments where id = $1)
    and coalesce(p.enrollment_id, $1) = $1
) t order by occurred_at, kind, id
"""


@router.get("/enrollments/{enrollment_id}/transactions", response_model=list[Transaction])
async def list_transactions(enrollment_id: int, include_cancelled: bool = False):
    """This enrollment's charges and the payments handed over for it, oldest
    first. Cancelled ones are left out unless asked for."""
    rows = await db.pool().fetch(_LEGACY_SHAPE, enrollment_id, include_cancelled)
    return [Transaction(**row) for row in rows]


@router.post("/enrollments/{enrollment_id}/payments", response_model=Transaction, status_code=status.HTTP_201_CREATED)
async def record_payment(enrollment_id: int, payload: CreatePaymentRequest, user: CurrentUser = Depends(get_current_user)):
    student_id = await db.pool().fetchval("select student_id from enrollments where id = $1", enrollment_id)
    if student_id is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Yozilish topilmadi.")
    async with db.pool().acquire() as conn:
        payment = await money.record_payment(
            conn,
            student_id=student_id,
            enrollment_id=enrollment_id,
            amount=payload.amount,
            method=payload.method or "cash",
            user_id=user.id,
            note=payload.note,
        )
    return Transaction(
        id=payment["id"],
        enrollment_id=enrollment_id,
        kind="payment",
        amount=payment["amount"],
        period_start=None,
        due_date=None,
        is_prorated=False,
        source="manual",
        note=payment["note"],
        method=payment["method"],
        occurred_at=payment["received_at"],
        status=payment["status"],
        receipt_no=payment["receipt_no"],
    )


@router.post("/payments/{payment_id}/cancel", response_model=Transaction)
async def cancel_payment(payment_id: int, payload: ReasonRequest, user: CurrentUser = Depends(get_current_user)):
    """Cancels a payment with a reason. It stays on record, marked cancelled,
    with a reversal; what it paid is owed again."""
    async with db.pool().acquire() as conn:
        reversal = await money.cancel_payment(conn, payment_id, payload.reason, user.id)
    return Transaction(
        id=reversal["id"],
        enrollment_id=reversal["enrollment_id"] or 0,
        kind="reversal",
        amount=reversal["amount"],
        period_start=None,
        due_date=None,
        is_prorated=False,
        source="manual",
        note=None,
        method=reversal["method"],
        occurred_at=reversal["received_at"],
        status="valid",
        receipt_no=None,
        reason=reversal["reason"],
    )
