"""Exactly-once writes for retried and offline-queued requests.

A client that may resend a write -- the offline outbox always does, and so
does the enrollment wizard -- sends an `Idempotency-Key` header (a UUID).
The first request with a key does the work and stores its response in the
same transaction; every later request with that key gets the stored
response back without doing anything.

The key row is inserted before the work starts. A second request with the
same key arriving while the first is still running blocks on that insert
until the first commits (then replays its response) or rolls back (then
does the work itself) -- so even a double-click can't double-enroll. A
failed request stores nothing, so fixing the problem and retrying works.
"""

import hashlib
import json
from collections.abc import Awaitable, Callable
from typing import Any
from uuid import UUID

from fastapi import HTTPException, status
from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse

from . import db
from .deps import CurrentUser

_RETENTION_DAYS = 30


def _request_hash(payload: Any) -> str:
    encoded = json.dumps(jsonable_encoder(payload), sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode()).hexdigest()


async def run(
    *,
    key: UUID | None,
    user: CurrentUser,
    endpoint: str,
    payload: Any,
    work: Callable[[Any], Awaitable[Any]],
    status_code: int = status.HTTP_201_CREATED,
) -> JSONResponse:
    """Runs `work(conn)` in a transaction, once per key. `endpoint` and
    `payload` identify the request: reusing a key for a different request is
    a client bug and is refused rather than answered with the wrong data."""
    request_hash = _request_hash(payload)
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            if key is not None:
                claimed = await conn.fetchval(
                    """
                    insert into idempotency_keys (key, user_id, endpoint, request_hash)
                    values ($1, $2, $3, $4)
                    on conflict (key) do nothing
                    returning true
                    """,
                    key,
                    user.id,
                    endpoint,
                    request_hash,
                )
                if not claimed:
                    stored = await conn.fetchrow("select * from idempotency_keys where key = $1", key)
                    if (stored["user_id"], stored["endpoint"], stored["request_hash"]) != (
                        user.id,
                        endpoint,
                        request_hash,
                    ):
                        raise HTTPException(
                            status.HTTP_422_UNPROCESSABLE_ENTITY,
                            "Idempotency-Key boshqa so'rov uchun ishlatilgan.",
                        )
                    return JSONResponse(
                        json.loads(stored["response"]),
                        status_code=stored["status_code"],
                        headers={"Idempotent-Replay": "true"},
                    )

            body = jsonable_encoder(await work(conn))

            if key is not None:
                await conn.execute(
                    "update idempotency_keys set status_code = $2, response = $3::jsonb where key = $1",
                    key,
                    status_code,
                    json.dumps(body),
                )
    return JSONResponse(body, status_code=status_code)


async def purge_expired() -> int:
    """Clients retry within minutes or, offline, days -- never a month."""
    result = await db.pool().execute(
        f"delete from idempotency_keys where created_at < now() - interval '{_RETENTION_DAYS} days'"
    )
    return int(result.split()[-1])
