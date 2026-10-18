from contextvars import ContextVar

import jwt
from fastapi import Depends, Header, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from . import db
from .security import decode_access_token

_bearer = HTTPBearer(auto_error=False)


class CurrentUser:
    def __init__(
        self, id: int, phone: str, full_name: str, role: str, active: bool, branch_id: int | None = None
    ):
        self.id = id
        self.phone = phone
        self.full_name = full_name
        self.role = role
        self.active = active
        # An admin's branch; the owner has none (they see every branch).
        self.branch_id = branch_id

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
        """
        select u.id, u.phone, u.full_name, u.role, u.is_active, u.token_version, ub.branch_id
        from users u left join user_branches ub on ub.user_id = u.id
        where u.id = $1
        """,
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
        branch_id=row["branch_id"],
    )


async def require_owner(user: CurrentUser = Depends(get_current_user)) -> CurrentUser:
    """Owner-only actions: staff accounts and the center's finances
    (salaries, expenses, profit). Everything else is open to the owner and
    admins alike -- the only two roles there are."""
    if not user.is_owner:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Faqat egasi uchun.")
    return user


class Scope:
    """Which branches a request may see. An admin is always their own branch;
    the owner is the branch named in the X-Branch header, or every branch.

    `ids` goes straight into SQL as `($1::bigint[] is null or col = any($1))`:
    None means all branches. A record outside the scope does not exist for the
    request (404, never 403), so nothing leaks about other branches."""

    def __init__(self, user: CurrentUser, ids: list[int] | None, headquarters: int):
        self.user = user
        self.ids = ids
        self._headquarters = headquarters

    @property
    def is_all(self) -> bool:
        return self.ids is None

    def allows(self, branch_id: int | None) -> bool:
        return self.ids is None or branch_id in self.ids

    def write_branch(self) -> int:
        """The branch a new record is created in: an admin's own, the one the
        owner picked, or -- when the owner is looking at everything -- the
        headquarters (the app makes the owner choose a branch first)."""
        if self.ids is not None:
            return self.ids[0]
        return self._headquarters


# The scope of the request being served. Every router depends on get_scope
# (see main.py), so this is always set while a request runs -- the helpers
# deep in the lead and trial code read it instead of being handed it at every
# call. Background jobs run with none: they work across all branches.
_current: ContextVar["Scope | None"] = ContextVar("branch_scope", default=None)


def ambient_scope() -> "Scope | None":
    return _current.get()


async def get_scope(
    user: CurrentUser = Depends(get_current_user),
    x_branch: int | None = Header(default=None),
) -> Scope:
    headquarters = await db.pool().fetchval("select id from branches where is_headquarters")
    if user.is_owner:
        if x_branch is None:
            scope = Scope(user, None, headquarters)
        else:
            if not await db.pool().fetchval("select 1 from branches where id = $1", x_branch):
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Filial topilmadi.")
            scope = Scope(user, [x_branch], headquarters)
    else:
        if user.branch_id is None:
            raise HTTPException(status.HTTP_403_FORBIDDEN, "Sizga filial biriktirilmagan.")
        scope = Scope(user, [user.branch_id], headquarters)
    _current.set(scope)
    return scope
