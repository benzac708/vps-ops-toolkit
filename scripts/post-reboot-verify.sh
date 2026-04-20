#!/usr/bin/env bash
# Post-reboot verification script
# Runs as systemd oneshot after boot to verify all services recovered
set -euo pipefail

LOG_DIR="/var/log/vps-maintenance"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/post-reboot_${TIMESTAMP}.log"
K3S_TIMEOUT=180  # seconds to wait for K3s pods
CHECK_INTERVAL=10
NODE_NAME="$(hostname)"

mkdir -p "$LOG_DIR"

log() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "$msg" | tee -a "$LOG_FILE"
}

log_section() {
  log ""
  log "=== $1 ==="
}

FAILURES=0

check_service() {
  local svc="$1"
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    log "[OK] $svc is active"
  else
    log "[FAIL] $svc is not active"
    FAILURES=$((FAILURES + 1))
  fi
}

log_section "POST-REBOOT VERIFICATION"
log "Kernel: $(uname -r)"
log "Boot time: $(who -b | awk '{print $3, $4}')"

# ─── Core services ──────────────────────────────────────────────────
log_section "SERVICE CHECKS"
check_service docker
check_service k3s
check_service fail2ban
check_service ufw
check_service tailscaled

# ─── UFW status ─────────────────────────────────────────────────────
log_section "UFW STATUS"
if ufw status | grep -q "Status: active"; then
  log "[OK] UFW is active"
else
  log "[FAIL] UFW is not active"
  FAILURES=$((FAILURES + 1))
fi

# ─── Tailscale ──────────────────────────────────────────────────────
log_section "TAILSCALE CHECK"
if command -v tailscale &>/dev/null; then
  ts_status=$(tailscale status --self 2>/dev/null | head -1 || echo "unknown")
  log "Tailscale: $ts_status"
  if echo "$ts_status" | grep -q "$(hostname)"; then
    log "[OK] Tailscale connected"
  else
    log "[WARN] Tailscale may not be fully connected"
  fi
fi

# ─── Docker health ──────────────────────────────────────────────────
log_section "DOCKER CHECK"
if docker info &>/dev/null; then
  log "[OK] Docker daemon healthy"
else
  log "[FAIL] Docker daemon not responding"
  FAILURES=$((FAILURES + 1))
fi

# ─── K3s uncordon + pod health ──────────────────────────────────────
log_section "K3S RECOVERY"
if command -v kubectl &>/dev/null; then
  # Uncordon node
  log "Uncordoning node $NODE_NAME..."
  kubectl uncordon "$NODE_NAME" 2>&1 | tee -a "$LOG_FILE" || true

  # Wait for pods to become ready
  log "Waiting up to ${K3S_TIMEOUT}s for pods to stabilize..."
  elapsed=0
  while [ $elapsed -lt $K3S_TIMEOUT ]; do
    not_ready=$(kubectl get pods -A --no-headers 2>/dev/null | grep -cvE "Running|Completed|Succeeded" || echo "0")
    if [ "$not_ready" -eq 0 ]; then
      log "[OK] All pods are Running/Completed (after ${elapsed}s)"
      break
    fi
    log "[WAIT] $not_ready pod(s) not ready yet (${elapsed}s/${K3S_TIMEOUT}s)"
    sleep $CHECK_INTERVAL
    elapsed=$((elapsed + CHECK_INTERVAL))
  done

  if [ $elapsed -ge $K3S_TIMEOUT ]; then
    log "[WARN] Some pods still not ready after ${K3S_TIMEOUT}s:"
    kubectl get pods -A --no-headers 2>/dev/null | grep -vE "Running|Completed|Succeeded" | tee -a "$LOG_FILE" || true
    FAILURES=$((FAILURES + 1))
  fi

  # Show final pod state
  log "Final pod state:"
  kubectl get pods -A 2>&1 | tee -a "$LOG_FILE" || true
else
  log "[SKIP] kubectl not available"
fi

# ─── Disk check ─────────────────────────────────────────────────────
log_section "DISK CHECK"
df -h --output=pcent,target -x tmpfs -x devtmpfs -x overlay -x nsfs 2>/dev/null | tail -n +2 | while IFS= read -r line; do
  usage=$(echo "$line" | awk '{print $1}' | tr -d '%')
  mount=$(echo "$line" | awk '{print $2}')
  [[ "$usage" =~ ^[0-9]+$ ]] || continue
  if [ "$usage" -ge 90 ]; then
    log "[ALERT] Disk at ${usage}% on ${mount}"
  else
    log "[OK] Disk at ${usage}% on ${mount}"
  fi
done

# ─── Summary ────────────────────────────────────────────────────────
log_section "SUMMARY"
if [ $FAILURES -eq 0 ]; then
  log "[OK] All post-reboot checks passed"
else
  log "[ALERT] $FAILURES check(s) failed — review log: $LOG_FILE"
fi
