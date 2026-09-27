#!/usr/bin/env bash
# stage-k3s.sh — stage a new k3s binary on all 4 homelab nodes WITHOUT restarting k3s.
# Running services keep the old in-memory binary; the new version activates on the next
# k3s/k3s-agent restart (sanctioned: node-maintenance-rolling-restart.service) or reboot.
#
# Usage:
#   stage-k3s.sh --dry-run            # download + checksum only, no node changes
#   K3S_VERSION=v1.36.1+k3s1 stage-k3s.sh
#
# Sudo: fetched once from 1Password (op://Personal/sudo-homelab/password), piped to sudo -S
# stdin — never argv/env/history. Single attempt per node (pam_faillock deny=3 — NEVER retry).
# Validated end-to-end 2026-06-05 (v1.35.3 -> v1.36.1).
set -euo pipefail

K3S_VERSION="${K3S_VERSION:?set K3S_VERSION, e.g. v1.36.1+k3s1 (channels: curl -s https://update.k3s.io/v1-release/channels | jq '.data[] | {id, latest}')}"
OP_SUDO_PATH="${OP_SUDO_PATH:-op://Personal/sudo-homelab/password}"
# shellcheck source=../../_shared/ssh-alias-resolve.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_shared" && pwd)/ssh-alias-resolve.sh"
# immich-vm included: rolling-restart-k3s.yml targets hosts:workers (immich-vm in that group),
# so a stage that skips it activates into version skew on the 4th node.
NODES=("$(resolve_alias gmk-k3s-control-plane)" "$(resolve_alias worker-node)" "$(resolve_alias worker-node-2)" "$(resolve_alias immich-vm)")
SSH_PORT="$SSH_NODE_PORT"
# Strict argv: an unrecognized flag (e.g. --dryrun typo) must NOT fall through to the
# real staging run (op fetch + sudo on all 4 nodes).
DRY_RUN="${1:-}"
case "$DRY_RUN" in "" | --dry-run) ;; *)
  echo "usage: [K3S_VERSION=vX.Y.Z+k3s1] stage-k3s.sh [--dry-run]" >&2
  exit 2
  ;;
esac

url_ver="${K3S_VERSION/+/%2B}" # URL-encode the + in the tag
BIN_URL="https://github.com/k3s-io/k3s/releases/download/${url_ver}/k3s"
SUM_URL="https://github.com/k3s-io/k3s/releases/download/${url_ver}/sha256sum-amd64.txt"

echo "== k3s binary stage: ${K3S_VERSION} =="
workdir="$(mktemp -d /tmp/k3s-upgrade.XXXXXX)"
trap 'rm -rf "$workdir"' EXIT

echo "-- downloading binary + checksums --"
curl -fsSL -o "$workdir/k3s" "$BIN_URL"
curl -fsSL -o "$workdir/sums.txt" "$SUM_URL"
expected="$(awk '$2 == "k3s" {print $1}' "$workdir/sums.txt")"
actual="$(shasum -a 256 "$workdir/k3s" | awk '{print $1}')"
if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
  echo "CHECKSUM MISMATCH: expected=$expected actual=$actual" >&2
  exit 1
fi
echo "   checksum OK: $actual"

if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "DRY-RUN: would stage to ${NODES[*]} (scp + sudo install -m755 to /usr/local/bin/k3s)"
  exit 0
fi

echo "-- fetching sudo password from 1Password --"
sudo_pw="$(op read "$OP_SUDO_PATH")"
if [ -z "$sudo_pw" ]; then
  echo "ABORT: op read returned empty (dismissed popup?) — no sudo attempted." >&2
  exit 1
fi

for node in "${NODES[@]}"; do
  echo "-- staging on $node --"
  scp -P "$SSH_PORT" -q "$workdir/k3s" "$node:/tmp/k3s-${K3S_VERSION}"
  # Single sudo attempt: install new binary alongside backup of the old one.
  printf '%s\n' "$sudo_pw" | ssh -p "$SSH_PORT" "$node" "sudo -S -p '' bash -c '
    set -euo pipefail
    cp -f /usr/local/bin/k3s /usr/local/bin/k3s.prev
    install -m755 /tmp/k3s-${K3S_VERSION} /usr/local/bin/k3s
    rm -f /tmp/k3s-${K3S_VERSION}
    echo \"   staged: \$(/usr/local/bin/k3s --version | awk \"NR==1\")\"
    echo \"   backup: /usr/local/bin/k3s.prev (\$(/usr/local/bin/k3s.prev --version | awk \"NR==1\"))\"
  '" || {
    echo "SUDO-OR-STAGE FAILED on $node — STOP, do not retry (faillock deny=3)." >&2
    exit 1
  }
done

echo "== all nodes staged. Running services still on old binary until restart. =="
echo "Next (activation): op-sudo on CP -> systemctl start node-maintenance-rolling-restart.service (see SKILL.md step 5)"
