"""Database-backed test setup.

Tests that take the `api` fixture run against a real PostgreSQL: a
throwaway cluster started for the test session (needs `initdb` and
`pg_ctl` on PATH), or the empty database in TEST_DATABASE_URL if set.
Every test starts from a freshly truncated schema.sql database.
"""

import os
import shutil
import socket
import subprocess
from dataclasses import dataclass
from pathlib import Path

# app.config reads these at import time.
os.environ.setdefault("DATABASE_URL", "postgresql://unused")
os.environ.setdefault("JWT_SECRET", "test-secret")

import asyncpg  # noqa: E402
import httpx  # noqa: E402
import pytest  # noqa: E402

from app import db  # noqa: E402
from app.config import settings  # noqa: E402
from app.main import app  # noqa: E402
from app.security import create_access_token  # noqa: E402

SERVER_DIR = Path(__file__).resolve().parent.parent


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@pytest.fixture(scope="session")
def postgres_server(tmp_path_factory):
    """URL of a server where tests may create databases (no db name)."""
    if os.environ.get("TEST_DATABASE_URL"):
        yield None
        return
    if not (shutil.which("initdb") and shutil.which("pg_ctl")):
        pytest.skip("PostgreSQL (initdb/pg_ctl) not installed and TEST_DATABASE_URL not set")
    root = tmp_path_factory.mktemp("pg")
    data = root / "data"
    port = _free_port()
    subprocess.run(
        ["initdb", "-D", str(data), "-U", "postgres", "--auth=trust", "-E", "UTF8", "--no-locale"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        [
            "pg_ctl", "-D", str(data), "-w", "-l", str(root / "server.log"),
            "-o", f"-p {port} -c listen_addresses=127.0.0.1 -c unix_socket_directories='' -c fsync=off",
            "start",
        ],
        check=True,
        capture_output=True,
    )
    try:
        yield f"postgresql://postgres@127.0.0.1:{port}"
    finally:
        subprocess.run(["pg_ctl", "-D", str(data), "-w", "-m", "immediate", "stop"], capture_output=True)


@pytest.fixture(scope="session")
def anyio_backend():
    return "asyncio"


@pytest.fixture(scope="session")
async def database_url(postgres_server):
    if postgres_server is None:
        url = os.environ["TEST_DATABASE_URL"]
    else:
        admin = await asyncpg.connect(f"{postgres_server}/postgres")
        await admin.execute("create database app_test")
        await admin.close()
        url = f"{postgres_server}/app_test"
    conn = await asyncpg.connect(url)
    await conn.execute((SERVER_DIR / "schema.sql").read_text())
    await conn.close()
    return url


@pytest.fixture(scope="session")
async def pool(database_url):
    settings.database_url = database_url
    await db.connect()
    yield db.pool()
    await db.disconnect()


@dataclass
class Api:
    client: httpx.AsyncClient
    owner_id: int
    admin_id: int
    pool: asyncpg.Pool

    def as_admin(self) -> httpx.AsyncClient:
        token = create_access_token(user_id=self.admin_id, role="admin", token_version=0)
        return httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app),
            base_url="http://test",
            headers={"Authorization": f"Bearer {token}"},
        )


class _TestPool:
    """The pool tests use for direct SQL. A teacher or student inserted by hand is
    put in Bosh ofis, as the app would when the owner adds one there -- so the many
    fixtures that seed teachers with raw SQL need no branch plumbing. (Branch
    tests make their teachers through the API or link them explicitly.)"""

    def __init__(self, inner):
        self._inner = inner

    def __getattr__(self, name):
        return getattr(self._inner, name)

    async def _linked(self, sql, result):
        lowered = sql.lower()
        if "insert into teachers" in lowered:
            await self._inner.execute(
                "insert into teacher_branches (teacher_id, branch_id) select id, 1 from teachers on conflict do nothing"
            )
        if "insert into students" in lowered:
            await self._inner.execute(
                "insert into student_branches (student_id, branch_id) select id, 1 from students on conflict do nothing"
            )
        return result

    async def execute(self, sql, *args, **kw):
        return await self._linked(sql, await self._inner.execute(sql, *args, **kw))

    async def fetch(self, sql, *args, **kw):
        return await self._linked(sql, await self._inner.fetch(sql, *args, **kw))

    async def fetchrow(self, sql, *args, **kw):
        return await self._linked(sql, await self._inner.fetchrow(sql, *args, **kw))

    async def fetchval(self, sql, *args, **kw):
        return await self._linked(sql, await self._inner.fetchval(sql, *args, **kw))


@pytest.fixture
async def api(pool):
    tables = await pool.fetch(
        "select tablename from pg_tables where schemaname = 'public'"
    )
    await pool.execute(
        "truncate " + ", ".join(row["tablename"] for row in tables) + " restart identity cascade"
    )
    # Truncating wiped Bosh ofis (id 1) too: every test starts with it.
    await pool.execute("insert into branches (name, is_headquarters) values ('Bosh ofis', true)")
    owner_id = await pool.fetchval(
        "insert into users (phone, password_hash, full_name, role) values ('998900000001', 'x', 'Owner', 'owner') "
        "returning id"
    )
    admin_id = await pool.fetchval(
        "insert into users (phone, password_hash, full_name, role) values ('998900000002', 'x', 'Operator', 'admin') "
        "returning id"
    )
    await pool.execute("insert into user_branches (user_id, branch_id) values ($1, 1)", admin_id)
    token = create_access_token(user_id=owner_id, role="owner", token_version=0)
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app),
        base_url="http://test",
        headers={"Authorization": f"Bearer {token}"},
    ) as client:
        yield Api(client=client, owner_id=owner_id, admin_id=admin_id, pool=_TestPool(pool))
