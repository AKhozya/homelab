#!/usr/bin/env bash
# node-config-notify.sh — parses ansible playbook log + fires Telegram alert.
# Invoked by node-maintenance-config.service ExecStopPost.
# Alerts on: SERVICE_RESULT != success OR failed > 0 OR changed > 0.
# Silent when idempotent (changed=0, failed=0, success).
set -uo pipefail

LOG=/var/log/node-maintenance/config-latest.log
RESULT="${1:-unknown}"   # $SERVICE_RESULT passed from systemd

if [ ! -r "$LOG" ]; then
  /usr/local/sbin/telegram-notify.sh "❌ node-config drift-heal: log missing ($LOG). result=$RESULT"
  exit 0
fi

CHANGED=$(grep -oE 'changed=[0-9]+' "$LOG" | tail -3 | awk -F= '{s+=$2} END{print s+0}')
FAILED=$(grep -oE 'failed=[0-9]+' "$LOG" | tail -3 | awk -F= '{s+=$2} END{print s+0}')

if [ "$RESULT" != "success" ] || [ "${FAILED:-0}" -gt 0 ]; then
  /usr/local/sbin/telegram-notify.sh "❌ node-config drift-heal FAILED (result=$RESULT changed=$CHANGED failed=$FAILED). journalctl -u node-maintenance-config.service -n 80"
elif [ "${CHANGED:-0}" -gt 0 ]; then
  /usr/local/sbin/telegram-notify.sh "⚙️ node-config drift-heal applied $CHANGED change(s). journalctl -u node-maintenance-config.service -n 80"
fi
