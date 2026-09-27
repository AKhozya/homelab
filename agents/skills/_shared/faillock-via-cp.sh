#!/usr/bin/env bash
# Reset pam_faillock counter for a user on a homelab worker, bypassing the
# locked-out user's own sudo. Uses CP-hosted ansible with node-maintenance
# NOPASSWD sudo on workers.
#
# Usage: faillock-via-cp.sh <node> [<user>]
#   <node> = worker-node | worker-node-2
#   <user> = akhozya (default) | z3us
#
# Requires: user enters CP sudo password ONCE (akhozya@CP — separate faillock
# from worker, unaffected by worker lock).
#
# Why this works:
#   - faillock state is per-host (`/run/faillock/<user>` local file)
#   - CP sudo unaffected by worker lockout
#   - ansible uses /var/lib/node-maintenance/.ssh/id_ed25519 (root reads via sudo)
#   - node-maintenance user has NOPASSWD sudo on workers (ansible role setup)

set -euo pipefail

NODE="${1:-}"
USER_="${2:-akhozya}"
if [ -z "$NODE" ]; then
  cat >&2 <<EOF
usage: $0 <worker-node|worker-node-2> [<user>]
EOF
  exit 2
fi

case "$NODE" in
worker-node | worker-node-2) ;;
*)
  echo "unsupported node: $NODE (use worker-node or worker-node-2)" >&2
  exit 2
  ;;
esac

# Whitelist the user like the node: $USER_ is interpolated into the remote ansible -a
# argument — reject anything but the two real accounts.
case "$USER_" in
akhozya | z3us) ;;
*)
  echo "unsupported user: $USER_ (use akhozya or z3us)" >&2
  exit 2
  ;;
esac

# shellcheck source=./ssh-alias-resolve.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ssh-alias-resolve.sh"
echo "[ssh -t] akhozya@CP :: sudo ansible $NODE faillock reset for $USER_"
exec ssh -p "$SSH_NODE_PORT" -t "$(resolve_alias cp)" \
  "sudo ansible $NODE -i /etc/node-maintenance/ansible/inventory.yml -m shell -a 'faillock --user $USER_ --reset && faillock --user $USER_' --become"
