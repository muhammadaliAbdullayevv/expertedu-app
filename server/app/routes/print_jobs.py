"""Printing from Telegram.

A teacher, an admin or the owner sends a file to the bot; the bot cuts out the chosen pages into a ready
PDF and queues it here (`/bot/print`). The CRM app on the PC beside the printer -- the branch's "print
station" -- asks for work every few seconds (`/print/next`), downloads the PDF, prints it and reports the
result; the bot then tells the person. The PDF is kept only while the job waits or prints."""

from datetime import timedelta
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status
from pydantic import BaseModel, Field

from .. import db
from ..deps import Scope, get_scope
from ..scope import branch_filter, not_found
from .bot import require_bot_key
from .bot_groups import _Actor

bot_router = APIRouter(prefix="/bot/print", tags=["print"], dependencies=[Depends(require_bot_key)])
router = APIRouter(prefix="/print", tags=["print"])

MAX_FILE = 25 * 1024 * 1024
# A job nobody picked up (the printer PC is off) is dropped after this, so old pages never come out tomorrow.
QUEUE_LIFETIME = timedelta(hours=3)
# A job taken by a station that then went silent.
PRINTING_LIFETIME = timedelta(minutes=10)
# A station that asked for work this recently counts as on.
ONLINE_WITHIN = timedelta(seconds=30)

_DONE = ("done", "failed", "expired", "cancelled")


async def _sweep(conn) -> None:
    """Gives up on jobs that waited or printed for too long, and drops the PDF of every finished job."""
    await conn.execute(
        "update print_jobs set status = 'expired', finished_at = now(), data = null, "
        "error = 'Printer kompyuteri yoqilmagan edi.' where status = 'queued' and created_at < now() - $1::interval",
        QUEUE_LIFETIME,
    )
    await conn.execute(
        "update print_jobs set status = 'failed', finished_at = now(), data = null, "
        "error = 'Printer kompyuteri javob bermadi.' where status = 'printing' and claimed_at < now() - $1::interval",
        PRINTING_LIFETIME,
    )


async def _online(conn, branch_id: int) -> bool:
    seen = await conn.fetchval("select last_seen_at > now() - $2::interval from print_stations where branch_id = $1", branch_id, ONLINE_WITHIN)
    return bool(seen)


# --- the bot's side ---------------------------------------------------------------------------------------------


class PrintBranch(BaseModel):
    id: int
    name: str
    online: bool
    # The printer the station last reported, what it can do (None = not known) and how many jobs wait.
    printer: str | None = None
    color: bool | None = None
    duplex: bool | None = None
    queued: int = 0


class PrintOptions(BaseModel):
    role: Literal["owner", "admin", "teacher"]
    name: str | None = None
    via: Literal["id", "phone"] | None = None
    branches: list[PrintBranch]


async def _printer_info(conn, branch_id: int, name: str) -> PrintBranch:
    row = await conn.fetchrow(
        "select printer, color, duplex, last_seen_at > now() - $2::interval as online from print_stations where branch_id = $1",
        branch_id, ONLINE_WITHIN,
    )
    waiting = await conn.fetchval("select count(*) from print_jobs where branch_id = $1 and status in ('queued', 'printing')", branch_id)
    return PrintBranch(
        id=branch_id, name=name, online=bool(row and row["online"]), printer=row["printer"] if row else None,
        color=row["color"] if row else None, duplex=row["duplex"] if row else None, queued=waiting,
    )


async def _actor(conn, telegram_user_id: int, is_owner: bool, name: str | None, verified_phone: str | None):
    """The person, if they may print (owner, an admin, a teacher), and the branches whose printer they may use."""
    actor = await _Actor.of(conn, telegram_user_id, is_owner=is_owner, name=name, verified_phone=verified_phone)
    if actor.is_owner or (actor.staff and actor.staff["role"] == "owner"):
        role = "owner"
        rows = await conn.fetch("select id, name from branches where is_active order by is_headquarters desc, name")
    elif actor.staff:
        role = "admin"
        rows = await conn.fetch("select id, name from branches where is_active and id = $1", actor.staff["branch_id"])
    elif actor.teacher:
        role = "teacher"
        rows = await conn.fetch(
            "select b.id, b.name from branches b join teacher_branches tb on tb.branch_id = b.id "
            "where tb.teacher_id = $1 and b.is_active order by b.is_headquarters desc, b.name",
            actor.teacher["id"],
        )
    else:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Chop etish faqat o'qituvchi, admin va egasi uchun.")
    return actor, role, rows


@bot_router.get("/options", response_model=PrintOptions)
async def options(
    telegram_user_id: int = Query(...), is_owner: bool = Query(False), name: str | None = Query(None),
    verified_phone: str | None = Query(None),
):
    async with db.pool().acquire() as conn:
        actor, role, rows = await _actor(conn, telegram_user_id, is_owner, name, verified_phone)
        return PrintOptions(
            role=role, name=actor.name, via=actor.via,
            branches=[await _printer_info(conn, r["id"], r["name"]) for r in rows],
        )


class PrintQueued(BaseModel):
    id: int
    branch_name: str
    online: bool
    ahead: int


@bot_router.post("", response_model=PrintQueued, status_code=status.HTTP_201_CREATED)
async def queue(
    request: Request,
    telegram_user_id: int = Query(...), chat_id: int = Query(...), is_owner: bool = Query(False),
    name: str | None = Query(None), verified_phone: str | None = Query(None),
    branch_id: int = Query(...), title: str = Query(..., max_length=200), summary: str | None = Query(None, max_length=300),
    pages: int = Query(..., ge=1), copies: int = Query(1, ge=1, le=999), duplex: bool = Query(False), color: bool = Query(False),
    landscape: bool = Query(False),
):
    """The body is the ready PDF (the bot has cut out the pages and laid them out)."""
    data = await request.body()
    if not data.startswith(b"%PDF"):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Fayl PDF emas.")
    if len(data) > MAX_FILE:
        raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, "Fayl juda katta.")
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            actor, role, rows = await _actor(conn, telegram_user_id, is_owner, name, verified_phone)
            branch = next((r for r in rows if r["id"] == branch_id), None)
            if branch is None:
                raise HTTPException(status.HTTP_403_FORBIDDEN, "Bu filialning printeridan foydalana olmaysiz.")
            ahead = await conn.fetchval("select count(*) from print_jobs where branch_id = $1 and status in ('queued', 'printing')", branch_id)
            # A printer known not to do colour / two sides is not asked to (the bot does not offer it either).
            caps = await conn.fetchrow("select color, duplex from print_stations where branch_id = $1", branch_id)
            if caps is not None:
                color = color and caps["color"] is not False
                duplex = duplex and caps["duplex"] is not False
            job_id = await conn.fetchval(
                """
                insert into print_jobs (branch_id, requested_by, requested_role, telegram_user_id, chat_id, title, summary,
                                        pages, copies, duplex, color, landscape, data)
                values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13) returning id
                """,
                branch_id, actor.name or name or "—", role, telegram_user_id, chat_id, title, summary, pages, copies, duplex,
                color, landscape, data,
            )
            return PrintQueued(id=job_id, branch_name=branch["name"], online=await _online(conn, branch_id), ahead=ahead)


@bot_router.post("/{job_id}/cancel", status_code=status.HTTP_204_NO_CONTENT)
async def bot_cancel(job_id: int, telegram_user_id: int = Query(...)):
    """The person who sent it takes it back, as long as the printer has not started on it."""
    async with db.pool().acquire() as conn:
        done = await conn.fetchval(
            "update print_jobs set status = 'cancelled', finished_at = now(), notified_at = now(), data = null "
            "where id = $1 and telegram_user_id = $2 and status = 'queued' returning id",
            job_id, telegram_user_id,
        )
    if done is None:
        raise HTTPException(status.HTTP_409_CONFLICT, "Bekor qilib bo'lmaydi.")


class PrintFinished(BaseModel):
    id: int
    chat_id: int
    title: str
    pages: int
    copies: int
    status: Literal["done", "failed", "expired", "cancelled"]
    error: str | None = None
    printer: str | None = None


@bot_router.get("/finished", response_model=list[PrintFinished])
async def finished():
    """Jobs whose result the person has not been told yet."""
    async with db.pool().acquire() as conn:
        await _sweep(conn)
        rows = await conn.fetch(
            "select id, chat_id, title, pages, copies, status, error, printer from print_jobs "
            "where notified_at is null and status = any($1::text[]) order by id limit 30",
            list(_DONE),
        )
    return [PrintFinished(**dict(r)) for r in rows]


@bot_router.post("/{job_id}/notified", status_code=status.HTTP_204_NO_CONTENT)
async def notified(job_id: int):
    await db.pool().execute("update print_jobs set notified_at = now() where id = $1 and notified_at is null", job_id)


# --- the print station's side (the CRM app, logged in) ---------------------------------------------------------


def _branch(scope: Scope) -> int:
    return scope.write_branch()


class StationJob(BaseModel):
    id: int
    title: str
    summary: str | None = None
    pages: int
    copies: int
    duplex: bool
    color: bool
    landscape: bool
    requested_by: str


@router.post("/next", response_model=StationJob | None)
async def next_job(
    printer: str | None = Query(None, max_length=200), color: bool | None = Query(None), duplex: bool | None = Query(None),
    scope: Scope = Depends(get_scope),
):
    """The station's every-few-seconds call: it counts as "on", and takes the oldest waiting job (204 when none)."""
    branch = _branch(scope)
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            await conn.execute(
                "insert into print_stations (branch_id, printer, color, duplex, last_seen_at) values ($1, $2, $3, $4, now()) "
                "on conflict (branch_id) do update set printer = excluded.printer, color = excluded.color, "
                "duplex = excluded.duplex, last_seen_at = now()",
                branch, printer, color, duplex,
            )
            await _sweep(conn)
            row = await conn.fetchrow(
                """
                update print_jobs set status = 'printing', claimed_at = now(), printer = $2
                where id = (select id from print_jobs where branch_id = $1 and status = 'queued' order by id limit 1 for update skip locked)
                returning id, title, summary, pages, copies, duplex, color, landscape, requested_by
                """,
                branch, printer,
            )
    if row is None:
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    return StationJob(**dict(row))


async def _own_job(conn, scope: Scope, job_id: int, *, columns: str = "*"):
    row = await conn.fetchrow(
        f"select {columns} from print_jobs where id = $1 and {branch_filter('branch_id', 2)}", job_id, scope.ids
    )
    if row is None:
        raise not_found("Chop etish topshirig'i")
    return row


@router.get("/{job_id}/file")
async def job_file(job_id: int, scope: Scope = Depends(get_scope)):
    async with db.pool().acquire() as conn:
        row = await _own_job(conn, scope, job_id, columns="status, data")
    if row["data"] is None or row["status"] not in ("queued", "printing"):
        raise not_found("Fayl")
    return Response(bytes(row["data"]), media_type="application/pdf")


class PrintResult(BaseModel):
    ok: bool
    error: str | None = Field(None, max_length=300)


@router.post("/{job_id}/result", status_code=status.HTTP_204_NO_CONTENT)
async def job_result(job_id: int, payload: PrintResult, scope: Scope = Depends(get_scope)):
    async with db.pool().acquire() as conn:
        await _own_job(conn, scope, job_id, columns="id")
        await conn.execute(
            "update print_jobs set status = $2, error = $3, finished_at = now(), data = null "
            "where id = $1 and status = 'printing'",
            job_id, "done" if payload.ok else "failed", None if payload.ok else (payload.error or "Printer xato berdi."),
        )


class PrintHistoryItem(BaseModel):
    id: int
    title: str
    summary: str | None = None
    pages: int
    copies: int
    requested_by: str
    requested_role: str
    status: str
    error: str | None = None
    created_at: str
    finished_at: str | None = None


@router.get("", response_model=list[PrintHistoryItem])
async def history(limit: int = Query(30, ge=1, le=100), scope: Scope = Depends(get_scope)):
    """Who printed what lately, newest first -- in the branch in view."""
    async with db.pool().acquire() as conn:
        await _sweep(conn)
        rows = await conn.fetch(
            f"select id, title, summary, pages, copies, requested_by, requested_role, status, error, created_at, finished_at "
            f"from print_jobs where {branch_filter('branch_id', 1)} order by id desc limit $2",
            scope.ids, limit,
        )
    return [
        PrintHistoryItem(**{**dict(r), "created_at": r["created_at"].isoformat(), "finished_at": r["finished_at"].isoformat() if r["finished_at"] else None})
        for r in rows
    ]


@router.post("/{job_id}/cancel", status_code=status.HTTP_204_NO_CONTENT)
async def cancel(job_id: int, scope: Scope = Depends(get_scope)):
    """Staff at the printer drop a waiting job; the person who sent it is told."""
    async with db.pool().acquire() as conn:
        await _own_job(conn, scope, job_id, columns="id")
        done = await conn.fetchval(
            "update print_jobs set status = 'cancelled', finished_at = now(), data = null, error = 'Administrator bekor qildi.' "
            "where id = $1 and status = 'queued' returning id",
            job_id,
        )
    if done is None:
        raise HTTPException(status.HTTP_409_CONFLICT, "Bekor qilib bo'lmaydi.")
