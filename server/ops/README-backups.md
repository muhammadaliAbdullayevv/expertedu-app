# Backups

Every night at 03:00 the server (cron, `ops/backup.sh`) makes **one encrypted pack**: the database dump and the Telegram
bot's own file (`bot.sqlite3`: books, locations, cover). It

- keeps the last 14 on the server in `/opt/expertedu/backups/daily/`,
- sends it to the owner in the bot's chat on Telegram (files up to 50 MB; a bigger one is announced in a message),
- tells the owner in the bot's chat if anything failed ("❌ Backup failed: ...").

The laptop pulls them (`ops/pull-backups.sh`, run daily by a systemd user timer) into `~/ExpertEdu-backups/` together with
a copy of the photos, keeping the last 60 packs. It complains with a desktop notification if the newest pack is more than
two days old.

**The passphrase** is in `/etc/expertedu-backup.pass` on the server. Keep a copy in your password manager: without it the
packs cannot be opened, and the server's copy is lost with the server.

## Setting it up on the server (once)

```bash
sudo sh -c 'umask 077; openssl rand -base64 33 > /etc/expertedu-backup.pass; chown administrator /etc/expertedu-backup.pass'
cat /etc/expertedu-backup.pass          # copy this into your password manager NOW
mkdir -p /opt/expertedu/backups/daily
bash /opt/expertedu/backend/ops/backup.sh      # a first one, by hand: it should arrive in the bot's chat
(crontab -l 2>/dev/null | grep -v backup.sh; echo '0 3 * * * /opt/expertedu/backend/ops/backup.sh >> /opt/expertedu/backups/backup.log 2>&1') | crontab -
```

## On the laptop (once)

```bash
mkdir -p ~/.config/systemd/user
cp ~/Documents/expertedu-app/server/ops/systemd/expertedu-backup-pull.* ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now expertedu-backup-pull.timer
~/Documents/expertedu-app/server/ops/pull-backups.sh     # a first pull by hand
```

## Opening a backup

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass file:PASSFILE -in expertedu-DATE.tar.gz.enc | tar xz -C opened/
#   opened/expertedu.dump   the database      opened/bot.sqlite3   the bot's file
```
(from Telegram: download the file from the bot's chat and use the same command.)

## Restoring the database

Into an empty database, as the database owner:

```bash
createdb -O expertedu_app expertedu_restored
pg_restore --no-owner --role=expertedu_app -d expertedu_restored opened/expertedu.dump
```
Check it (`psql expertedu_restored -c 'select count(*) from students'`), then point the API's `DATABASE_URL` at it, or
restore over the live one with `pg_restore --clean --if-exists` when the service is stopped. Put `bot.sqlite3` back at
`/opt/expertedu-bot/bot.sqlite3` (bot stopped) to bring back the books and locations.

Try a restore into a scratch database once a month; a backup nobody has opened is a hope, not a backup.
