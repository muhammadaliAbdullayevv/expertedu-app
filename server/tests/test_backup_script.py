"""ops/backup.sh and ops/pull-backups.sh, run for real against a throwaway PostgreSQL and a fake Telegram."""

import http.server
import io
import os
import shutil
import sqlite3
import subprocess
import tarfile
import threading
import time
from urllib.parse import parse_qs
from pathlib import Path

import asyncpg
import pytest

from conftest import SERVER_DIR

pytestmark = pytest.mark.anyio

OPS = SERVER_DIR / "ops"
TOKEN = "123456:SECRET-TOKEN-VALUE"
PASSPHRASE = "correct horse battery staple"

for tool in ("pg_dump", "pg_restore", "openssl", "curl", "rsync"):
    if not shutil.which(tool):
        pytest.skip(f"{tool} not installed", allow_module_level=True)


class FakeTelegram:
    """Records every request the script makes to the Telegram Bot API."""

    def __init__(self):
        self.requests: list[tuple[str, bytes]] = []
        fake = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                fake.requests.append((self.path, body))
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"ok":true}')

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()


@pytest.fixture
def telegram():
    fake = FakeTelegram()
    yield fake
    fake.close()


@pytest.fixture
async def source(postgres_server):
    if postgres_server is None:
        pytest.skip("needs a throwaway cluster, not TEST_DATABASE_URL")
    admin = await asyncpg.connect(f"{postgres_server}/postgres")
    for name in ("backup_src", "backup_dst"):
        await admin.execute(f"drop database if exists {name}")
    await admin.execute("create database backup_src")
    await admin.close()
    conn = await asyncpg.connect(f"{postgres_server}/backup_src")
    await conn.execute("create table students (id serial primary key, full_name text, phone text)")
    await conn.execute("insert into students (full_name, phone) values ('Botir Aliyev', '998901110001'), ('Aziza Karimova', '998901110003')")
    await conn.close()
    return postgres_server


def setup_env(tmp_path: Path, db_url: str, telegram: FakeTelegram, *, passphrase: bool = True) -> dict:
    (tmp_path / "app.env").write_text(f"DATABASE_URL={db_url}\nOTHER=1\n")
    (tmp_path / "bot.env").write_text(f"BOT_TOKEN={TOKEN}\nOWNER_IDS=4242,5555\n")
    sqlite_path = tmp_path / "bot.sqlite3"
    conn = sqlite3.connect(sqlite_path)
    conn.execute("create table books (title text)")
    conn.execute("insert into books values ('English File')")
    conn.commit()
    conn.close()
    if passphrase:
        (tmp_path / "pass").write_text(PASSPHRASE + "\n")
    return {
        **os.environ,
        "APP_ENV": str(tmp_path / "app.env"),
        "BOT_ENV": str(tmp_path / "bot.env"),
        "PASS_FILE": str(tmp_path / "pass"),
        "BOT_DB": str(sqlite_path),
        "BACKUP_DIR": str(tmp_path / "daily"),
        "TG_API": telegram.url,
    }


def run_backup(env: dict, **extra) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(OPS / "backup.sh")], env={**env, **extra}, capture_output=True, text=True, timeout=120)


def message_text(body: bytes) -> str:
    """The text of a sendMessage request (form-encoded)."""
    return parse_qs(body.decode())["text"][0]


def decrypt(path: Path) -> bytes:
    return subprocess.run(
        ["openssl", "enc", "-d", "-aes-256-cbc", "-pbkdf2", "-iter", "200000", "-pass", f"pass:{PASSPHRASE}", "-in", str(path)],
        check=True, capture_output=True,
    ).stdout


async def test_a_backup_is_encrypted_restorable_and_sent_to_the_owner(tmp_path, source, telegram):
    env = setup_env(tmp_path, f"{source}/backup_src", telegram)
    done = run_backup(env, STAMP="20261018_030000")
    assert done.returncode == 0, done.stderr
    (backup,) = list((tmp_path / "daily").iterdir())
    assert backup.name == "expertedu-20261018_030000.tar.gz.enc" and oct(backup.stat().st_mode)[-3:] == "600"
    assert b"Botir Aliyev" not in backup.read_bytes() and b"998901110001" not in backup.read_bytes()  # not readable without the passphrase

    # opened with the passphrase: a database dump and the bot's file
    with tarfile.open(fileobj=io.BytesIO(decrypt(backup)), mode="r:gz") as tar:
        names = sorted(m.name.lstrip("./") for m in tar.getmembers() if m.isfile())
        assert names == ["bot.sqlite3", "expertedu.dump"]
        tar.extractall(tmp_path / "opened", filter="data")
    # the dump restores into a fresh database with the same rows
    admin = await asyncpg.connect(f"{source}/postgres")
    await admin.execute("create database backup_dst")
    await admin.close()
    subprocess.run(["pg_restore", "--no-owner", "-d", f"{source}/backup_dst", str(tmp_path / "opened" / "expertedu.dump")], check=True, capture_output=True)
    conn = await asyncpg.connect(f"{source}/backup_dst")
    assert [r["full_name"] for r in await conn.fetch("select full_name from students order by id")] == ["Botir Aliyev", "Aziza Karimova"]
    await conn.close()
    assert sqlite3.connect(tmp_path / "opened" / "bot.sqlite3").execute("select title from books").fetchall() == [("English File",)]

    # sent to the first owner id, as a document, and it is the encrypted file
    (path, body), = telegram.requests
    assert path == f"/bot{TOKEN}/sendDocument"
    assert b'name="chat_id"\r\n\r\n4242' in body and "encrypted".encode() in body
    assert backup.read_bytes() in body and b"Botir Aliyev" not in body
    assert TOKEN not in done.stdout + done.stderr  # the token is never printed


async def test_old_backups_are_rotated_out(tmp_path, source, telegram):
    env = setup_env(tmp_path, f"{source}/backup_src", telegram)
    for day in range(1, 6):
        assert run_backup(env, STAMP=f"2026100{day}_030000", KEEP="3", SEND_TELEGRAM="0").returncode == 0
        os.utime(tmp_path / "daily" / f"expertedu-2026100{day}_030000.tar.gz.enc", (day * 1000, day * 1000))
    assert sorted(p.name for p in (tmp_path / "daily").iterdir()) == [f"expertedu-2026100{d}_030000.tar.gz.enc" for d in (3, 4, 5)]
    assert telegram.requests == []  # SEND_TELEGRAM=0


async def test_without_the_passphrase_nothing_unencrypted_is_made_and_the_owner_is_told(tmp_path, source, telegram):
    env = setup_env(tmp_path, f"{source}/backup_src", telegram, passphrase=False)
    done = run_backup(env)
    assert done.returncode != 0 and "passphrase" in done.stderr
    assert not (tmp_path / "daily").exists() or list((tmp_path / "daily").iterdir()) == []
    (path, body), = telegram.requests
    assert path.endswith("/sendMessage") and "Backup failed" in message_text(body) and "passphrase" in message_text(body)


async def test_a_database_that_cannot_be_dumped_is_reported(tmp_path, source, telegram):
    env = setup_env(tmp_path, f"{source}/does_not_exist", telegram)
    done = run_backup(env)
    assert done.returncode != 0
    assert list((tmp_path / "daily").iterdir()) == [] if (tmp_path / "daily").exists() else True
    (path, body), = telegram.requests
    assert path.endswith("/sendMessage") and "pg_dump" in message_text(body)


async def test_a_pack_too_big_for_telegram_is_announced_not_sent(tmp_path, source, telegram):
    env = setup_env(tmp_path, f"{source}/backup_src", telegram)
    done = run_backup(env, MAX_TELEGRAM_BYTES="10")
    assert done.returncode == 0
    (path, body), = telegram.requests
    assert path.endswith("/sendMessage") and "too big" in message_text(body)
    assert len(list((tmp_path / "daily").iterdir())) == 1  # still kept on the server


async def test_a_telegram_that_is_down_does_not_lose_the_backup(tmp_path, source, telegram):
    env = setup_env(tmp_path, f"{source}/backup_src", telegram)
    done = run_backup(env, TG_API="http://127.0.0.1:1")
    assert done.returncode == 0 and len(list((tmp_path / "daily").iterdir())) == 1


def local_pull_script(tmp_path: Path) -> Path:
    """pull-backups.sh with the server replaced by local folders (no ssh): same rsync, same pruning, same checks."""
    script = (OPS / "pull-backups.sh").read_text()
    script = script.replace('"$HOST:$REMOTE_BACKUPS"', '"$REMOTE_BACKUPS"').replace('"$HOST:$REMOTE_PHOTOS"', '"$REMOTE_PHOTOS"')
    script = script.replace('ssh_cmd="ssh', 'ssh_cmd="true ssh')
    local = tmp_path / "pull.sh"
    local.write_text(script)
    return local


def test_the_laptop_pull_copies_backups_and_photos_and_keeps_the_last_ones(tmp_path):
    remote = tmp_path / "remote"
    (remote / "daily").mkdir(parents=True)
    (remote / "photos").mkdir()
    now = time.time()
    for day in range(1, 5):  # day 4 is the newest
        f = remote / "daily" / f"expertedu-2026101{day}_030000.tar.gz.enc"
        f.write_bytes(b"x" * day)
        os.utime(f, (now - (5 - day) * 60, now - (5 - day) * 60))
    (remote / "photos" / "a.jpg").write_bytes(b"jpg")
    dest = tmp_path / "laptop"
    env = {**os.environ, "DEST": str(dest), "KEEP": "2", "REMOTE_BACKUPS": f"{remote}/daily/", "REMOTE_PHOTOS": f"{remote}/photos/"}
    done = subprocess.run(["bash", str(local_pull_script(tmp_path))], env=env, capture_output=True, text=True, timeout=60)
    assert done.returncode == 0, done.stderr
    assert sorted(p.name for p in (dest / "daily").iterdir()) == [f"expertedu-2026101{d}_030000.tar.gz.enc" for d in (3, 4)]
    assert (dest / "photos" / "a.jpg").read_bytes() == b"jpg"
    assert "pulled; newest: expertedu-20261014_030000" in done.stdout
    assert len(list((remote / "daily").iterdir())) == 4  # the server's copies are never touched


def test_the_laptop_pull_complains_when_the_server_backups_are_stale_or_missing(tmp_path):
    remote = tmp_path / "remote" / "daily"
    remote.mkdir(parents=True)
    (tmp_path / "remote" / "photos").mkdir()
    env = {**os.environ, "DEST": str(tmp_path / "laptop"), "REMOTE_BACKUPS": f"{remote}/", "REMOTE_PHOTOS": f"{tmp_path / 'remote' / 'photos'}/"}
    script = local_pull_script(tmp_path)
    done = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True, timeout=60)
    assert done.returncode != 0 and "no backup on the server yet" in done.stderr
    old = remote / "expertedu-20200101_030000.tar.gz.enc"
    old.write_bytes(b"x")
    os.utime(old, (1_000_000_000, 1_000_000_000))
    done = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True, timeout=60)
    assert done.returncode != 0 and "older than two days" in done.stderr
