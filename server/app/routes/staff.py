"""Staff accounts, managed by the owner. There are two roles: the one
owner, and admins the owner adds. Switching an account off or resetting
its password signs it out everywhere (token_version)."""

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, status

from .. import db
from ..deps import CurrentUser, require_owner
from ..phone import is_valid_uzbek_phone, normalize
from ..schemas import CreateStaffRequest, ResetPasswordRequest, StaffMember, UpdateStaffRequest
from ..security import hash_password

router = APIRouter(prefix="/staff", tags=["staff"], dependencies=[Depends(require_owner)])

_MIN_PASSWORD = 6
_SELECT = """
select u.id, u.phone, u.full_name, u.role, u.is_active, u.created_at, l.last_login_at,
       ub.branch_id, b.name as branch_name
from users u
left join staff_logins l on l.user_id = u.id
left join user_branches ub on ub.user_id = u.id
left join branches b on b.id = ub.branch_id
"""


def _password(value: str) -> str:
    if len(value) < _MIN_PASSWORD:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, f"Parol kamida {_MIN_PASSWORD} belgidan iborat bo'lsin.")
    return value


async def _branch(conn, branch_id: int | None) -> int:
    """The branch an admin is put in: the one named, else Bosh ofis."""
    if branch_id is None:
        return await conn.fetchval("select id from branches where is_headquarters")
    if not await conn.fetchval("select 1 from branches where id = $1 and is_active", branch_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Filial topilmadi.")
    return branch_id


async def _fetch(conn, staff_id: int) -> StaffMember:
    row = await conn.fetchrow(f"{_SELECT} where u.id = $1", staff_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Xodim topilmadi.")
    return StaffMember(**row)


@router.get("", response_model=list[StaffMember])
async def list_staff():
    rows = await db.pool().fetch(
        f"{_SELECT} order by u.role = 'owner' desc, u.is_active desc, u.full_name"
    )
    return [StaffMember(**row) for row in rows]


@router.post("", response_model=StaffMember, status_code=status.HTTP_201_CREATED)
async def create_staff(payload: CreateStaffRequest):
    """Adds an admin -- there's only ever one owner."""
    full_name = payload.full_name.strip()
    if not full_name:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Ism kiritilishi shart.")
    phone = normalize(payload.phone)
    if not is_valid_uzbek_phone(phone):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Telefon noto'g'ri: +998 dan keyin 9 ta raqam bo'lishi kerak.")
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            branch_id = await _branch(conn, payload.branch_id)
            try:
                staff_id = await conn.fetchval(
                    """
                    insert into users (phone, full_name, password_hash, role)
                    values ($1, $2, $3, 'admin')
                    returning id
                    """,
                    phone,
                    full_name,
                    hash_password(_password(payload.password)),
                )
            except asyncpg.UniqueViolationError:
                raise HTTPException(status.HTTP_409_CONFLICT, "Bu raqam bilan xodim allaqachon bor.")
            await conn.execute("insert into user_branches (user_id, branch_id) values ($1, $2)", staff_id, branch_id)
            return await _fetch(conn, staff_id)


async def _lock_admin(conn, staff_id: int, user: CurrentUser) -> dict:
    row = await conn.fetchrow("select * from users where id = $1 for update", staff_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Xodim topilmadi.")
    if row["role"] == "owner" and row["id"] != user.id:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Egasining hisobini o'zgartirib bo'lmaydi.")
    return row


@router.patch("/{staff_id}", response_model=StaffMember)
async def update_staff(staff_id: int, payload: UpdateStaffRequest, user: CurrentUser = Depends(require_owner)):
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            row = await _lock_admin(conn, staff_id, user)
            if payload.full_name is not None:
                full_name = payload.full_name.strip()
                if not full_name:
                    raise HTTPException(status.HTTP_400_BAD_REQUEST, "Ism kiritilishi shart.")
                await conn.execute("update users set full_name = $2 where id = $1", staff_id, full_name)
            if payload.branch_id is not None:
                if row["role"] == "owner":
                    raise HTTPException(status.HTTP_400_BAD_REQUEST, "Egasi hamma filialni ko'radi.")
                branch_id = await _branch(conn, payload.branch_id)
                await conn.execute(
                    """
                    insert into user_branches (user_id, branch_id) values ($1, $2)
                    on conflict (user_id) do update set branch_id = excluded.branch_id
                    """,
                    staff_id,
                    branch_id,
                )
            if payload.is_active is not None and payload.is_active != row["is_active"]:
                if row["role"] == "owner":
                    raise HTTPException(status.HTTP_400_BAD_REQUEST, "Egasining hisobini o'chirib bo'lmaydi.")
                # Switching off also signs the account out of every device.
                await conn.execute(
                    "update users set is_active = $2, token_version = token_version + 1 where id = $1",
                    staff_id,
                    payload.is_active,
                )
            return await _fetch(conn, staff_id)


@router.post("/{staff_id}/password", response_model=StaffMember)
async def reset_password(
    staff_id: int, payload: ResetPasswordRequest, user: CurrentUser = Depends(require_owner)
):
    """Sets a new password and signs the account out everywhere."""
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            await _lock_admin(conn, staff_id, user)
            await conn.execute(
                """
                update users
                set password_hash = $2, token_version = token_version + 1,
                    failed_login_attempts = 0, locked_until = null
                where id = $1
                """,
                staff_id,
                hash_password(_password(payload.password)),
            )
            return await _fetch(conn, staff_id)
