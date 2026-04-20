#!/usr/bin/env bash
set -euo pipefail

REPORT_DIR="${REPORT_DIR:-$HOME/security-reports}"
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
REPORT_FILE="${REPORT_DIR}/security-check-${TIMESTAMP}.log"

mkdir -p "${REPORT_DIR}"
umask 077

{
  echo "=== Security Health Check ==="
  echo "Timestamp: $(date -Iseconds)"
  echo

  echo "[System]"
  uptime
  free -h
  df -h /
  echo

  echo "[Critical Services]"
  systemctl is-active ssh
  systemctl is-active ufw
  systemctl is-active fail2ban
  systemctl is-active k3s
  echo

  echo "[Firewall Rules]"
  ufw status verbose
  echo

  echo "[Fail2ban]"
  fail2ban-client status
  fail2ban-client status sshd
  echo

  echo "[Listening Sockets]"
  ss -tulpen
  echo

  echo "[Docker Exposed Ports]"
  docker ps --format '{{.Names}}\t{{.Ports}}\t{{.Status}}'
  echo

  echo "[Kubernetes Workloads]"
  kubectl get pods -A
  echo

  echo "[Kubernetes Ingress]"
  kubectl get ingress -A
  echo

  echo "[Unattended Upgrades]"
  systemctl is-enabled unattended-upgrades
  systemctl is-active unattended-upgrades
} > "${REPORT_FILE}" 2>&1

chmod 640 "${REPORT_FILE}"

echo "Security report written to ${REPORT_FILE}"
