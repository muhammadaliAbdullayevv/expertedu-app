#!/usr/bin/env bash
# Nightly database backup on the VPS, run from the administrator crontab:
#   30 21 * * * /opt/expertedu/backend/ops/backup.sh >> /opt/expertedu/backups/backup.log 2>&1
# (21:30 UTC = 02:30 in Tashkent.) Keeps 14 days of daily-*.dump files;
# the pre-<migration>-*.dump files taken before deploys are never pruned.
# A PC copies the latest ones off the server: tools/backup-pull/.
set -euo pipefail

dir=/opt/expertedu/backups
set -a
. /etc/expertedu.env
set +a

stamp="$(TZ=Asia/Tashkent date +%Y%m%d_%H%M%S)"
target="$dir/daily-$stamp.dump"
# Written under a temporary name, so a half-written file is never taken
# for a backup (by the pull on the PC, or by someone restoring in a hurry).
pg_dump "$DATABASE_URL" -Fc -f "$target.part"
mv "$target.part" "$target"

find "$dir" -maxdepth 1 -name 'daily-*.dump' -mtime +14 -delete
echo "$(date -u +%FT%TZ) ok $(basename "$target") $(stat -c %s "$target") bytes"
