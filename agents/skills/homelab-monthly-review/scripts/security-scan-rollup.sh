#!/usr/bin/env bash
# security-scan-rollup.sh — monthly-review rollup of node security-scan logs (lynis+rkhunter).
# Replaces the inline 3-node loop that (a) had the worst quoting in the skill corpus,
# (b) required hand-editing a <prev> placeholder, (c) silently skipped immich-vm after
# its 2026-07-10 join (security_scan role runs hosts:all — 4 nodes have logs).
# Read-only, no sudo (logs root:adm 640, scan users in adm).
#
# Usage: security-scan-rollup.sh            # current month + prior month (.log.1)
set -euo pipefail

# shellcheck source=../../_shared/ssh-alias-resolve.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_shared" && pwd)/ssh-alias-resolve.sh"

cur="$(date -u +%Y-%m)"
prev="$(date -u -v-1m +%Y-%m 2>/dev/null || date -u -d '1 month ago' +%Y-%m)" # BSD then GNU

for node in gmk-k3s-control-plane worker-node worker-node-2 immich-vm; do
  uh="$(resolve_alias "$node")"
  # shellcheck disable=SC2029  # $cur/$prev expand client-side by design; $h/$f remote
  ssh -p "$SSH_NODE_PORT" -o ConnectTimeout=5 "$uh" '
    h=$(hostname)
    for f in security-scan-'"$cur"'.log security-scan-'"$prev"'.log.1; do
      p="/var/log/node-maintenance/$f"
      if [ ! -r "$p" ]; then echo "$h $f | MISSING"; continue; fi
      echo "$h $f | $(grep -oE "Suspect files: [0-9]+" "$p" | head -1) | $(grep -oE "Possible rootkits: [0-9]+" "$p" | head -1) | warnings=$(grep -c "^Warning:" "$p")"
    done' || echo "$node UNREACHABLE"
done
