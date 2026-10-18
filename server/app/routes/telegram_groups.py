"""The group page's Telegram section (for the CRM app): is a Telegram chat connected to this
group, a one-time code to connect one, and disconnecting. The bot side is in bot_groups.py."""

import secrets
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, status
from pydantic import BaseModel

from .. import db
from ..config import settings
from ..deps import CurrentUser, Scope, get_current_user, get_scope
from ..scope import require_group

router = APIRouter(prefix="/groups/{group_id}/telegram", tags=["telegram"])

# No look-alikes (0/O, 1/I): the code is read off a screen and typed into Telegram.
_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
CODE_LENGTH = 8
CODE_LIFETIME = timedelta(hours=24)


class TelegramGroupStatus(BaseModel):
    connected: bool
    chat_title: str | None = None
    connected_at: datetime | None = None
    connected_by: str | None = None
    # The newest code that can still be used, with the link that adds the bot to a chat and hands it over.
    code: str | None = None
    code_expires_at: datetime | None = None
    link: str | None = None


def _link(code: str) -> str:
    return f"https://t.me/{settings.telegram_bot_username}?startgroup={code}"


async def _status(conn, group_id: int) -> TelegramGroupStatus:
    chat = await conn.fetchrow("select title, connected_at, connected_by from telegram_groups where group_id = $1", group_id)
    code = await conn.fetchrow(
        "select code, expires_at from telegram_connect_codes where group_id = $1 and used_at is null and expires_at > now() "
        "order by created_at desc limit 1",
        group_id,
    )
    return TelegramGroupStatus(
        connected=chat is not None,
        chat_title=chat["title"] if chat else None,
        connected_at=chat["connected_at"] if chat else None,
        connected_by=chat["connected_by"] if chat else None,
        code=code["code"] if code else None,
        code_expires_at=code["expires_at"] if code else None,
        link=_link(code["code"]) if code else None,
    )


@router.get("", response_model=TelegramGroupStatus)
async def telegram_status(group_id: int, scope: Scope = Depends(get_scope)):
    async with db.pool().acquire() as conn:
        await require_group(conn, scope, group_id)
        return await _status(conn, group_id)


@router.post("/code", response_model=TelegramGroupStatus, status_code=status.HTTP_201_CREATED)
async def new_code(group_id: int, user: CurrentUser = Depends(get_current_user), scope: Scope = Depends(get_scope)):
    """A fresh one-time code (valid for a day); the group's earlier unused codes stop working."""
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            await require_group(conn, scope, group_id)
            await conn.execute(
                "update telegram_connect_codes set used_at = now() where group_id = $1 and used_at is null", group_id
            )
            code = "".join(secrets.choice(_ALPHABET) for _ in range(CODE_LENGTH))
            await conn.execute(
                "insert into telegram_connect_codes (code, group_id, created_by, expires_at) values ($1, $2, $3, $4)",
                code, group_id, user.id, datetime.now(timezone.utc) + CODE_LIFETIME,
            )
            return await _status(conn, group_id)


@router.delete("", response_model=TelegramGroupStatus)
async def disconnect(group_id: int, scope: Scope = Depends(get_scope)):
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            await require_group(conn, scope, group_id)
            await conn.execute("delete from telegram_groups where group_id = $1", group_id)
            await conn.execute(
                "update telegram_connect_codes set used_at = now() where group_id = $1 and used_at is null", group_id
            )
            return await _status(conn, group_id)
