#!/usr/bin/env bash
# telegram-notify-claude.sh — inject a prompt into the Claude Telegram bot through its
# in-pod HTTP trigger endpoint. node-maintenance-phase2.service ExecStopPost runs this
# after a successful weekly run, so Claude reviews the post-reboot alerts in the
# operator's normal Telegram DM.
#
# The secret comes from the bot's own environment inside the pod. The CP keeps no copy.
# Two copies went out of step once: the rotation on 2026-07-31 updated SOPS, and
# /etc/node-maintenance/claude-trigger-secret kept its 2026-04-27 value. The bot then
# answered 403, `|| true` in the caller discarded that, and two weekly runs got no alert
# review before anyone noticed on 2026-08-08. Reading the pod's variable grants nothing
# new — whoever can `kubectl exec` into that container can already read it.
#
# Usage: telegram-notify-claude.sh "prompt text"
set -euo pipefail

PROMPT="${1:-}"
[ -n "$PROMPT" ] || { echo "Usage: $0 <prompt>" >&2; exit 1; }

KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
NS="claude-telegram"
DEPLOY="claude-telegram"
CONTAINER="claude-telegram"
PORT="8080"

# The caller is `ExecStopPost=... || true`, which discards a non-zero exit. If this script
# does not alert, nothing does.
fail() {
  echo "Claude trigger notify FAILED: $1" >&2
  /usr/local/sbin/telegram-notify.sh \
    "⚠️ Claude trigger FAILED ($1) — the post-maintenance alert review did NOT run." || true
  exit 1
}

[ -r "$KUBECONFIG_PATH" ] || fail "missing $KUBECONFIG_PATH"

PAYLOAD="$(jq -n --arg p "$PROMPT" '{prompt: $p}')" || fail "jq could not build the payload"

# `--data-binary @-` reads the body from stdin, which keeps the prompt out of the
# container's argv. Not `-d @-` — that one strips newlines from the JSON.
# curl ships in the bot image; the deployment's readinessProbe execs it against /healthz.
printf '%s' "$PAYLOAD" | kubectl --kubeconfig="$KUBECONFIG_PATH" -n "$NS" exec -i \
  "deploy/${DEPLOY}" -c "$CONTAINER" -- \
  sh -c "curl -fsS --max-time 10 \
    -X POST 'http://127.0.0.1:${PORT}/trigger' \
    -H \"X-Trigger-Secret: \$TRIGGER_SECRET\" \
    -H 'Content-Type: application/json' \
    --data-binary @- >/dev/null" \
  || fail "POST /trigger rejected or unreachable"

echo "Claude trigger accepted"
