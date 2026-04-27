#!/usr/bin/env bash
# telegram-notify-claude.sh — Inject a prompt into the Claude Telegram bot
# via its in-pod HTTP trigger endpoint. Used by systemd ExecStopPost on
# successful weekly maintenance to kick off an autonomous Claude review run
# inside the user's normal Telegram DM with the bot.
#
# Reads shared secret from /etc/node-maintenance/claude-trigger-secret.
# Reaches the bot via `kubectl exec` (no Service / NetworkPolicy needed —
# trigger server is bound to the pod's loopback interface).
#
# Usage: telegram-notify-claude.sh "prompt text"
set -euo pipefail

PROMPT="${1:-}"
[ -n "$PROMPT" ] || { echo "Usage: $0 <prompt>" >&2; exit 1; }

SECRET_FILE="/etc/node-maintenance/claude-trigger-secret"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
NS="claude-telegram"
DEPLOY="claude-telegram"
CONTAINER="claude-telegram"
PORT="8080"

[ -r "$SECRET_FILE" ] || { echo "Missing $SECRET_FILE" >&2; exit 1; }
[ -r "$KUBECONFIG_PATH" ] || { echo "Missing $KUBECONFIG_PATH" >&2; exit 1; }
SECRET="$(tr -d '[:space:]' < "$SECRET_FILE")"

PAYLOAD="$(jq -n --arg p "$PROMPT" '{prompt: $p}')"

# `bun` ships curl-less images sometimes — fall back to wget if needed.
exec kubectl --kubeconfig="$KUBECONFIG_PATH" -n "$NS" exec \
  "deploy/${DEPLOY}" -c "$CONTAINER" -- \
  sh -c "
    if command -v curl >/dev/null 2>&1; then
      curl -fsS --max-time 10 \
        -X POST 'http://127.0.0.1:${PORT}/trigger' \
        -H 'X-Trigger-Secret: ${SECRET}' \
        -H 'Content-Type: application/json' \
        -d '${PAYLOAD}' >/dev/null
    else
      wget -q --timeout=10 -O- \
        --header='X-Trigger-Secret: ${SECRET}' \
        --header='Content-Type: application/json' \
        --post-data='${PAYLOAD}' \
        'http://127.0.0.1:${PORT}/trigger' >/dev/null
    fi
  " || echo "Claude trigger notify failed (ignored)" >&2
