import asyncio
import time
from collections import defaultdict

import httpx

from . import db, fcm
from .config import settings
from .phone import normalize

_token: str | None = None
_token_expires_at: float = 0.0

# One lock per shop so a welcome SMS (queued from create_customer) and a
# debt/payment SMS (queued moments later from record_transaction) can never
# have their sms_logs insert -- and thus their created_at, which is what
# both the gateway phone's /pending poll and the owner's SMS history screen
# order by -- land in the wrong order just because their BackgroundTasks
# happened to get scheduled out of order. Without this, a staff member
# adding debt right after creating a customer could have the debt text
# arrive on the customer's phone before the welcome text, or two debts
# added in quick succession could arrive swapped.
_shop_locks: defaultdict[object, asyncio.Lock] = defaultdict(asyncio.Lock)


async def _get_token() -> str:
    global _token, _token_expires_at
    if _token and time.time() < _token_expires_at:
        return _token

    async with httpx.AsyncClient(timeout=15) as client:
        response = await client.post(
            f"{settings.eskiz_base_url}/api/auth/login",
            data={"email": settings.eskiz_email, "password": settings.eskiz_password},
        )
        response.raise_for_status()
        token = response.json()["data"]["token"]

    _token = token
    _token_expires_at = time.time() + 25 * 24 * 60 * 60  # Eskiz tokens last ~30 days.
    return token


async def send_customer_sms(
    *,
    shop_id,
    phone: str,
    message: str,
    customer_id,
    transaction_id,
) -> None:
    """Sends an SMS and always records the attempt in sms_logs. Serialized
    per shop (see _shop_locks) so concurrent callers -- typically a welcome
    SMS and a debt SMS queued moments apart -- always finish being queued
    in the order they were called, not the order their background tasks
    happened to get scheduled."""
    async with _shop_locks[shop_id]:
        await _send_customer_sms_locked(
            shop_id=shop_id,
            phone=phone,
            message=message,
            customer_id=customer_id,
            transaction_id=transaction_id,
        )


async def _send_customer_sms_locked(
    *,
    shop_id,
    phone: str,
    message: str,
    customer_id,
    transaction_id,
) -> None:
    normalized_phone = normalize(phone)

    gateway_key = await db.pool().fetchval("select sms_gateway_key from shops where id = $1", shop_id)

    if gateway_key:
        # Queue it for that shop's own gateway phone to pick up via
        # GET /sms-gateway/pending instead of sending it ourselves.
        await db.pool().execute(
            """
            insert into sms_logs (shop_id, customer_id, transaction_id, phone, message, status)
            values ($1, $2, $3, $4, $5, 'pending')
            """,
            shop_id,
            customer_id,
            transaction_id,
            normalized_phone,
            message,
        )
        # The gateway phone's own in-app poll timer only runs while its app
        # is foregrounded, so relying on it alone meant messages only went
        # out when that specific phone happened to be open at the right
        # moment. This wakes it immediately via FCM instead.
        await fcm.wake_sms_gateway(shop_id)
        return

    status = "skipped"
    provider_response: str | None = None

    if settings.sms_configured:
        try:
            token = await _get_token()
            async with httpx.AsyncClient(timeout=15) as client:
                response = await client.post(
                    f"{settings.eskiz_base_url}/api/message/sms/send",
                    headers={"Authorization": f"Bearer {token}"},
                    data={
                        "mobile_phone": normalized_phone,
                        "message": message,
                        "from": settings.eskiz_from,
                    },
                )
            provider_response = response.text[:500]
            status = "sent" if response.status_code < 300 else "failed"
        except Exception as error:  # noqa: BLE001 - log and continue, never block the transaction.
            status = "failed"
            provider_response = str(error)[:500]

    await db.pool().execute(
        """
        insert into sms_logs (shop_id, customer_id, transaction_id, phone, message, status, provider_response)
        values ($1, $2, $3, $4, $5, $6, $7)
        """,
        shop_id,
        customer_id,
        transaction_id,
        normalized_phone,
        message,
        status,
        provider_response,
    )
