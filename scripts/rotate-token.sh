#!/usr/bin/env bash
# Copy a rotated token from a 1Password item's `credential` field into the homelab SOPS files.
# Never prints a value.
#   cf  -> cert-manager secret (Cloudflare dns_and_certs token)
#   tg  -> every SOPS secret whose Telegram token belongs to the same bot (same id before ':')
# Usage: scripts/rotate-token.sh cf|tg "<1Password item>" [--dry-run], run from a worktree:
# it edits the checkout it lives in. Procedure: docs/SECRETS_ROTATION.md.
# The value is checked with its issuer before any write. Values reach curl and sops on stdin or
# in a mode-600 temp file, never in argv, because argv shows in the process list; jq's stderr is
# dropped wherever its input holds a secret, because a jq error can quote the value.
# Edits land in staged copies first and then by rename, so no file is half-written. If a run
# stops between two renames, re-run it: targets that already hold the value are skipped.
# `git checkout -- <file>` undoes an edit; nothing reaches the cluster until it is merged.
set +x # a caller's `bash -x` would print every value
set -euo pipefail
umask 077
kind=${1:-}
item=${2:-}
dry=${3:-}
case "$kind:$dry" in cf: | cf:--dry-run | tg: | tg:--dry-run) ;; *) item= ;; esac
[ -n "$item" ] || {
  echo 'usage: rotate-token.sh cf|tg "<1Password item>" [--dry-run]' >&2
  exit 2
}
# A separate assignment, so set -e stops here: `cd "$(failing)"` runs `cd ""`, which succeeds.
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd -- "$root"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
op item get "$item" --vault Personal --fields credential --reveal </dev/null >"$tmp/raw" 2>/dev/null ||
  fail "cannot read the credential field of 1Password item '$item'"
v=$(<"$tmp/raw") # drops only the trailing newline op adds; the shape checks reject other whitespace
printf '%s' "$v" >"$tmp/v"

# get writes the decrypted value to $3: a file keeps a trailing newline that $(...) would drop,
# so cmp compares exact bytes.
get() { sops -d --extract "[\"stringData\"][\"$2\"]" "$1" >"$3" 2>/dev/null || fail "cannot decrypt $1 $2"; }
mkdir "$tmp/stage"
staged=()
put() {
  local c="$tmp/stage/${1//\//_}"
  if [ ! -f "$c" ]; then
    cp "$1" "$c"
    staged+=("$1")
  fi
  jq -Rs . "$tmp/v" | sops set --value-stdin "$c" "[\"stringData\"][\"$2\"]" 2>/dev/null ||
    fail "sops could not set $1 $2; no file was changed"
  get "$c" "$2" "$tmp/got"
  cmp -s "$tmp/got" "$tmp/v" || fail "$1 $2 did not read back; no file was changed"
}
publish() {
  local f
  for f in "${staged[@]}"; do
    cp "$tmp/stage/${f//\//_}" "$f.rotate-new"
    mv -f "$f.rotate-new" "$f"
    echo "updated $f"
  done
}

if [ "$kind" = cf ]; then
  [[ $v =~ ^[A-Za-z0-9_-]{40,}$ ]] || fail "'$item' credential does not look like a Cloudflare token"
  printf 'Authorization: Bearer %s\n' "$v" >"$tmp/h"
  # -q first: skip ~/.curlrc, which could turn on verbose output or a trace file
  curl -q -s -H @"$tmp/h" https://api.cloudflare.com/client/v4/user/tokens/verify >"$tmp/r"
  jq -e '.success == true and .result.status == "active"' "$tmp/r" >/dev/null 2>&1 ||
    fail "Cloudflare does not report the token as active"
  echo "Cloudflare: token active"
  pairs=(infrastructure/controllers/cert-manager/cloudflare-secret.yaml:api-token)
  id=
else
  [[ $v =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] || fail "'$item' credential does not look like a Telegram bot token"
  id=${v%%:*}
  printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$v" | curl -q -s --config - >"$tmp/r"
  jq -e --arg id "$id" '.ok == true and (.result.id | tostring) == $id' "$tmp/r" >/dev/null 2>&1 ||
    fail "Telegram does not accept the token"
  bot=$(jq -r '.result.username' "$tmp/r")
  echo "Telegram: token works for @$bot"
  pairs=(
    monitoring/configs/kube-prometheus-stack/alertmanager-telegram-secret.yaml:bot_token
    monitoring/configs/kube-prometheus-stack/alertmanager-telegram-secret.yaml:token
    infrastructure/configs/backup-replication/backup-telegram-secret.yaml:bot_token
    apps/pricebuddy/telegram-secret.yaml:bot_token
    apps/claude-telegram/claude-telegram-env-secret.yaml:telegram-bot-token
  )
fi

matched=0
for pair in "${pairs[@]}"; do
  f=${pair%%:*} k=${pair#*:}
  get "$f" "$k" "$tmp/old"
  # read returns 1 at a final line with no newline (the sops output) but still fills the variable.
  IFS= read -r first <"$tmp/old" || [ -n "${first:-}" ] || first=
  [ -z "$id" ] || [ "${first%%:*}" = "$id" ] || continue
  matched=$((matched + 1))
  if cmp -s "$tmp/old" "$tmp/v"; then
    echo "already current: $f $k"
  elif [ "$dry" = --dry-run ]; then
    echo "would update $f $k"
  else
    put "$f" "$k"
  fi
done
[ "$matched" -gt 0 ] || fail "no SOPS secret holds a token for this bot"
if [ "$dry" = --dry-run ]; then
  echo "dry run: nothing written"
else
  publish
  echo "done. Next: tell Claude to commit and merge."
fi
