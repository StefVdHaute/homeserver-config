#!/usr/bin/env bash
# =============================================================
# Restic Backup Script
# Backs up Docker volumes + Seafile data to Raspberry Pi
# =============================================================

set -euo pipefail

# --- Config (sourced from environment or .env) ---
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:?Set RESTIC_REPOSITORY (e.g. sftp:pi@192.168.1.50:/backups/homeserver)}"
RESTIC_PASSWORD="${RESTIC_PASSWORD:?Set RESTIC_PASSWORD}"

DOCKER_VOLUMES="/mnt/data/docker/volumes"
SEAFILE_DATA="/mnt/data/seafile"
LOCAL_BACKUP_STAGING="/mnt/data/backups"

LOG_FILE="/var/log/restic-backup.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# --- Pre-flight ---
log "Starting backup..."

# Initialize repo if it doesn't exist yet
restic snapshots > /dev/null 2>&1 || {
  log "Initializing Restic repository..."
  restic init
}

# --- Backup ---
log "Backing up Docker volumes..."
restic backup "$DOCKER_VOLUMES" \
  --tag docker-volumes \
  --exclude="*.tmp" \
  --exclude="*.log"

log "Backing up Seafile data..."
restic backup "$SEAFILE_DATA" \
  --tag seafile-data

# --- Prune old snapshots ---
log "Pruning old snapshots..."
restic forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 6 \
  --prune

# --- Verify ---
log "Verifying repository integrity..."
restic check

log "Backup complete."
