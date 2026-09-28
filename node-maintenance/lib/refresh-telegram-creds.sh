#!/usr/bin/env bash
# refresh-telegram-creds.sh — copy the Telegram bot token and chat ID from the
# backup-replication/backup-telegram Secret into /etc/node-maintenance/.
#
# install.sh runs it once, and sync-from-git.sh runs it on every sync, so a token rotated
# in SOPS reaches the CP files within one sync after Flux applies the Secret. The
# security_scan role copies these files from the CP to every node.
# One read of the Secret feeds both files, and neither file changes unless both values are
# non-empty, so a failed read never leaves a token from one rotation next to a chat ID from
# another. The script never prints either value.
set -euo pipefail

KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
DIR="/etc/node-maintenance"

tok_tmp=""
chat_tmp=""
trap 'rm -f "$tok_tmp" "$chat_tmp"' EXIT

secret="$(kubectl --kubeconfig="$KUBECONFIG_PATH" -n backup-replication get secret backup-telegram -o json)"
tok_tmp="$(mktemp "$DIR/telegram-token.XXXXXX")"
chat_tmp="$(mktemp "$DIR/telegram-chat-id.XXXXXX")"
jq -er '.data.bot_token' <<<"$secret" | base64 -d > "$tok_tmp"
jq -er '.data.chat_id' <<<"$secret" | base64 -d > "$chat_tmp"
[ -s "$tok_tmp" ] && [ -s "$chat_tmp" ] \
  || { echo "backup-telegram: bot_token or chat_id is empty" >&2; exit 1; }
chmod 0600 "$tok_tmp" "$chat_tmp"
mv -f "$tok_tmp" "$DIR/telegram-token"
tok_tmp=""
mv -f "$chat_tmp" "$DIR/telegram-chat-id"
chat_tmp=""
