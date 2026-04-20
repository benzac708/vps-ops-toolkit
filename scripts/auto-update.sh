#!/bin/bash
# Weekly system update with error handling and broken-dep detection
set -euo pipefail

LOGDIR="/var/log/updates"
DATE=$(date +%Y%m%d_%H%M%S)
LOGFILE="${LOGDIR}/update_${DATE}.log"
mkdir -p "$LOGDIR"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOGFILE"
}

export DEBIAN_FRONTEND=noninteractive

log "=== System Update Start ==="

# Step 1: Check for broken packages first
log "Checking for broken packages..."
if ! dpkg --audit >> "$LOGFILE" 2>&1; then
  log "[ERROR] Broken packages detected. Attempting fix..."
  apt --fix-broken install -y >> "$LOGFILE" 2>&1 || {
    log "[FATAL] Could not fix broken packages. Aborting upgrade."
    exit 1
  }
fi

# Step 2: Update package lists
log "Running apt update..."
if ! apt update >> "$LOGFILE" 2>&1; then
  log "[ERROR] apt update failed"
  exit 1
fi

# Step 3: Check if upgrade would succeed
log "Checking upgrade..."
if ! apt upgrade --dry-run >> "$LOGFILE" 2>&1; then
  log "[ERROR] apt upgrade dry-run failed — likely broken deps"
  apt --fix-broken install -y >> "$LOGFILE" 2>&1 || true
fi

# Step 4: Perform upgrade
log "Running apt upgrade..."
if apt upgrade -y >> "$LOGFILE" 2>&1; then
  log "[OK] Upgrade completed successfully"
else
  log "[ERROR] apt upgrade failed with exit code $?"
fi

# Step 5: Autoremove if possible
apt autoremove -y >> "$LOGFILE" 2>&1 || true

# Step 6: Check reboot required
if [ -f /var/run/reboot-required ]; then
  log "[INFO] Reboot required after update"
fi

log "=== System Update Complete ==="

# Cleanup old logs
find "$LOGDIR" -type f -mtime +30 -delete 2>/dev/null || true
