#!/usr/bin/env bash
# VPS Maintenance Script
# Handles cleanup, health checks, and maintenance tasks not covered by apt/unattended-upgrades
# Run weekly via cron or manually with --dry-run to preview actions
set -euo pipefail

DRY_RUN=false
LOG_DIR="/var/log/vps-maintenance"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/maintenance_${TIMESTAMP}.log"
DISK_WARN_PERCENT=80
DOCKER_PRUNE_HOURS=168  # 7 days in hours
LOG_RETENTION_DAYS=30
CUSTOM_LOG_RETENTION_DAYS=30

# Parse args
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      echo "Usage: vps-maintenance.sh [--dry-run]"
      echo "  --dry-run  Preview actions without executing"
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

run_or_preview() {
  if $DRY_RUN; then
    log "[DRY-RUN] Would run: $*"
  else
    log "[RUN] $*"
    eval "$@" 2>&1 | tee -a "$LOG_FILE" || log "[WARN] Command failed: $*"
  fi
}

# ─── Disk Usage Check ────────────────────────────────────────────────
log_section "DISK USAGE CHECK"
while IFS= read -r line; do
  # df --output=pcent,target format: "  41% /"
  usage=$(echo "$line" | awk '{print $1}' | tr -d '%')
  mount=$(echo "$line" | awk '{print $2}')
  [ -z "$usage" ] || [ -z "$mount" ] && continue
  [[ "$usage" =~ ^[0-9]+$ ]] || continue
  if [ "$usage" -ge "$DISK_WARN_PERCENT" ]; then
    log "[ALERT] Disk usage at ${usage}% on ${mount}"
  else
    log "[OK] Disk usage at ${usage}% on ${mount}"
  fi
done < <(df -h --output=pcent,target -x tmpfs -x devtmpfs -x overlay -x nsfs 2>/dev/null | tail -n +2)

# ─── Docker Cleanup ──────────────────────────────────────────────────
log_section "DOCKER CLEANUP"
if command -v docker &>/dev/null; then
  # Show what would be pruned
  dangling=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l)
  log "Dangling images: ${dangling}"

  unused=$(docker images --format '{{.ID}} {{.CreatedSince}}' 2>/dev/null | grep -c "weeks\|months\|years" || echo 0)
  log "Images older than a week: ${unused}"

  # Prune dangling images and build cache
  run_or_preview "docker image prune -f --filter 'until=${DOCKER_PRUNE_HOURS}h'"

  # Prune stopped containers older than 7 days
  run_or_preview "docker container prune -f --filter 'until=${DOCKER_PRUNE_HOURS}h'"

  # Prune unused volumes (only truly orphaned)
  run_or_preview "docker volume prune -f"

  # Show disk usage after
  log "Docker disk usage:"
  docker system df 2>&1 | tee -a "$LOG_FILE"
else
  log "[SKIP] Docker not installed"
fi

# ─── K3s Cleanup ─────────────────────────────────────────────────────
log_section "K3S CLEANUP"
if command -v kubectl &>/dev/null; then
  # Clean up completed/failed pods across all namespaces
  completed=$(sudo kubectl get pods -A --field-selector=status.phase==Succeeded -o name 2>/dev/null | wc -l)
  failed=$(sudo kubectl get pods -A --field-selector=status.phase==Failed -o name 2>/dev/null | wc -l)
  log "Completed pods: ${completed}, Failed pods: ${failed}"

  if [ "$completed" -gt 0 ] || [ "$failed" -gt 0 ]; then
    for ns in $(sudo kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      run_or_preview "sudo kubectl delete pods -n $ns --field-selector=status.phase==Succeeded 2>/dev/null || true"
      run_or_preview "sudo kubectl delete pods -n $ns --field-selector=status.phase==Failed 2>/dev/null || true"
    done
  fi

  # Check for old replicasets with 0 replicas
  old_rs=$(sudo kubectl get rs -A -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
count = 0
for item in data.get('items', []):
    if item.get('status', {}).get('replicas', 0) == 0:
        count += 1
print(count)
" 2>/dev/null || echo 0)
  log "Empty replicasets: ${old_rs}"
else
  log "[SKIP] kubectl not available"
fi

# ─── Log Rotation for Custom Logs ────────────────────────────────────
log_section "CUSTOM LOG CLEANUP"
for dir in /var/log/updates /var/log/security /var/log/vps-maintenance /home/ubuntu/security-reports; do
  if [ -d "$dir" ]; then
    old_count=$(find "$dir" -type f -mtime +${CUSTOM_LOG_RETENTION_DAYS} 2>/dev/null | wc -l)
    log "Old files (>${CUSTOM_LOG_RETENTION_DAYS}d) in ${dir}: ${old_count}"
    if [ "$old_count" -gt 0 ]; then
      run_or_preview "find $dir -type f -mtime +${CUSTOM_LOG_RETENTION_DAYS} -delete"
    fi
  fi
done

# ─── Reboot Required Check ──────────────────────────────────────────
log_section "REBOOT CHECK"
if [ -f /var/run/reboot-required ]; then
  log "[ALERT] System reboot required (kernel update pending)"
  if [ -f /var/run/reboot-required.pkgs ]; then
    log "Packages requiring reboot:"
    cat /var/run/reboot-required.pkgs | tee -a "$LOG_FILE"
  fi
else
  log "[OK] No reboot required"
fi

# ─── APT Health Check ───────────────────────────────────────────────
log_section "APT HEALTH CHECK"
# Check for broken packages
broken=$(dpkg --audit 2>&1)
if [ -n "$broken" ]; then
  log "[ALERT] Broken packages detected:"
  echo "$broken" | tee -a "$LOG_FILE"
else
  log "[OK] No broken packages"
fi

# Check how many packages are upgradable
upgradable=$(apt list --upgradable 2>/dev/null | grep -c "upgradable" || echo 0)
log "Packages awaiting upgrade: ${upgradable}"

# Check for autoremovable packages
autoremove=$(apt list --installed 2>/dev/null | wc -l)
autoremove_count=$(sudo apt autoremove --dry-run 2>/dev/null | grep -c "^Remv " || echo 0)
if [ "$autoremove_count" -gt 0 ]; then
  log "[INFO] ${autoremove_count} packages can be autoremoved"
  run_or_preview "sudo apt autoremove -y"
fi

# ─── Tool Version Check ─────────────────────────────────────────────
log_section "TOOL VERSIONS"
declare -A tools=(
  [gh]="$(gh --version 2>/dev/null | head -1 || echo 'not installed')"
  [docker]="$(docker --version 2>/dev/null || echo 'not installed')"
  [helm]="$(helm version --short 2>/dev/null || echo 'not installed')"
  [k3s]="$(k3s --version 2>/dev/null | head -1 || echo 'not installed')"
  [bun]="$(bun --version 2>/dev/null || echo 'not installed')"
  [node]="$(node --version 2>/dev/null || echo 'not installed')"
  [terraform]="$(terraform --version 2>/dev/null | head -1 || echo 'not installed')"
  [git]="$(git --version 2>/dev/null || echo 'not installed')"
)
for tool in "${!tools[@]}"; do
  log "  ${tool}: ${tools[$tool]}"
done

# ─── Summary ─────────────────────────────────────────────────────────
log_section "MAINTENANCE COMPLETE"
log "Dry run: ${DRY_RUN}"
log "Log saved to: ${LOG_FILE}"

# Cleanup old maintenance logs
find "$LOG_DIR" -type f -mtime +${LOG_RETENTION_DAYS} -delete 2>/dev/null || true
