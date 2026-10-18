#!/usr/bin/env bash
# The daily backup of the Expert Edu center, run on the server by cron.
#
#   1. dumps the database (pg_dump -Fc) and the bot's own file (books, locations, cover);
#   2. packs them and ENCRYPTS the pack (AES-256, passphrase in $PASS_FILE) -- a database
#      of students, phone numbers and payments never leaves the server unencrypted;
#   3. keeps the last $KEEP packs in $BACKUP_DIR (the laptop pulls them, see pull-backups.sh);
#   4. sends the encrypted pack to the owner in the bot's chat on Telegram (a bot may send
#      files up to 50 MB; a bigger one is announced in a message instead).
# Any failure sends a message saying which step failed and exits non-zero.
#
# Restoring: docs in ops/README-backups.md.
set -uo pipefail

BACKUP_DIR=${BACKUP_DIR:-/opt/expertedu/backups/daily}
KEEP=${KEEP:-14}
APP_ENV=${APP_ENV:-/etc/expertedu.env}
BOT_ENV=${BOT_ENV:-/etc/expertedu-bot.env}
PASS_FILE=${PASS_FILE:-/etc/expertedu-backup.pass}
BOT_DB=${BOT_DB:-/opt/expertedu-bot/bot.sqlite3}
TG_API=${TG_API:-https://api.telegram.org}
SEND_TELEGRAM=${SEND_TELEGRAM:-1}
MAX_TELEGRAM_BYTES=${MAX_TELEGRAM_BYTES:-49000000}

stamp=${STAMP:-$(date +%Y%m%d_%H%M%S)}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- Telegram (the token and the owner's id come from the bot's env file; never printed) ----------------
env_value() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-; }
TOKEN=$(env_value "$BOT_ENV" BOT_TOKEN)
CHAT=${BACKUP_CHAT_ID:-$(env_value "$BOT_ENV" OWNER_IDS | cut -d, -f1 | tr -d ' ')}

tg_text() {
  [ "$SEND_TELEGRAM" = 1 ] && [ -n "$TOKEN" ] && [ -n "$CHAT" ] || return 0
  curl -fsS --max-time 60 -o /dev/null "$TG_API/bot$TOKEN/sendMessage" --data-urlencode "chat_id=$CHAT" --data-urlencode "text=$1" \
    || echo "could not send the Telegram message" >&2
}
tg_file() {
  [ "$SEND_TELEGRAM" = 1 ] && [ -n "$TOKEN" ] && [ -n "$CHAT" ] || return 0
  curl -fsS --max-time 300 -o /dev/null "$TG_API/bot$TOKEN/sendDocument" -F "chat_id=$CHAT" -F "caption=$2" -F "document=@$1" \
    || { echo "could not send the file to Telegram" >&2; return 1; }
}
fail() {
  echo "$(date '+%F %T') BACKUP FAILED: $1" >&2
  tg_text "❌ Backup failed on $(hostname): $1"
  exit 1
}

# --- 1. dump ----------------------------------------------------------------------------------------------
[ -s "$PASS_FILE" ] || fail "no passphrase file ($PASS_FILE): refusing to make an unencrypted backup"
DB=$(env_value "$APP_ENV" DATABASE_URL)
[ -n "$DB" ] || fail "DATABASE_URL not found in $APP_ENV"
pack="$work/pack"
mkdir -p "$pack"
pg_dump -Fc "$DB" -f "$pack/expertedu.dump" 2>"$work/pg_dump.err" || fail "pg_dump: $(head -c 200 "$work/pg_dump.err" | tr '\n' ' ')"
[ -s "$pack/expertedu.dump" ] || fail "the database dump is empty"
if [ -f "$BOT_DB" ]; then
  python3 - "$BOT_DB" "$pack/bot.sqlite3" <<'PY' || fail "copying the bot's file"
import sqlite3, sys
src = sqlite3.connect(sys.argv[1]); dst = sqlite3.connect(sys.argv[2])
src.backup(dst); dst.close(); src.close()
PY
fi

# --- 2. pack and encrypt ---------------------------------------------------------------------------------
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
plain="$work/expertedu-$stamp.tar.gz"
tar czf "$plain" -C "$pack" . || fail "packing"
out="$BACKUP_DIR/expertedu-$stamp.tar.gz.enc"
openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass "file:$PASS_FILE" -in "$plain" -out "$out.part" || fail "encrypting"
# Prove it can be opened before trusting it.
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "file:$PASS_FILE" -in "$out.part" | tar tzf - >/dev/null 2>&1 \
  || { rm -f "$out.part"; fail "the encrypted backup does not open again"; }
mv "$out.part" "$out"
chmod 600 "$out"
size=$(stat -c %s "$out")

# --- 3. rotate -----------------------------------------------------------------------------------------------
ls -1t "$BACKUP_DIR"/expertedu-*.tar.gz.enc 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

# --- 4. Telegram ---------------------------------------------------------------------------------------------
human=$(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "$size bytes")
if [ "$size" -le "$MAX_TELEGRAM_BYTES" ]; then
  tg_file "$out" "💾 Backup $(date '+%F %H:%M') · $human · encrypted (AES-256)" || tg_text "⚠️ Backup saved on the server ($human) but could not be sent here."
else
  tg_text "💾 Backup $(date '+%F %H:%M') saved on the server and pulled by the laptop ($human) -- too big for Telegram (limit 50 MB)."
fi
echo "$(date '+%F %T') backup ok: $(basename "$out") $human"
