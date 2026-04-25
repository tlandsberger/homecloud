#!/bin/sh
set -e

export RESTIC_PASSWORD   # aus Portainer-Env gesetzt
FORGET_ARGS="--keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune"

echo "=== Backup gestartet: $(date) ==="

# 1. Lokal sichern
export RESTIC_REPOSITORY=/data/backup
restic backup /data/volumes \
  --exclude "/data/volumes/monitoring_loki_data" \
  --exclude "/data/volumes/monitoring_prometheus_data" \
  --exclude "/data/volumes/monitoring_alloy_data" \
  --exclude "/data/volumes/windows_windows_data" \
  --exclude "**/Plex Media Server/Cache" \
  --exclude "**/Plex Media Server/Codecs"
restic forget $FORGET_ARGS

# 2. Snapshot nach OneDrive kopieren (Daten nur einmal von Disk gelesen)
export RESTIC_REPOSITORY2="$RESTIC_REMOTE_REPOSITORY"
export RESTIC_PASSWORD2="$RESTIC_PASSWORD"
restic copy latest

# 3. Retention auch im Remote-Repo anwenden
RESTIC_REPOSITORY="$RESTIC_REMOTE_REPOSITORY" restic forget $FORGET_ARGS

echo "=== Backup abgeschlossen: $(date) ==="
