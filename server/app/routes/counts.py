from fastapi import APIRouter, Depends

from .. import db, funnel
from ..deps import Scope, get_current_user, get_scope
from ..schemas import ShellCounts

router = APIRouter(tags=["counts"], dependencies=[Depends(get_current_user)])


@router.get("/counts", response_model=ShellCounts)
async def shell_counts(scope: Scope = Depends(get_scope)):
    """The sidebar badges, from app/funnel.py."""
    async with db.pool().acquire() as conn:
        return ShellCounts(**await funnel.shell_counts(conn, scope.ids))
