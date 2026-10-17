from fastapi import APIRouter, Depends

from .. import db, funnel
from ..deps import get_current_user
from ..schemas import ShellCounts

router = APIRouter(tags=["counts"], dependencies=[Depends(get_current_user)])


@router.get("/counts", response_model=ShellCounts)
async def shell_counts():
    """The sidebar badges, from app/funnel.py."""
    async with db.pool().acquire() as conn:
        return ShellCounts(**await funnel.shell_counts(conn))
