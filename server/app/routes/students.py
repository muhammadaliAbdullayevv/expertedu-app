import asyncpg
from fastapi import APIRouter, Depends, HTTPException, status

from .. import db
from ..deps import CurrentUser, get_current_user
from ..phone import is_valid_uzbek_phone, normalize
from ..schemas import (
    CreateStudentRequest,
    CreateStudentWithEnrollmentRequest,
    PhoneCheck,
    PhoneOwner,
    Student,
    StudentEnrolled,
    StudentListItem,
    UpdateStudentRequest,
)
from .enrollments import enroll

router = APIRouter(prefix="/students", tags=["students"], dependencies=[Depends(get_current_user)])

_BALANCE_EXPR = """
coalesce(sum(case when t.kind = 'charge' then t.amount when t.kind = 'payment' then -t.amount else 0 end), 0)
"""

_HEARD_FROM = ("instagram", "telegram", "referral", "walk_in", "other")
_PAYMENT_METHODS = ("cash", "card", "click_payme")


def valid_phone(raw: str | None, label: str = "Telefon") -> str:
    """Digits only, 998 + 9 digits -- how every phone is compared and stored,
    so "+998 90 100 00 70" and "998901000070" are the same number."""
    phone = normalize(raw or "")
    if not is_valid_uzbek_phone(phone):
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            f"{label} noto'g'ri: +998 dan keyin 9 ta raqam bo'lishi kerak.",
        )
    return phone


def _optional_phone(raw: str | None, label: str) -> str | None:
    return valid_phone(raw, label) if raw and raw.strip() else None


def _heard_from(value: str | None) -> str | None:
    if value is None:
        return None
    if value not in _HEARD_FROM:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "\"Qayerdan eshitdi\" qiymati noto'g'ri.")
    return value


async def phone_owner(conn, phone: str) -> PhoneOwner | None:
    """The student who already has this (normalized) phone, with the groups
    they're active in -- one student per number, see uq_students_phone."""
    row = await conn.fetchrow(
        """
        select s.id, s.full_name, s.phone,
               coalesce(array_agg(g.name order by g.name) filter (where g.id is not null), '{}') as group_names
        from students s
        left join enrollments e on e.student_id = s.id and e.status = 'active'
        left join groups g on g.id = e.group_id
        where s.phone = $1
        group by s.id
        """,
        phone,
    )
    if row is None:
        return None
    return PhoneOwner(
        student_id=row["id"], full_name=row["full_name"], phone=row["phone"], group_names=list(row["group_names"])
    )


def duplicate_phone_error(owner: PhoneOwner) -> HTTPException:
    groups = ", ".join(owner.group_names) or "guruhsiz"
    return HTTPException(
        status.HTTP_409_CONFLICT,
        f"Bu raqam allaqachon mavjud: {owner.full_name} ({groups})",
    )


async def _raise_if_taken(conn, phone: str, *, except_student_id: int | None = None) -> None:
    owner = await phone_owner(conn, phone)
    if owner is not None and owner.student_id != except_student_id:
        raise duplicate_phone_error(owner)


@router.get("", response_model=list[StudentListItem])
async def list_students(q: str | None = None):
    where = "where s.full_name ilike $1 or s.phone ilike $1" if q else ""
    args = [f"%{q.strip()}%"] if q else []
    rows = await db.pool().fetch(
        f"""
        select s.*, {_BALANCE_EXPR} as balance
        from students s
        left join enrollments e on e.student_id = s.id
        left join transactions t on t.enrollment_id = e.id
        {where}
        group by s.id
        order by s.full_name asc
        """,
        *args,
    )
    return [StudentListItem(**row) for row in rows]


# Declared before "/{student_id}" so the path isn't read as a student id.
@router.get("/phone-check", response_model=PhoneCheck)
async def check_phone(phone: str):
    """Live duplicate check while the number is being typed. Anything that
    isn't a complete number yet simply has no owner."""
    normalized = normalize(phone)
    if not is_valid_uzbek_phone(normalized):
        return PhoneCheck(owner=None)
    return PhoneCheck(owner=await phone_owner(db.pool(), normalized))


@router.post("", response_model=Student, status_code=status.HTTP_201_CREATED)
async def create_student(payload: CreateStudentRequest):
    full_name = payload.full_name.strip()
    if not full_name:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "F.I.Sh. kiritilishi shart.")
    phone = valid_phone(payload.phone)
    await _raise_if_taken(db.pool(), phone)
    try:
        row = await db.pool().fetchrow(
            """
            insert into students (full_name, phone, telegram_username, note, parent_phone, heard_from)
            values ($1, $2, $3, $4, $5, $6)
            returning *
            """,
            full_name,
            phone,
            payload.telegram_username,
            payload.note,
            _optional_phone(payload.parent_phone, "Ota-ona telefoni"),
            _heard_from(payload.heard_from),
        )
    except asyncpg.UniqueViolationError:
        # Someone saved the same number between the check and the insert.
        raise duplicate_phone_error(await phone_owner(db.pool(), phone))
    return Student(**row)


@router.post("/with-enrollment", response_model=StudentEnrolled, status_code=status.HTTP_201_CREATED)
async def create_student_with_enrollment(
    payload: CreateStudentWithEnrollmentRequest, user: CurrentUser = Depends(get_current_user)
):
    """The "Yangi o'quvchi" dialog: student, enrollment, first charge and the
    optional first payment are saved together or not at all -- a failure
    can never leave a student without a group."""
    full_name = payload.full_name.strip()
    if not full_name:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "F.I.Sh. kiritilishi shart.")
    phone = valid_phone(payload.phone)
    parent_phone = _optional_phone(payload.parent_phone, "Ota-ona telefoni")
    heard_from = _heard_from(payload.heard_from)
    note = (payload.note or "").strip() or None

    first_payment = payload.first_payment_amount or 0
    if first_payment < 0:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "To'lov summasi manfiy bo'lishi mumkin emas.")
    if first_payment and payload.first_payment_method not in _PAYMENT_METHODS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "To'lov usulini tanlang.")

    async with db.pool().acquire() as conn:
        await _raise_if_taken(conn, phone)
        try:
            async with conn.transaction():
                student = await conn.fetchrow(
                    """
                    insert into students (full_name, phone, note, parent_phone, heard_from, created_by)
                    values ($1, $2, $3, $4, $5, $6)
                    returning *
                    """,
                    full_name,
                    phone,
                    note,
                    parent_phone,
                    heard_from,
                    user.id,
                )
                enrollment, first_charge = await enroll(
                    conn,
                    student_id=student["id"],
                    group_id=payload.group_id,
                    joined_at=payload.joined_at,
                    created_by=user.id,
                    first_month=payload.first_month,
                    discount_kind=payload.discount_kind,
                    discount_value=payload.discount_value,
                )
                if first_payment:
                    await conn.execute(
                        """
                        insert into transactions (enrollment_id, kind, amount, source, method, created_by)
                        values ($1, 'payment', $2, 'manual', $3, $4)
                        """,
                        enrollment["id"],
                        first_payment,
                        payload.first_payment_method,
                        user.id,
                    )
        except asyncpg.UniqueViolationError:
            raise duplicate_phone_error(await phone_owner(conn, phone))

    return StudentEnrolled(
        student=Student(**student),
        enrollment_id=enrollment["id"],
        first_charge=first_charge,
        first_payment=first_payment,
    )


@router.get("/{student_id}", response_model=Student)
async def get_student(student_id: int):
    row = await db.pool().fetchrow("select * from students where id = $1", student_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "O'quvchi topilmadi.")
    return Student(**row)


@router.patch("/{student_id}", response_model=Student)
async def update_student(student_id: int, payload: UpdateStudentRequest):
    existing = await db.pool().fetchrow("select * from students where id = $1", student_id)
    if existing is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "O'quvchi topilmadi.")

    updates = payload.model_dump(exclude_unset=True)
    if "phone" in updates:
        updates["phone"] = valid_phone(updates["phone"])
        await _raise_if_taken(db.pool(), updates["phone"], except_student_id=student_id)
    if not updates:
        return Student(**existing)

    fields = list(updates.keys())
    values = list(updates.values())
    set_clause = ", ".join(f"{field} = ${i + 2}" for i, field in enumerate(fields))
    try:
        row = await db.pool().fetchrow(
            f"update students set {set_clause} where id = $1 returning *",
            student_id,
            *values,
        )
    except asyncpg.UniqueViolationError:
        raise duplicate_phone_error(await phone_owner(db.pool(), updates["phone"]))
    return Student(**row)
