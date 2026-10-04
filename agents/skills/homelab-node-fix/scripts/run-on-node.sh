#!/usr/bin/env bash
# Run a local script on a remote homelab node via scp + ssh -t + cleanup.
# User enters sudo password live in their terminal; output flows back here.
#
# Usage:
#   run-on-node.sh <ssh-alias> <local-script.sh> [args...]
#
# Examples:
#   run-on-node.sh ssh_master_node ./fix-pacman.sh
#   run-on-node.sh ssh_worker_node2 ./debug-nic.sh eth0
#
# Aliases (resolved by _shared/ssh-alias-resolve.sh):
#   ssh_master_node   -> akhozya@gmk-k3s-control-plane:65300
#   ssh_worker_node   -> akhozya@worker-node:65300
#   ssh_worker_node2  -> z3us@worker-node-2:65300
#   immich-vm         -> akhozya@immich-vm:65300
#
# Lints the script with shellcheck before transfer.
# Removes the remote copy on exit.

set -euo pipefail

ALIAS="${1:-}"
SCRIPT="${2:-}"
if [ -z "$ALIAS" ] || [ -z "$SCRIPT" ]; then
  cat >&2 <<EOF
usage: $0 <ssh-alias> <local-script.sh> [args...]
known aliases: ssh_master_node, ssh_worker_node, ssh_worker_node2
EOF
  exit 2
fi
shift 2

if [ ! -f "$SCRIPT" ]; then
  echo "local script not found: $SCRIPT" >&2
  exit 3
fi

if command -v shellcheck >/dev/null 2>&1; then
  if ! shellcheck "$SCRIPT"; then
    echo "shellcheck failed for $SCRIPT — abort before transfer" >&2
    exit 4
  fi
else
  echo "[WARN] shellcheck not installed; skipping pre-flight lint" >&2
fi

# Resolve alias -> ssh args (zsh alias not accessible from bash)
# shellcheck source=../../_shared/ssh-alias-resolve.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_shared" && pwd)/ssh-alias-resolve.sh"
SSH_USER_HOST="$(resolve_alias "$ALIAS")" || exit 2

# Real remote mktemp — /tmp/$NAME-$$ is predictable.
REMOTE="$(ssh -p "$SSH_NODE_PORT" "$SSH_USER_HOST" 'mktemp /tmp/run-on-node.XXXXXX')"
[ -n "$REMOTE" ] || {
  echo "could not create remote tempfile on $SSH_USER_HOST" >&2
  exit 5
}

cleanup() {
  ssh -p "$SSH_NODE_PORT" "$SSH_USER_HOST" "rm -f '$REMOTE'" 2>/dev/null || true
}
trap cleanup EXIT

echo "[scp] $SCRIPT -> $SSH_USER_HOST:$REMOTE"
scp -P "$SSH_NODE_PORT" -q "$SCRIPT" "${SSH_USER_HOST}:${REMOTE}"

# %q-quote each arg: a bare $* re-splits on spaces and breaks on quotes remote-side.
args=""
for a in "$@"; do args+=" $(printf '%q' "$a")"; done
echo "[ssh -t] $SSH_USER_HOST :: bash $REMOTE$args"
# -t: sudo needs a TTY for its password prompt.
ssh -p "$SSH_NODE_PORT" -t "$SSH_USER_HOST" "bash '$REMOTE'$args"
