import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from . import db
from .security import decode_access_token

_bearer = HTTPBearer(auto_error=False)


class CurrentUser:
    def __init__(self, id: int, phone: str, full_name: str, role: str, active: bool):
        self.id = id
        self.phone = phone
        self.full_name = full_name
        self.role = role
        self.active = active

    @property
    def is_owner(self) -> bool:
        return self.role == "owner"


async def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> CurrentUser:
    if credentials is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Missing bearer token.")

    try:
        payload = decode_access_token(credentials.credentials)
        user_id = int(payload["sub"])
        token_version = payload["tv"]
    except (jwt.PyJWTError, KeyError, ValueError):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid or expired token.")

    row = await db.pool().fetchrow(
        "select id, phone, full_name, role, is_active, token_version from users where id = $1",
        user_id,
    )
    if row is None or not row["is_active"]:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Account is not active.")
    if row["token_version"] != token_version:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Session revoked, please sign in again.")

    return CurrentUser(
        id=row["id"],
        phone=row["phone"],
        full_name=row["full_name"],
        role=row["role"],
        active=row["is_active"],
    )


async def require_owner(user: CurrentUser = Depends(get_current_user)) -> CurrentUser:
    """Owner-only actions: staff accounts and the center's finances
    (salaries, expenses, profit). Everything else is open to the owner and
    admins alike -- the only two roles there are."""
    if not user.is_owner:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Faqat egasi uchun.")
    return user
