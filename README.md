# vps-ops-toolkit

Public Linux VPS operations and maintenance scripts.

## Included Scripts

- `scripts/auto-update.sh`: package update and cleanup workflow
- `scripts/vps-maintenance.sh`: disk, Docker, Kubernetes, APT, and log maintenance
- `scripts/security-health-check.sh`: host and cluster security health snapshot
- `scripts/safe-reboot.sh`: guarded reboot flow with K3s drain logic
- `scripts/post-reboot-verify.sh`: post-boot verification and K3s recovery checks

## Included Systemd Units

- `systemd/auto-update.service`
- `systemd/auto-update.timer`
- `systemd/post-reboot-verify.service`

## Purpose

This repo contains generic Bash-based host administration examples for Linux VPS operations. Adjust paths, users, and service names to match your environment before using them in production.
