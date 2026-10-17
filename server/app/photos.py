"""Profile photos: validation and the files on disk.

The app shrinks the picture before sending it; here we only make sure it
really is a small PNG, JPEG or WebP, give it a name nobody can guess, and
keep one file per person (a new photo replaces the old one)."""

import re
import secrets
from pathlib import Path

from fastapi import HTTPException, status

from .config import settings

MAX_BYTES = 2 * 1024 * 1024
KINDS = ("teacher", "student")
_NAME = re.compile(r"^(teacher|student)-\d+-[0-9a-f]{16}\.(png|jpg|webp)$")


def sniff(data: bytes) -> str | None:
    """The extension a picture's first bytes say it is, or None."""
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if data.startswith(b"\xff\xd8\xff"):
        return "jpg"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    return None


def directory() -> Path:
    path = Path(settings.photos_dir)
    path.mkdir(parents=True, exist_ok=True)
    return path


def check(data: bytes) -> str:
    if not data:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Rasm yuborilmadi.")
    if len(data) > MAX_BYTES:
        raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, "Rasm juda katta (2 MB dan oshmasin).")
    extension = sniff(data)
    if extension is None:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Faqat PNG, JPG yoki WebP rasm yuklash mumkin.")
    return extension


def store(kind: str, owner_id: int, data: bytes) -> str:
    """Writes the picture and returns its stored name."""
    extension = check(data)
    name = f"{kind}-{owner_id}-{secrets.token_hex(8)}.{extension}"
    (directory() / name).write_bytes(data)
    return name


def remove(name: str | None) -> None:
    if name and _NAME.match(name):
        (directory() / name).unlink(missing_ok=True)


def path_for(name: str) -> Path | None:
    """The file for a stored name -- only names we made ourselves."""
    if not _NAME.match(name):
        return None
    path = directory() / name
    return path if path.is_file() else None
