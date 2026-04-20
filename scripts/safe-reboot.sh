#!/usr/bin/env bash
# Safe VPS Reboot Script
# Pre-checks services, drains K3s, logs state, reboots only when safe
# Post-reboot verification handled by post-reboot-verify.service (systemd oneshot)
set -euo pipefail

DRY_RUN=false
FORCE=false
LOG_DIR="/var/log/vps-maintenance"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/reboot_${TIMESTAMP}.log"
K3S_DRAIN_TIMEOUT=120
NODE_NAME="$(hostname)"

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --force) FORCE=true ;;
    -h|--help)
      echo "Usage: safe-reboot.sh [--dry-run] [--force]"
      echo "  --dry-run  Preview all checks without rebooting"
      echo "  --force    Reboot even if no reboot-required flag"
      exit 0
      ;;
  esac
done

mkdir -p "$LOG_DIR"

log() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "$msg" | tee -a "$LOG_FILE"
}

log_section() {
  log ""
  log "=== $1 ==="
}

# ─── Check if reboot is needed ──────────────────────────────────────
log_section "REBOOT REQUIRED CHECK"
if [ ! -f /var/run/reboot-required ] && [ "$FORCE" = false ]; then
  log "[OK] No reboot required. Use --force to override."
  exit 0
fi

if [ -f /var/run/reboot-required ]; then
  log "[INFO] Reboot required:"
  cat /var/run/reboot-required.pkgs 2>/dev/null | tee -a "$LOG_FILE" || true
else
  log "[INFO] Forced reboot requested (no pending kernel updates)"
fi

# ─── Check for active K3s rollouts ──────────────────────────────────
log_section "K3S ROLLOUT CHECK"
if command -v kubectl &>/dev/null; then
  rollouts_in_progress=0
  while IFS= read -r deploy; do
    ns=$(echo "$deploy" | awk '{print $1}')
    name=$(echo "$deploy" | awk '{print $2}')
    # Check if ready replicas != desired replicas
    ready=$(kubectl get deploy -n "$ns" "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    desired=$(kubectl get deploy -n "$ns" "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    ready=${ready:-0}
    if [ "$ready" != "$desired" ]; then
      log "[WARN] Deployment $ns/$name mid-rollout (ready=$ready, desired=$desired)"
      rollouts_in_progress=$((rollouts_in_progress + 1))
    fi
  done < <(kubectl get deploy -A --no-headers 2>/dev/null | awk '{print $1, $2}')

  if [ "$rollouts_in_progress" -gt 0 ] && [ "$FORCE" = false ]; then
    log "[ABORT] $rollouts_in_progress deployment(s) mid-rollout. Use --force to override."
    exit 1
  fi
else
  log "[SKIP] kubectl not available"
fi

# ─── Pre-reboot health snapshot ─────────────────────────────────────
log_section "PRE-REBOOT HEALTH SNAPSHOT"

# System info
log "Kernel: $(uname -r)"
log "Uptime: $(uptime -p)"
log "Load: $(cat /proc/loadavg)"

# Disk
df -h --output=pcent,target -x tmpfs -x devtmpfs -x overlay -x nsfs 2>/dev/null | tail -n +2 | while IFS= read -r line; do
  log "Disk: $line"
done

# Services
for svc in k3s docker fail2ban ufw tailscaled; do
  status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
  log "Service $svc: $status"
done

# K3s pods
if command -v kubectl &>/dev/null; then
  log "K3s pods:"
  kubectl get pods -A --no-headers 2>/dev/null | tee -a "$LOG_FILE" || true
fi

# Tailscale
if command -v tailscale &>/dev/null; then
  log "Tailscale: $(tailscale status --self 2>/dev/null | head -1 || echo 'unknown')"
fi

# ─── Drain K3s node ─────────────────────────────────────────────────
log_section "K3S NODE DRAIN"
if command -v kubectl &>/dev/null; then
  if $DRY_RUN; then
    log "[DRY-RUN] Would drain node: $NODE_NAME"
  else
    log "Cordoning node $NODE_NAME..."
    kubectl cordon "$NODE_NAME" 2>&1 | tee -a "$LOG_FILE" || true

    log "Draining node (timeout=${K3S_DRAIN_TIMEOUT}s)..."
    kubectl drain "$NODE_NAME" \
      --ignore-daemonsets \
      --delete-emptydir-data \
      --force \
      --timeout="${K3S_DRAIN_TIMEOUT}s" 2>&1 | tee -a "$LOG_FILE" || {
        log "[WARN] Drain did not complete cleanly, proceeding anyway"
      }
  fi
else
  log "[SKIP] kubectl not available"
fi

# ─── Execute reboot ─────────────────────────────────────────────────
log_section "REBOOT"
if $DRY_RUN; then
  log "[DRY-RUN] Would reboot now"
  log "[DRY-RUN] Post-reboot verification would run via post-reboot-verify.service"
  # Uncordon since we're not actually rebooting
  if command -v kubectl &>/dev/null; then
    log "[DRY-RUN] Would uncordon node after reboot"
  fi
  log "Dry run complete. Log: $LOG_FILE"
  exit 0
fi

log "Initiating reboot in 10 seconds..."
log "Post-reboot verification will run via systemd oneshot"
sync
sleep 10
/sbin/reboot
