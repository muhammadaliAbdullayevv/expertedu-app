"""The migrations, applied in order to an empty database, must end up with
the same tables, columns, constraints and indexes as schema.sql -- and
0008's rollback must bring back 0007's inquiries."""

import os

import asyncpg
import pytest

from conftest import SERVER_DIR

pytestmark = pytest.mark.anyio

MIGRATIONS = sorted((SERVER_DIR / "migrations").glob("0*.sql"))


async def _fresh_db(server: str, name: str) -> asyncpg.Connection:
    admin = await asyncpg.connect(f"{server}/postgres")
    await admin.execute(f"drop database if exists {name}")
    await admin.execute(f"create database {name}")
    await admin.close()
    return await asyncpg.connect(f"{server}/{name}")


async def _apply(conn: asyncpg.Connection, path) -> None:
    async with conn.transaction():
        await conn.execute(path.read_text())


async def _shape(conn: asyncpg.Connection) -> dict:
    columns = await conn.fetch(
        """
        select table_name, column_name, data_type, is_nullable, column_default
        from information_schema.columns where table_schema = 'public'
        """
    )
    constraints = await conn.fetch(
        """
        select conrelid::regclass::text as table_name, conname, pg_get_constraintdef(oid) as definition
        from pg_constraint
        where connamespace = 'public'::regnamespace and contype <> 'n'
        """
    )
    indexes = await conn.fetch("select indexname, indexdef from pg_indexes where schemaname = 'public'")
    triggers = await conn.fetch("select tgname from pg_trigger where not tgisinternal")
    return {
        "columns": {tuple(row) for row in columns},
        "constraints": {tuple(row) for row in constraints},
        "indexes": {tuple(row) for row in indexes},
        "triggers": {row["tgname"] for row in triggers},
    }


@pytest.fixture
def server(postgres_server):
    if postgres_server is None:
        pytest.skip("needs a throwaway cluster, not TEST_DATABASE_URL")
    return postgres_server


async def test_migrations_match_schema_sql(server):
    migrated = await _fresh_db(server, "migrated")
    fresh = await _fresh_db(server, "fresh")
    try:
        for path in MIGRATIONS:
            await _apply(migrated, path)
        await fresh.execute((SERVER_DIR / "schema.sql").read_text())
        assert await _shape(migrated) == await _shape(fresh)
    finally:
        await migrated.close()
        await fresh.close()


async def test_0008_converts_old_inquiries_and_rolls_back(server):
    conn = await _fresh_db(server, "rollback_check")
    try:
        for path in MIGRATIONS:
            if path.name.startswith("0008"):
                break
            await _apply(conn, path)
        await conn.execute(
            """
            insert into users (phone, password_hash, full_name, role) values ('998900000001', 'x', 'Owner', 'owner');
            insert into students (full_name, phone) values ('Ali', '998901112233');
            insert into inquiries (full_name, phone, status, trial_date, created_by) values
              ('A', '+998 90 000 00 01', 'new', '2026-10-20', 1),
              ('B', '901234567', 'scheduled', null, 1),
              ('C', '998901112233', 'converted', null, 1),
              ('D', '998900000004', 'lost', null, 1);
            update inquiries set converted_student_id = 1 where full_name = 'C';
            """
        )
        before = await _shape(conn)

        await _apply(conn, SERVER_DIR / "migrations" / "0008_admissions.sql")
        rows = await conn.fetch("select full_name, phone, stage, student_id, closed_at from leads order by id")
        assert [(row["full_name"], row["phone"], row["stage"]) for row in rows] == [
            ("A", "998900000001", "new"),
            ("B", "998901234567", "contacted"),
            # Old "converted" only made a student, never an enrollment.
            ("C", "998901112233", "decision_pending"),
            ("D", "998900000004", "not_interested"),
        ]
        assert rows[2]["student_id"] == 1
        assert rows[3]["closed_at"] is not None
        assert await conn.fetchval("select count(*) from lead_interactions") == 4

        await _apply(conn, SERVER_DIR / "migrations" / "rollback" / "0008_admissions.sql")
        statuses = await conn.fetch("select full_name, status from inquiries order by id")
        assert [tuple(row) for row in statuses] == [("A", "new"), ("B", "contacted"), ("C", "contacted"), ("D", "lost")]
        after = await _shape(conn)
        # Same tables, columns and indexes as before 0008 (Postgres 18 names
        # NOT NULL constraints after the table, which is why they're left out).
        assert after == before
    finally:
        await conn.close()


def test_migration_files_are_numbered_in_order():
    numbers = [int(path.name[:4]) for path in MIGRATIONS]
    assert numbers == list(range(1, len(numbers) + 1)), [path.name for path in MIGRATIONS]
    assert os.path.exists(SERVER_DIR / "migrations" / "rollback" / "0008_admissions.sql")
