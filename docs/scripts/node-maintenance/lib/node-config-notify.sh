#!/usr/bin/env bash
# node-config-notify.sh — parses ansible playbook log + fires Telegram alert.
# Invoked by node-maintenance-config.service ExecStopPost.
# Alerts on: SERVICE_RESULT != success OR failed > 0 OR changed > 0.
# Silent when idempotent (changed=0, failed=0, success).
#
# Failure attribution: the controller is the CP node (ansible_connection: local).
# A worker-side failure is reported by ansible as `fatal: [<worker>]: ...`
# — but skim-readers may misread the alert as a CP failure because the alert
# fires from CP. The "Failed on:" line is therefore placed in the SUBJECT
# (first body line) so target nodes are unambiguous.
set -uo pipefail

LOG=/var/log/node-maintenance/config-latest.log
RESULT="${1:-unknown}"   # $SERVICE_RESULT passed from systemd

if [ ! -r "$LOG" ]; then
  /usr/local/sbin/telegram-notify.sh "❌ node-config drift-heal: log missing ($LOG). result=$RESULT"
  exit 0
fi

CHANGED=$(grep -oE 'changed=[0-9]+' "$LOG" | tail -3 | awk -F= '{s+=$2} END{print s+0}')
FAILED=$(grep -oE 'failed=[0-9]+' "$LOG" | tail -3 | awk -F= '{s+=$2} END{print s+0}')

# Pair the *correct* TASK header to the fatal line — the TASK on or before
# the fatal's line number, NOT the last TASK in the log. A naive `last TASK`
# pick can land on a later host-conditional task that the failing host
# skipped (e.g. rebuilderd W2-only orphan removal printed after a CP fatal).
extract_task_header() {
  local last_fatal task_line
  last_fatal=$1
  task_line=$(grep -nE '^TASK \[' "$LOG" | awk -F: -v f="$last_fatal" '$1<=f{l=$1} END{print l}')
  [ -n "${task_line:-}" ] && sed -n "${task_line}p" "$LOG"
}

# Pull msg / cmd / attempts from the fatal JSON instead of dumping raw JSON
# truncated mid-token. Falls back to raw 300-char trim if parse fails.
extract_fatal_summary() {
  local fatal_line
  fatal_line=$(sed -n "${1}p" "$LOG")
  local msg cmd attempts host
  host=$(printf '%s' "$fatal_line" | sed -nE 's/^(fatal|failed): \[([^]]+)\].*/\2/p')
  msg=$(printf '%s' "$fatal_line" | grep -oE '"msg": *"[^"]*"' | head -1 | sed -E 's/"msg": *"//; s/"$//')
  cmd=$(printf '%s' "$fatal_line" | grep -oE '"cmd": *"[^"]*"' | head -1 | sed -E 's/"cmd": *"//; s/"$//')
  [ -z "$cmd" ] && cmd=$(printf '%s' "$fatal_line" | grep -oE '"commands": *\[[^]]*\]' | head -1)
  attempts=$(printf '%s' "$fatal_line" | grep -oE '"attempts": *[0-9]+' | head -1)
  if [ -n "${msg:-}" ] || [ -n "${cmd:-}" ]; then
    [ -n "${host:-}" ]     && printf 'host: %s\n' "$host"
    [ -n "${attempts:-}" ] && printf '%s\n' "$attempts" | tr -d '"'
    [ -n "${cmd:-}" ]      && printf 'cmd: %s\n' "$cmd" | head -c 200
    [ -n "${msg:-}" ]      && printf '\nmsg: %s\n' "$msg" | head -c 300
  else
    printf '%s' "$fatal_line" | cut -c1-300
  fi
}

extract_recap() {
  local recap
  recap=$(grep -nE '^PLAY RECAP' "$LOG" | tail -1 | cut -d: -f1 || true)
  [ -n "${recap:-}" ] && sed -n "${recap},$((recap + 5))p" "$LOG"
}

# Distinct failing hosts from `fatal: [<host>]:` and `failed: [<host>]:` lines.
extract_failed_hosts() {
  grep -oE '^(fatal|failed): \[[^]]+\]' "$LOG" 2>/dev/null \
    | sed -E 's/^(fatal|failed): \[([^]]+)\]/\2/' \
    | sort -u \
    | paste -sd, -
}

# UTC ISO timestamps bracketing the fatal — for `journalctl --since/--until`.
extract_journal_window() {
  local fatal_line first_line last_ts first_ts
  fatal_line=$(grep -nE '^(fatal|failed):' "$LOG" | tail -1 | cut -d: -f1 || true)
  [ -z "${fatal_line:-}" ] && return 0
  first_ts=$(head -n 1 "$LOG" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+' | head -1)
  last_ts=$(date -u -Iseconds 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%S+0000")
  [ -n "${first_ts:-}" ] && printf 'window: %s..%s\n' "$first_ts" "$last_ts"
}

if [ "$RESULT" != "success" ] || [ "${FAILED:-0}" -gt 0 ]; then
  HOSTS=$(extract_failed_hosts)
  CTRL=$(hostname)
  HOSTS_LINE=""
  if [ -n "${HOSTS:-}" ]; then
    HOSTS_LINE="🎯 Failed on: ${HOSTS}  (controller: ${CTRL})"
  else
    HOSTS_LINE="🎯 Failed on: <unattributed>  (controller: ${CTRL})"
  fi

  LAST_FATAL=$(grep -nE '^(fatal|failed):' "$LOG" | tail -1 | cut -d: -f1 || true)
  TASK_HDR=""
  FATAL_SUM=""
  if [ -n "${LAST_FATAL:-}" ]; then
    TASK_HDR=$(extract_task_header "$LAST_FATAL" | tr -d '`' | head -c 200)
    FATAL_SUM=$(extract_fatal_summary "$LAST_FATAL" | tr -d '`' | head -c 500)
  fi
  RECAP=$(extract_recap | tr -d '`' | head -c 600)
  WIN=$(extract_journal_window | head -c 100)

  BODY=$(printf '%s\n%s\n\n%s\n%s\n\n%s\n\nDiag: journalctl -u node-maintenance-config.service --no-pager -n 200\nLive log: /var/log/node-maintenance/config-latest.log' \
    "${TASK_HDR:-(task header missing)}" \
    "${FATAL_SUM:-(fatal summary missing)}" \
    "${RECAP:-(recap missing)}" \
    "${WIN:-}" \
    "")

  /usr/local/sbin/telegram-notify.sh "$(printf '❌ node-config drift-heal FAILED (result=%s changed=%s failed=%s)\n%s\n\n```\n%s\n```' "$RESULT" "$CHANGED" "$FAILED" "$HOSTS_LINE" "$BODY")"
elif [ "${CHANGED:-0}" -gt 0 ]; then
  /usr/local/sbin/telegram-notify.sh "⚙️ node-config drift-heal applied $CHANGED change(s). journalctl -u node-maintenance-config.service -n 80"
fi
