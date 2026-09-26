#!/usr/bin/env bash
# telegram-notify.sh — CLI wrapper used by systemd ExecStopPost on phase failure.
# Reads token + chat-id from /etc/node-maintenance/, POSTs to Telegram Bot API.
# Usage: telegram-notify.sh "message text"
set -euo pipefail

MESSAGE="${1:-}"
[ -n "$MESSAGE" ] || { echo "Usage: $0 <message>" >&2; exit 1; }

TOKEN_FILE="/etc/node-maintenance/telegram-token"
CHAT_FILE="/etc/node-maintenance/telegram-chat-id"
[ -r "$TOKEN_FILE" ] || { echo "Missing $TOKEN_FILE" >&2; exit 1; }
[ -r "$CHAT_FILE" ]  || { echo "Missing $CHAT_FILE"  >&2; exit 1; }

TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
CHAT_ID="$(tr -d '[:space:]' < "$CHAT_FILE")"

curl -fsS --max-time 10 \
  -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg c "$CHAT_ID" --arg t "$MESSAGE" \
            '{chat_id: $c, text: $t}')" \
  > /dev/null || echo "Telegram notify failed (ignored)" >&2
