"""One-off: creates the center's owner account. Run once per deployment --
there's no self-serve signup, since this is single-tenant software (one
deployment == one education center).

Usage: DATABASE_URL=... python scripts/create_owner.py <phone> <full_name> <password>
"""
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import db  # noqa: E402
from app.phone import normalize  # noqa: E402
from app.security import hash_password  # noqa: E402


async def main() -> None:
    phone, full_name, password = sys.argv[1], sys.argv[2], sys.argv[3]
    await db.connect()
    try:
        row = await db.pool().fetchrow(
            """
            insert into users (phone, full_name, password_hash, role)
            values ($1, $2, $3, 'owner')
            returning id
            """,
            normalize(phone),
            full_name.strip(),
            hash_password(password),
        )
        print(f"Created owner user id={row['id']}")
    finally:
        await db.disconnect()


if __name__ == "__main__":
    asyncio.run(main())
