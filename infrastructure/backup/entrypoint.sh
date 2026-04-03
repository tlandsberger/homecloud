#!/bin/sh
set -e

# rclone-Config in den Default-Pfad schreiben (kein RCLONE_CONFIG nötig)
mkdir -p /root/.config/rclone
printf '%s' "$RCLONE_CONFIG_BASE64" | base64 -d > /root/.config/rclone/rclone.conf

# Repos idempotent initialisieren: restic cat config gibt 0 zurück wenn Repo existiert
echo "Prüfe lokales Repo..."
RESTIC_REPOSITORY=/data/backup restic cat config > /dev/null 2>&1 \
  || RESTIC_REPOSITORY=/data/backup restic init

echo "Prüfe OneDrive-Repo..."
RESTIC_REPOSITORY="$RESTIC_REMOTE_REPOSITORY" restic cat config > /dev/null 2>&1 \
  || RESTIC_REPOSITORY="$RESTIC_REMOTE_REPOSITORY" restic init

echo "$BACKUP_CRON /backup.sh >> /proc/1/fd/1 2>&1" > /etc/crontabs/root
echo "Backup scheduled: $BACKUP_CRON"
exec crond -f -l 8
