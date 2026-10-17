#!/usr/bin/env bash
# Installs the daily backup copy for the current user (no root needed):
#   tools/backup-pull/install.sh
# Check it with:  systemctl --user list-timers expertedu-backup-pull.timer
#                 journalctl --user -u expertedu-backup-pull.service
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

install -Dm755 "$here/pull.sh" "$HOME/.local/bin/expertedu-backup-pull"
install -Dm644 "$here/expertedu-backup-pull.service" "$HOME/.config/systemd/user/expertedu-backup-pull.service"
install -Dm644 "$here/expertedu-backup-pull.timer" "$HOME/.config/systemd/user/expertedu-backup-pull.timer"
systemctl --user daemon-reload
systemctl --user enable --now expertedu-backup-pull.timer
# Run once now, so there's a copy straight away.
systemctl --user start expertedu-backup-pull.service
