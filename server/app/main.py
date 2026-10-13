from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from . import db
from .routes import auth, enrollments, groups, health, students

_UPLOADS_DIR = Path(__file__).resolve().parent.parent / "uploads"


@asynccontextmanager
async def lifespan(app: FastAPI):
    await db.connect()
    yield
    await db.disconnect()


app = FastAPI(title="Expert Edu Center API", lifespan=lifespan)

_UPLOADS_DIR.mkdir(parents=True, exist_ok=True)
app.mount("/uploads", StaticFiles(directory=str(_UPLOADS_DIR)), name="uploads")

app.include_router(health.router)
app.include_router(auth.router)
app.include_router(groups.router)
app.include_router(students.router)
app.include_router(enrollments.router)
