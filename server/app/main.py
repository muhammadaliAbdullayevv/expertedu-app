import asyncio
from contextlib import asynccontextmanager, suppress
from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from . import db
from .jobs import recurring_charges
from .routes import (
    auth,
    dashboard,
    debtors,
    enrollments,
    groups,
    health,
    inquiries,
    students,
    subjects,
    teachers,
    transactions,
)

_UPLOADS_DIR = Path(__file__).resolve().parent.parent / "uploads"


@asynccontextmanager
async def lifespan(app: FastAPI):
    await db.connect()
    billing_job = asyncio.create_task(recurring_charges.run_forever())
    yield
    billing_job.cancel()
    with suppress(asyncio.CancelledError):
        await billing_job
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
app.include_router(inquiries.router)
app.include_router(dashboard.router)
app.include_router(debtors.router)
app.include_router(teachers.router)
