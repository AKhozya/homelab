#!/usr/bin/env bash
# sync-node-maintenance.sh — Mac-side on-demand trigger.
# Fires node-maintenance-sync.service on CP (same path the 10-min timer uses).
# All git auth lives on CP via /root/.ssh/homelab-deploy.
set -euo pipefail

CP_HOST="${NODE_MAINT_CP_HOST:-gmk-k3s-control-plane}"
CP_USER="${NODE_MAINT_CP_USER:-akhozya}"
CP_PORT="${NODE_MAINT_CP_PORT:-65300}"

echo "==> Trigger node-maintenance-sync.service on $CP_USER@$CP_HOST:$CP_PORT"

ssh -p "$CP_PORT" -t "$CP_USER@$CP_HOST" \
  "sudo systemctl start node-maintenance-sync.service && sudo journalctl -u node-maintenance-sync.service -n 30 --no-pager"

echo "==> Done"
