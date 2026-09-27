#!/usr/bin/env bash
# Force pacman mirror DB refresh on a homelab node before install.
# Mirror staleness causes 404 errors on -S installs (incident 2026-05-14).
#
# Usage: pacman-cache-refresh.sh <ssh-alias>
# Aliases: ssh_master_node, ssh_worker_node, ssh_worker_node2
#
# Sudo runs interactively (-t) so user enters password live.

set -euo pipefail
# shellcheck source=./ssh-alias-resolve.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ssh-alias-resolve.sh"
ALIAS="${1:-}"
if [ -z "$ALIAS" ]; then
  echo "usage: $0 <ssh_master_node|ssh_worker_node|ssh_worker_node2>" >&2
  exit 2
fi
UH="$(resolve_alias "$ALIAS")" || exit 2

echo "[ssh -t] $UH :: sudo pacman -Syy"
exec ssh -p "$SSH_NODE_PORT" -t "$UH" "sudo pacman -Syy"
