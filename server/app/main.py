import asyncio
from contextlib import asynccontextmanager, suppress
from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from . import db
from .jobs import housekeeping, recurring_charges
from .routes import (
    admissions_report,
    auth,
    counts,
    dashboard,
    debtors,
    enrollments,
    finance,
    follow_ups,
    groups,
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

_UPLOADS_DIR.mkdir(parents=True, exist_ok=True)
app.mount("/uploads", StaticFiles(directory=str(_UPLOADS_DIR)), name="uploads")

app.include_router(health.router)
app.include_router(auth.router)
app.include_router(subjects.router)
app.include_router(groups.router)
app.include_router(students.router)
app.include_router(enrollments.router)
app.include_router(transactions.router)
app.include_router(counts.router)
app.include_router(inquiries.router)
app.include_router(dashboard.router)
app.include_router(debtors.router)
app.include_router(teachers.router)
app.include_router(leads.router)
app.include_router(trials.router)
app.include_router(follow_ups.router)
app.include_router(admissions_report.router)
app.include_router(users.router)
app.include_router(staff.router)
app.include_router(timetable.router)
app.include_router(finance.router)
