from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, status

from .. import db
from ..deps import CurrentUser, get_current_user
from ..phone import normalize
from ..schemas import LoginRequest, LoginResponse, MeResponse
from ..security import create_access_token, verify_password

router = APIRouter(tags=["auth"])

_MAX_FAILED_ATTEMPTS = 5
_LOCKOUT_DURATION = timedelta(minutes=15)


@router.post("/auth/login", response_model=LoginResponse)
async def login(payload: LoginRequest):
    phone = normalize(payload.phone)
    row = await db.pool().fetchrow(
        """
        select id, full_name, password_hash, role, is_active, token_version,
               failed_login_attempts, locked_until
        from users where phone = $1
        """,
        phone,
    )

    if row is not None and row["locked_until"] is not None and row["locked_until"] > datetime.now(timezone.utc):
        minutes_left = max(1, int((row["locked_until"] - datetime.now(timezone.utc)).total_seconds() // 60) + 1)
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS,
            f"Juda ko'p urinish. {minutes_left} daqiqadan so'ng qayta urinib ko'ring.",
        )

    valid = row is not None and row["is_active"] and verify_password(payload.password, row["password_hash"])
    if not valid:
        if row is not None and row["is_active"]:
            await _record_failed_attempt(row["id"], row["failed_login_attempts"])
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Telefon yoki parol noto'g'ri.")

    await db.pool().execute(
        "update users set failed_login_attempts = 0, locked_until = null where id = $1",
        row["id"],
    )

    token = create_access_token(user_id=row["id"], role=row["role"], token_version=row["token_version"])
    return LoginResponse(
        token=token,
        user_id=row["id"],
        role=row["role"],
        full_name=row["full_name"],
        phone=phone,
    )


async def _record_failed_attempt(user_id: int, current_attempts: int) -> None:
    attempts = current_attempts + 1
    locked_until = datetime.now(timezone.utc) + _LOCKOUT_DURATION if attempts >= _MAX_FAILED_ATTEMPTS else None
    await db.pool().execute(
        "update users set failed_login_attempts = $1, locked_until = $2 where id = $3",
        attempts,
        locked_until,
        user_id,
    )


@router.get("/me", response_model=MeResponse)
async def me(user: CurrentUser = Depends(get_current_user)):
    return MeResponse(user_id=user.id, phone=user.phone, full_name=user.full_name, role=user.role)


@router.post("/me/revoke-sessions", status_code=status.HTTP_204_NO_CONTENT)
async def revoke_my_sessions(user: CurrentUser = Depends(get_current_user)):
    """Invalidates every JWT issued for this account, forcing a fresh login
    on every device -- for a lost/stolen phone."""
    await db.pool().execute("update users set token_version = token_version + 1 where id = $1", user.id)
