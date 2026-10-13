from fastapi import APIRouter, Depends, HTTPException, status

from .. import db
from ..deps import get_current_user
from ..schemas import CreatePaymentRequest, Transaction

router = APIRouter(prefix="/enrollments", tags=["transactions"], dependencies=[Depends(get_current_user)])


@router.get("/{enrollment_id}/transactions", response_model=list[Transaction])
async def list_transactions(enrollment_id: int):
    rows = await db.pool().fetch(
        "select * from transactions where enrollment_id = $1 order by occurred_at asc", enrollment_id
    )
    return [Transaction(**row) for row in rows]


@router.post("/{enrollment_id}/payments", response_model=Transaction, status_code=status.HTTP_201_CREATED)
async def record_payment(enrollment_id: int, payload: CreatePaymentRequest):
    exists = await db.pool().fetchval("select 1 from enrollments where id = $1", enrollment_id)
    if not exists:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Yozilish topilmadi.")
    if payload.amount <= 0:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Summa musbat bo'lishi kerak.")

    row = await db.pool().fetchrow(
        """
        insert into transactions (enrollment_id, kind, amount, source, note)
        values ($1, 'payment', $2, 'manual', $3)
        returning *
        """,
        enrollment_id,
        payload.amount,
        payload.note,
    )
    return Transaction(**row)
