"""Sends push notifications via Firebase Cloud Messaging's HTTP v1 API.

Deliberately calls Google's REST API directly with httpx + pyjwt (both
already dependencies) instead of pulling in the firebase-admin SDK, which
drags in grpcio and a lot else this small a use case doesn't need -- the
actual protocol here is just "sign a JWT, trade it for an access token,
POST the message," which is little enough code to own directly.
"""

import base64
import json
import logging
import time
from uuid import UUID

import httpx
import jwt

from . import db
from .config import settings

logger = logging.getLogger(__name__)

_TOKEN_URL = "https://oauth2.googleapis.com/token"
_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"

# Cached in-process; a fresh access token is requested once it's within a
# minute of expiring rather than on every single push.
_cached_token: str | None = None
_cached_token_expires_at: float = 0.0


def _service_account() -> dict:
    # FCM_SERVICE_ACCOUNT_JSON holds the service account file base64-encoded,
    # not raw JSON -- the raw JSON's private_key field embeds literal "\n"
    # escape sequences, and systemd's EnvironmentFile parser does not pass
    # those through byte-for-byte the way a shell would, which silently
    # corrupted the key (RS256 signing failed with "could not parse the
    # provided public key") the one time this shipped without the encoding.
    # Base64 has no characters any env-file/shell parser treats specially,
    # so this sidesteps the whole class of bug rather than fixing one case.
    raw = base64.b64decode(settings.fcm_service_account_json)
    return json.loads(raw)


async def _access_token() -> str | None:
    global _cached_token, _cached_token_expires_at

    if not settings.fcm_configured:
        return None
    if _cached_token is not None and time.time() < _cached_token_expires_at - 60:
        return _cached_token

    account = _service_account()
    now = int(time.time())
    assertion = jwt.encode(
        {
            "iss": account["client_email"],
            "scope": _SCOPE,
            "aud": _TOKEN_URL,
            "iat": now,
            "exp": now + 3600,
        },
        account["private_key"],
        algorithm="RS256",
    )

    async with httpx.AsyncClient(timeout=10) as client:
        response = await client.post(
            _TOKEN_URL,
            data={
                "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                "assertion": assertion,
            },
        )
    response.raise_for_status()
    body = response.json()
    _cached_token = body["access_token"]
    _cached_token_expires_at = time.time() + body["expires_in"]
    return _cached_token


async def _send_to_tokens(
    tokens: list[str],
    *,
    notification: dict | None,
    data: dict,
    channel_id: str | None,
    tag: str | None,
) -> None:
    """Shared low-level sender behind notify_other_staff/wake_sms_gateway/
    notify_customer -- token fetch and the best-effort try/except wrapper
    stay with each caller (they query different rows and log a different
    "what failed" message), but the actual per-token HTTP send loop and
    stale-token cleanup is identical for all three, so it lives here once.

    [notification] is None for a silent data-only wake (see wake_sms_gateway);
    otherwise {"title": ..., "body": ...}. [channel_id]/[tag] are only
    meaningful alongside a real notification -- Android routes/collapses
    auto-displayed background pushes by them (see callers for why each
    matters).
    """
    access_token = await _access_token()
    if access_token is None or not tokens:
        return

    project_id = _service_account()["project_id"]
    url = f"https://fcm.googleapis.com/v1/projects/{project_id}/messages:send"
    headers = {"Authorization": f"Bearer {access_token}"}

    android: dict = {"priority": "high"}
    if notification is not None:
        android_notification = {"channel_id": channel_id}
        if tag:
            android_notification["tag"] = tag
        android["notification"] = android_notification

    stale_tokens: list[str] = []
    async with httpx.AsyncClient(timeout=10) as client:
        for token in tokens:
            message: dict = {"message": {"token": token, "data": data, "android": android}}
            if notification is not None:
                message["message"]["notification"] = notification
            try:
                response = await client.post(url, headers=headers, json=message)
                if response.status_code == 404 or (
                    response.status_code == 400 and "UNREGISTERED" in response.text
                ):
                    stale_tokens.append(token)
            except httpx.HTTPError:
                # A single bad send (network blip, one dead token) should
                # never stop the rest of the recipients from being notified.
                continue

    if stale_tokens:
        await db.pool().execute(
            "delete from device_tokens where token = any($1::text[])", stale_tokens
        )


async def notify_other_staff(
    *,
    actor_id: UUID,
    shop_id: UUID,
    title: str,
    body: str,
    customer_id: UUID | None,
    activity_id: str | None = None,
) -> None:
    """Pushes to every registered device except the one that caused the
    event -- the same "everyone else sees it" rule the in-app activity feed
    already follows. Best-effort: a push failure never raises, since a
    notification not arriving shouldn't break the write that triggered it.

    That guarantee lives here, wrapping literally everything below (a bad
    credential, a Google outage, anything) -- not just the per-token loop
    further down. The one time it didn't (before this try/except existed) a
    bad key turned "push failed to send" into "customer creation failed",
    even though the customer had already been saved.
    """
    if not settings.fcm_configured:
        return
    try:
        rows = await db.pool().fetch(
            "select token from device_tokens where shop_id = $1 and user_id != $2", shop_id, actor_id
        )
        if not rows:
            return
        data = {"customer_id": str(customer_id)} if customer_id else {}
        if activity_id:
            data["activity_id"] = activity_id
        await _send_to_tokens(
            [row["token"] for row in rows],
            notification={"title": title, "body": body},
            data=data,
            # Must match LocalNotificationsService's channel id (already
            # created on-device at app startup) -- without this, Android
            # posts background/terminated pushes to its own default channel
            # instead, which is importance-default rather than high and so
            # never shows as a heads-up popup, only a silent tray entry.
            channel_id="staff_activity",
            # Lets Android collapse a redelivered copy of the same push
            # (FCM is at-least-once, not exactly-once) into the existing
            # notification instead of showing it a second time.
            tag=activity_id,
        )
    except Exception:
        logger.exception("Failed to send push notification(s); the triggering write already succeeded.")


async def notify_all_staff(
    *,
    shop_id: UUID,
    title: str,
    body: str,
    customer_id: UUID,
    activity_id: str | None = None,
) -> None:
    """Like notify_other_staff, but for events with no staff "actor" to
    exclude -- specifically a customer sending a chat message, which every
    staff device should be told about, not just everyone-but-one."""
    if not settings.fcm_configured:
        return
    try:
        rows = await db.pool().fetch(
            """
            select token from device_tokens
            where shop_id = $1 and user_id in (
              select id from users where shop_id = $1 and role in ('owner', 'seller')
            )
            """,
            shop_id,
        )
        if not rows:
            return
        data = {"customer_id": str(customer_id)}
        if activity_id:
            data["activity_id"] = activity_id
        await _send_to_tokens(
            [row["token"] for row in rows],
            notification={"title": title, "body": body},
            data=data,
            channel_id="staff_activity",
            tag=activity_id,
        )
    except Exception:
        logger.exception("Failed to send push notification(s); the triggering write already succeeded.")


async def notify_customer(
    *,
    customer_id: UUID,
    title: str,
    body: str,
    activity_id: str | None = None,
) -> None:
    """Pushes to a customer-role login's own device(s) -- e.g. "your debt
    was just recorded" -- completely separate from notify_other_staff,
    which only ever targets staff accounts. Best-effort for the same
    reason: a push failure must never affect the transaction write that
    triggered it.
    """
    if not settings.fcm_configured:
        return
    try:
        rows = await db.pool().fetch(
            "select token from device_tokens where user_id in (select id from users where customer_id = $1)",
            customer_id,
        )
        if not rows:
            return
        data = {"type": "customer_activity"}
        if activity_id:
            data["activity_id"] = activity_id
        await _send_to_tokens(
            [row["token"] for row in rows],
            notification={"title": title, "body": body},
            data=data,
            channel_id="customer_activity",
            tag=activity_id,
        )
    except Exception:
        logger.exception("Failed to push to customer; the triggering write already succeeded.")


async def wake_sms_gateway(shop_id: UUID) -> None:
    """Pings whichever device(s) are flagged as the SMS gateway with a
    data-only push the instant a message is queued for them, instead of
    relying solely on that phone's own in-app poll timer, which only runs
    while its app happens to be foregrounded. Best-effort, same reasoning
    as notify_other_staff: a push failure must never affect the SMS queuing
    that already succeeded.
    """
    if not settings.fcm_configured:
        return
    try:
        rows = await db.pool().fetch(
            "select token from device_tokens where shop_id = $1 and is_sms_gateway", shop_id
        )
        if not rows:
            return
        await _send_to_tokens(
            [row["token"] for row in rows],
            # Deliberately no "notification" key -- this must not
            # auto-display anything, it's purely a wake-up signal the app
            # handles itself in firebaseMessagingBackgroundHandler.
            notification=None,
            data={"type": "sms_gateway_poll"},
            channel_id=None,
            tag=None,
        )
    except Exception:
        logger.exception("Failed to wake SMS-gateway device(s); the SMS is still queued.")


async def alert_owner(message: str) -> None:
    """Pushes a plain alert to every owner-role device, for failures that
    happen outside any request path entirely -- a failed nightly database
    or CSV backup (see scripts/alert_owner.py, scripts/backup_db.sh,
    scripts/export_csv_backup.py) -- not tied to any particular shop's
    activity feed. Best-effort, same reasoning as every other sender here:
    a push failure must never raise and crash the script that's already
    mid-failure-handling."""
    if not settings.fcm_configured:
        return
    try:
        rows = await db.pool().fetch(
            """
            select dt.token from device_tokens dt
            join users u on u.id = dt.user_id
            where u.role = 'owner'
            """
        )
        if not rows:
            return
        await _send_to_tokens(
            [row["token"] for row in rows],
            notification={"title": "Diqqat", "body": message},
            data={},
            channel_id="staff_activity",
            tag=None,
        )
    except Exception:
        logger.exception("Failed to alert owner device(s) with message: %s", message)
