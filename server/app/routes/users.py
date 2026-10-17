from fastapi import APIRouter, Depends

from .. import db
from ..deps import get_current_user
from ..schemas import UserBrief

router = APIRouter(prefix="/users", tags=["users"], dependencies=[Depends(get_current_user)])


@router.get("", response_model=list[UserBrief])
async def list_users():
    """Active staff accounts -- who a lead or task can be assigned to."""
    rows = await db.pool().fetch(
        "select id, full_name, role from users where is_active order by full_name asc"
    )
    return [UserBrief(**row) for row in rows]
