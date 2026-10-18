import asyncio
import logging
import time
from contextlib import asynccontextmanager, suppress
from pathlib import Path

from fastapi import Depends, FastAPI
from fastapi.staticfiles import StaticFiles

from . import db
from .deps import get_scope
from .jobs import housekeeping, recurring_charges
from .routes import (
    admissions_report,
    auth,
    branches,
    counts,
    dashboard,
    debtors,
    enrollments,
    finance,
    follow_ups,
    groups,
    photos,
    health,
    inquiries,
    leads,
    staff,
    students,
    subjects,
    timetable,
    teachers,
    transactions,
    trials,
    users,
)

_UPLOADS_DIR = Path(__file__).resolve().parent.parent / "uploads"


@asynccontextmanager
async def lifespan(app: FastAPI):
    await db.connect()
    jobs = [
        asyncio.create_task(recurring_charges.run_forever()),
        asyncio.create_task(housekeeping.run_forever()),
    ]
    yield
    for job in jobs:
        job.cancel()
    for job in jobs:
        with suppress(asyncio.CancelledError):
            await job
    await db.disconnect()


app = FastAPI(title="Expert Edu Center API", lifespan=lifespan)

_slow = logging.getLogger("expertedu.slow")


@app.middleware("http")
async def log_slow_requests(request, call_next):
    """Says in the journal which requests took over two seconds, so a "server
    did not answer" report can be matched with what the server was doing."""
    started = time.monotonic()
    response = await call_next(request)
    took = time.monotonic() - started
    if took > 2:
        _slow.warning("SLOW %s %s took %.1fs -> %s", request.method, request.url.path, took, response.status_code)
    return response

_UPLOADS_DIR.mkdir(parents=True, exist_ok=True)
app.mount("/uploads", StaticFiles(directory=str(_UPLOADS_DIR)), name="uploads")

app.include_router(health.router)
app.include_router(auth.router)
app.include_router(branches.router)
# Everything below runs inside a branch scope: get_scope is a dependency of
# every one of these routers, so the scope is always known while the request
# is served (tests/test_branches.py checks no route escapes this).
_scoped = {"dependencies": [Depends(get_scope)]}
app.include_router(subjects.router, **_scoped)
app.include_router(groups.router, **_scoped)
app.include_router(students.router, **_scoped)
app.include_router(enrollments.router, **_scoped)
app.include_router(transactions.router, **_scoped)
app.include_router(counts.router, **_scoped)
app.include_router(inquiries.router, **_scoped)
app.include_router(dashboard.router, **_scoped)
app.include_router(debtors.router, **_scoped)
app.include_router(teachers.router, **_scoped)
app.include_router(leads.router, **_scoped)
app.include_router(trials.router, **_scoped)
app.include_router(follow_ups.router, **_scoped)
app.include_router(admissions_report.router, **_scoped)
app.include_router(users.router, **_scoped)
app.include_router(staff.router, **_scoped)
app.include_router(timetable.router, **_scoped)
app.include_router(finance.router, **_scoped)
app.include_router(photos.router, **_scoped)
