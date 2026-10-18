from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.responses import FileResponse

from .. import db, photos
from ..deps import Scope, get_current_user, get_scope
from ..scope import require_student, require_teacher
from ..schemas import PhotoResult

router = APIRouter(prefix="/photos", tags=["photos"], dependencies=[Depends(get_current_user)])

_TABLES = {"teachers": ("teachers", "teacher", "O'qituvchi topilmadi."), "students": ("students", "student", "O'quvchi topilmadi.")}


def _owner(group: str) -> tuple[str, str, str]:
    if group not in _TABLES:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Topilmadi.")
    return _TABLES[group]


async def _visible(scope: Scope, group: str, owner_id: int) -> None:
    """The person must be one this request's branch scope may see."""
    if group == "students":
        await require_student(db.pool(), scope, owner_id)
    else:
        await require_teacher(db.pool(), scope, owner_id)


@router.get("/file/{name}")
async def get_photo(name: str, scope: Scope = Depends(get_scope)):
    """Behind login on purpose: these are pictures of students -- and only of
    people in the branch in view."""
    path = photos.path_for(name)
    if path is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Rasm topilmadi.")
    kind, owner_id = name.split("-")[0], int(name.split("-")[1])
    await _visible(scope, "students" if kind == "student" else "teachers", owner_id)
    # The name changes with every new photo, so a copy never goes stale.
    return FileResponse(path, headers={"Cache-Control": "private, max-age=31536000, immutable"})


@router.put("/{group}/{owner_id}", response_model=PhotoResult)
async def set_photo(group: str, owner_id: int, request: Request, scope: Scope = Depends(get_scope)):
    """The picture is the request body itself (PNG, JPEG or WebP, up to 2 MB)."""
    table, kind, missing = _owner(group)
    await _visible(scope, group, owner_id)
    declared = request.headers.get("content-length")
    if declared and declared.isdigit() and int(declared) > photos.MAX_BYTES:
        raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, "Rasm juda katta (2 MB dan oshmasin).")
    data = await request.body()
    photos.check(data)
    old = await db.pool().fetchval(f"select photo from {table} where id = $1", owner_id)
    if old is None and not await db.pool().fetchval(f"select 1 from {table} where id = $1", owner_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, missing)
    name = photos.store(kind, owner_id, data)
    await db.pool().execute(f"update {table} set photo = $2 where id = $1", owner_id, name)
    photos.remove(old)
    return PhotoResult(photo=name)


@router.delete("/{group}/{owner_id}", response_model=PhotoResult)
async def delete_photo(group: str, owner_id: int, scope: Scope = Depends(get_scope)):
    table, _, missing = _owner(group)
    await _visible(scope, group, owner_id)
    row = await db.pool().fetchrow(f"select photo from {table} where id = $1", owner_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, missing)
    await db.pool().execute(f"update {table} set photo = null where id = $1", owner_id)
    photos.remove(row["photo"])
    return PhotoResult(photo=None)
