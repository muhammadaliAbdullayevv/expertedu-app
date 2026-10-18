"""Branches: Bosh ofis and the filiallar. The owner sees and manages them
all; an admin sees only their own."""

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, status

from .. import db
from ..deps import CurrentUser, get_current_user, require_owner
from ..schemas import Branch, CreateBranchRequest, UpdateBranchRequest

router = APIRouter(prefix="/branches", tags=["branches"])

_SELECT = "select id, name, is_headquarters, is_active from branches"


@router.get("", response_model=list[Branch])
async def list_branches(user: CurrentUser = Depends(get_current_user)):
    if user.is_owner:
        rows = await db.pool().fetch(f"{_SELECT} order by is_headquarters desc, name")
    else:
        rows = await db.pool().fetch(f"{_SELECT} where id = $1", user.branch_id)
    return [Branch(**row) for row in rows]


@router.post("", response_model=Branch, status_code=status.HTTP_201_CREATED)
async def create_branch(payload: CreateBranchRequest, user: CurrentUser = Depends(require_owner)):
    name = payload.name.strip()
    if not name:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Filial nomini kiriting.")
    try:
        row = await db.pool().fetchrow(
            "insert into branches (name) values ($1) returning id, name, is_headquarters, is_active", name
        )
    except asyncpg.UniqueViolationError:
        raise HTTPException(status.HTTP_409_CONFLICT, "Bu nomli filial allaqachon bor.")
    return Branch(**row)


@router.patch("/{branch_id}", response_model=Branch)
async def update_branch(branch_id: int, payload: UpdateBranchRequest, user: CurrentUser = Depends(require_owner)):
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            row = await conn.fetchrow(f"{_SELECT} where id = $1 for update", branch_id)
            if row is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Filial topilmadi.")
            if payload.name is not None:
                name = payload.name.strip()
                if not name:
                    raise HTTPException(status.HTTP_400_BAD_REQUEST, "Filial nomini kiriting.")
                try:
                    await conn.execute("update branches set name = $2 where id = $1", branch_id, name)
                except asyncpg.UniqueViolationError:
                    raise HTTPException(status.HTTP_409_CONFLICT, "Bu nomli filial allaqachon bor.")
            if payload.is_active is not None and payload.is_active != row["is_active"]:
                if row["is_headquarters"]:
                    raise HTTPException(status.HTTP_400_BAD_REQUEST, "Bosh ofisni o'chirib bo'lmaydi.")
                await conn.execute("update branches set is_active = $2 where id = $1", branch_id, payload.is_active)
            return Branch(**await conn.fetchrow(f"{_SELECT} where id = $1", branch_id))
