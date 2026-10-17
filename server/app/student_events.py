"""The "Amallar" log of a student: every time his place in the center changes."""


async def log(
    conn,
    student_id: int,
    kind: str,
    user_id: int | None,
    *,
    group_id: int | None = None,
    to_group_id: int | None = None,
    enrollment_id: int | None = None,
    to_enrollment_id: int | None = None,
    note: str | None = None,
    debt: int | None = None,
) -> None:
    """Writes one event, taking the group names as they are right now so the
    entry still reads the same after a group is renamed."""
    names = {
        row["id"]: row["name"]
        for row in await conn.fetch(
            "select id, name from groups where id = any($1::bigint[])",
            [g for g in (group_id, to_group_id) if g is not None],
        )
    }
    await conn.execute(
        """
        insert into student_events (student_id, kind, group_id, group_name, to_group_id, to_group_name,
                                    enrollment_id, to_enrollment_id, note, debt, created_by)
        values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
        """,
        student_id, kind, group_id, names.get(group_id), to_group_id, names.get(to_group_id),
        enrollment_id, to_enrollment_id, (note or "").strip() or None, debt, user_id,
    )
