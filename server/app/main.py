from contextlib import asynccontextmanager

from fastapi import FastAPI

from . import db
from .routes import auth, health


@asynccontextmanager
async def lifespan(app: FastAPI):
    await db.connect()
    yield
    await db.disconnect()


app = FastAPI(title="Expert Edu Center API", lifespan=lifespan)

app.include_router(health.router)
app.include_router(auth.router)
