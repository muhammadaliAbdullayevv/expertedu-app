#!/usr/bin/env bash
# Copies the server's encrypted daily backups -- and the photos -- to this laptop.
# Nothing is ever deleted from the server by this; the laptop keeps the last $KEEP backups.
# Run by the systemd user timer (see ops/README-backups.md) or by hand.
set -uo pipefail

HOST=${HOST:-administrator@108.181.203.226}
PORT=${PORT:-10054}
KEY=${KEY:-$HOME/.ssh/databasemart}
DEST=${DEST:-$HOME/ExpertEdu-backups}
KEEP=${KEEP:-60}
REMOTE_BACKUPS=${REMOTE_BACKUPS:-/opt/expertedu/backups/daily/}
REMOTE_PHOTOS=${REMOTE_PHOTOS:-/opt/expertedu/backend/photos/}

ssh_cmd="ssh -p $PORT -i $KEY -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new"
mkdir -p "$DEST/daily" "$DEST/photos"
chmod 700 "$DEST"

notify() { command -v notify-send >/dev/null && notify-send "Expert Edu backup" "$1" || true; }

if ! rsync -a --partial -e "$ssh_cmd" "$HOST:$REMOTE_BACKUPS" "$DEST/daily/"; then
  echo "$(date '+%F %T') could not pull the backups" >&2
  notify "Could not copy the server backups (is the server reachable?)"
  exit 1
fi
rsync -a --partial -e "$ssh_cmd" "$HOST:$REMOTE_PHOTOS" "$DEST/photos/" || echo "$(date '+%F %T') photos not copied" >&2

ls -1t "$DEST"/daily/expertedu-*.tar.gz.enc 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
newest=$(ls -1t "$DEST"/daily/expertedu-*.tar.gz.enc 2>/dev/null | head -1)
if [ -z "$newest" ]; then
  echo "$(date '+%F %T') no backup on the server yet" >&2
  notify "No backup found on the server yet."
  exit 1
fi
# A backup older than two days means the server's job has stopped.
if [ -z "$(find "$newest" -mtime -2 2>/dev/null)" ]; then
  echo "$(date '+%F %T') the newest backup is older than two days: $newest" >&2
  notify "The newest server backup is more than two days old!"
  exit 1
fi
echo "$(date '+%F %T') pulled; newest: $(basename "$newest")"
