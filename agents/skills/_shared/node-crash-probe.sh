#!/usr/bin/env bash
# Host-side crash forensics on a homelab node.
# Checks: pstore (kernel panic blobs), the kernel log (journalctl -k) for OOM/panic/kill,
# and the previous boot's error log.
#
# Usage: node-crash-probe.sh <ssh-alias>
# Aliases: ssh_master_node, ssh_worker_node, ssh_worker_node2
#
# Read-only — no sudo needed: kernel log comes from journalctl -k (works via the
# systemd-journal group); raw dmesg is BLOCKED for unprivileged users on these nodes
# (kernel.dmesg_restrict=1 — a bare `dmesg | grep` silently prints nothing and reads
# as "no crashes", verified 2026-07-04).

set -euo pipefail
# shellcheck source=./ssh-alias-resolve.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ssh-alias-resolve.sh"
ALIAS="${1:-}"
if [ -z "$ALIAS" ]; then
  echo "usage: $0 <ssh_master_node|ssh_worker_node|ssh_worker_node2>" >&2
  exit 2
fi
UH="$(resolve_alias "$ALIAS")" || exit 2

ssh -p "$SSH_NODE_PORT" "$UH" 'bash -s' <<'EOF'
set -u
echo "=== pstore (kernel panic blobs) ==="
ls -la /sys/fs/pstore/ 2>/dev/null || echo "(empty or unreadable)"

echo
echo "=== kernel log (journalctl -k): OOM / panic / kill (last 50 lines) ==="
out="$(journalctl -k --no-pager 2>/dev/null | grep -iE 'oom|panic|kill|hung|tainted' | tail -50)"
if [ -n "$out" ]; then
  printf '%s\n' "$out"
else
  echo "(none in current boot — note: raw dmesg is restricted here, journalctl -k is the source)"
fi

echo
echo "=== previous boot's error log ==="
journalctl --boot=-1 -p err --no-pager 2>/dev/null | tail -30 || echo "(no previous boot log)"

echo
echo "=== current boot uptime / load ==="
uptime
EOF
