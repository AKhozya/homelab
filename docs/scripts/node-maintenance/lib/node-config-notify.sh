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

# Extract failure context: last failing TASK header + fatal/failed line + PLAY RECAP.
# Kept small (<600 chars) to fit Telegram message body comfortably.
extract_failure_tail() {
  local last_task last_fatal recap
  last_task=$(grep -nE '^TASK \[' "$LOG" | tail -1 | cut -d: -f1 || true)
  last_fatal=$(grep -nE '^(fatal|failed):' "$LOG" | tail -1 | cut -d: -f1 || true)
  recap=$(grep -nE '^PLAY RECAP' "$LOG" | tail -1 | cut -d: -f1 || true)

  if [ -n "${last_fatal:-}" ]; then
    # Print the failing TASK line, then fatal line (trimmed), then PLAY RECAP line if present.
    [ -n "${last_task:-}" ] && sed -n "${last_task}p" "$LOG"
    # Trim fatal line to 300 chars to avoid dumping full JSON blobs.
    sed -n "${last_fatal}p" "$LOG" | cut -c1-300
    [ -n "${recap:-}" ] && sed -n "${recap},$((recap + 3))p" "$LOG"
  else
    tail -n 15 "$LOG"
  fi
}

if [ "$RESULT" != "success" ] || [ "${FAILED:-0}" -gt 0 ]; then
  # Strip triple backticks to keep Markdown code block intact.
  TAIL=$(extract_failure_tail 2>/dev/null | tr -d '`' | head -c 600)
  /usr/local/sbin/telegram-notify.sh "$(printf '❌ node-config drift-heal FAILED (result=%s changed=%s failed=%s)\n\n```\n%s\n```' "$RESULT" "$CHANGED" "$FAILED" "$TAIL")"
elif [ "${CHANGED:-0}" -gt 0 ]; then
  /usr/local/sbin/telegram-notify.sh "⚙️ node-config drift-heal applied $CHANGED change(s). journalctl -u node-maintenance-config.service -n 80"
fi
