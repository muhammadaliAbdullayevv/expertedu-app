from fastapi import APIRouter, Depends

from .. import db
from ..deps import Scope, get_current_user, get_scope
from ..schemas import UserBrief

router = APIRouter(prefix="/users", tags=["users"], dependencies=[Depends(get_current_user)])


@router.get("", response_model=list[UserBrief])
async def list_users(scope: Scope = Depends(get_scope)):
    """Active staff accounts -- who a lead or task can be assigned to: the
    admins of the branch in view, and the owner."""
    rows = await db.pool().fetch(
        """
        select u.id, u.full_name, u.role from users u left join user_branches ub on ub.user_id = u.id
        where u.is_active and (u.role = 'owner' or $1::bigint[] is null or ub.branch_id = any($1::bigint[]))
        order by u.full_name asc
        """,
        scope.ids,
    )
    return [UserBrief(**row) for row in rows]
