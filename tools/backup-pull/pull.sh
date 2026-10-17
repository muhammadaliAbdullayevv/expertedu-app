#!/usr/bin/env bash
# Copies the server's nightly database backups to this PC, so they survive
# losing the server. Run daily by expertedu-backup-pull.timer (see
# install.sh); safe to run by hand. Keeps the last 30 days locally.
#
# Settings (environment, all optional):
#   EXPERTEDU_BACKUP_DIR  where to keep them   (default ~/ExpertEduBackups)
#   EXPERTEDU_SSH_KEY     key for the VPS      (default ~/.ssh/databasemart)
set -euo pipefail

dest="${EXPERTEDU_BACKUP_DIR:-$HOME/ExpertEduBackups}"
key="${EXPERTEDU_SSH_KEY:-$HOME/.ssh/databasemart}"
remote="administrator@108.181.203.226:/opt/expertedu/backups/"
mkdir -p "$dest"

# Only finished daily dumps (not *.part), never deleting anything here.
rsync -a --include='daily-*.dump' --exclude='*' \
  -e "ssh -p 10054 -i $key -o BatchMode=yes -o ConnectTimeout=20" \
  "$remote" "$dest/"

find "$dest" -maxdepth 1 -name 'daily-*.dump' -mtime +30 -delete
latest="$(ls -1 "$dest"/daily-*.dump 2>/dev/null | tail -1)"
echo "$(date -Is) ok, latest: ${latest:-none}"
