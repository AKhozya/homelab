#!/usr/bin/env bash
# telegram-notify.sh — CLI wrapper used by systemd ExecStopPost on phase failure.
# Reads token + chat-id from /etc/node-maintenance/, POSTs to Telegram Bot API.
# Usage: telegram-notify.sh "message text"
#
# Every caller discards this script's exit code (`|| true`, `failed_when: false`), so a
# failed send reports itself: an err-priority journal line and the gauge
# node_maintenance_telegram_notify_success 0 in the node-exporter textfile directory.
set -euo pipefail

MESSAGE="${1:-}"
[ -n "$MESSAGE" ] || { echo "Usage: $0 <message>" >&2; exit 1; }

TOKEN_FILE="/etc/node-maintenance/telegram-token"
CHAT_FILE="/etc/node-maintenance/telegram-chat-id"
METRIC_DIR="/var/lib/node_exporter/textfile"

write_metric() {
  [ -d "$METRIC_DIR" ] || return 0
  {
    echo '# HELP node_maintenance_telegram_notify_success 1 if the last Telegram notify on this node was delivered.'
    echo '# TYPE node_maintenance_telegram_notify_success gauge'
    echo "node_maintenance_telegram_notify_success $1"
    echo '# HELP node_maintenance_telegram_notify_last_attempt_timestamp_seconds Unix time of the last Telegram notify attempt.'
    echo '# TYPE node_maintenance_telegram_notify_last_attempt_timestamp_seconds gauge'
    echo "node_maintenance_telegram_notify_last_attempt_timestamp_seconds $(date +%s)"
  } > "$METRIC_DIR/telegram_notify.prom.tmp" \
    && chmod 0644 "$METRIC_DIR/telegram_notify.prom.tmp" \
    && mv -f "$METRIC_DIR/telegram_notify.prom.tmp" "$METRIC_DIR/telegram_notify.prom" \
    || true
}

fail() {
  logger -p user.err -t telegram-notify "Telegram notify FAILED: $1" 2>/dev/null || true
  echo "Telegram notify FAILED: $1" >&2
  write_metric 0
  exit 1
}

[ -r "$TOKEN_FILE" ] || fail "missing $TOKEN_FILE"
[ -r "$CHAT_FILE" ]  || fail "missing $CHAT_FILE"

TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")" || fail "cannot read $TOKEN_FILE"
CHAT_ID="$(tr -d '[:space:]' < "$CHAT_FILE")" || fail "cannot read $CHAT_FILE"
[ -n "$TOKEN" ] && [ -n "$CHAT_ID" ] || fail "empty token or chat-id file"

BODY="$(jq -n --arg c "$CHAT_ID" --arg t "$MESSAGE" '{chat_id: $c, text: $t}')" \
  || fail "jq could not build the payload"

# The URL carries the token, so it goes in through --config on a pipe: any local user can
# read a process's argv. printf is a shell builtin, so the token reaches no argv here either.
curl -fsS --max-time 10 \
  --config <(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TOKEN") \
  -H "Content-Type: application/json" \
  --data-binary @- <<< "$BODY" > /dev/null \
  || fail "curl exit $? (bad token, network or Telegram API)"

write_metric 1
