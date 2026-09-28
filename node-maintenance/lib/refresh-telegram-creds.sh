#!/usr/bin/env bash
# refresh-telegram-creds.sh — copy the Telegram bot token and chat ID from the
# backup-replication/backup-telegram Secret into /etc/node-maintenance/.
#
# install.sh runs it once, and sync-from-git.sh runs it on every sync, so a token rotated
# in SOPS reaches the CP files within one sync after Flux applies the Secret. The
# security_scan role copies these files from the CP to every node.
# Each file is replaced only after a non-empty read, so a failed read keeps the old value.
# The values are never printed.
set -euo pipefail

KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
DIR="/etc/node-maintenance"

tmp=""
trap 'rm -f "$tmp"' EXIT

for pair in bot_token:telegram-token chat_id:telegram-chat-id; do
  key="${pair%%:*}"
  dest="$DIR/${pair#*:}"
  tmp="$(mktemp "$dest.XXXXXX")"
  kubectl --kubeconfig="$KUBECONFIG_PATH" -n backup-replication get secret backup-telegram \
    -o "jsonpath={.data.$key}" | base64 -d > "$tmp"
  [ -s "$tmp" ] || { echo "backup-telegram: key $key is empty or missing" >&2; exit 1; }
  chmod 0600 "$tmp"
  mv -f "$tmp" "$dest"
  tmp=""
done
