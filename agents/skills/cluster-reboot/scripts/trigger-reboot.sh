#!/usr/bin/env bash
# trigger-reboot.sh [--dry-run] — start the sanctioned node-maintenance phase1→phase2 rolling
# reboot, fetching the shared homelab sudo password from 1Password (op) and injecting it to
# `sudo -S` over SSH. This is the ONE privileged step the cluster-reboot skill otherwise leaves
# to the operator; with the op item in place it becomes hands-off.
#
# Safety (read before editing):
#   - FAILLOCK-SAFE: fetches the secret FIRST and aborts BEFORE any sudo if `op read` is empty
#     (a dismissed 1Password popup → empty → would otherwise feed sudo an empty password and burn
#     a faillock attempt). pam_faillock deny=3 → 3 failed sudos = 10-min lockout. This makes a
#     SINGLE attempt and NEVER auto-retries. Pre-verify op independently: `op read "$OP_SUDO_PATH" >/dev/null && echo OK`.
#   - IDLE GUARD: refuses to reboot through a running drift-heal/sync or an already-in-flight run
#     (phase2-pending), and aborts if the CP can't be reached to verify that state.
#   - NO SECRET LEAK: the password travels op → shell var → ssh stdin (heredoc) → `sudo -S`.
#     Never in argv, env, or shell history.
#   - Requires the op CLI to be unlocked — approve the 1Password (Touch ID) popup the first time
#     per session; it's cached for a window afterwards.
# After triggering, monitor with watch-reboot.sh (same dir).
#
# Overridable env: CP_HOST (default gmk-k3s-control-plane, an ~/.ssh/config Host),
#                  OP_SUDO_PATH (default op://Personal/sudo-homelab/password).
set -euo pipefail
CP_HOST="${CP_HOST:-gmk-k3s-control-plane}"
OP_SUDO_PATH="${OP_SUDO_PATH:-op://Personal/sudo-homelab/password}"
dry=0
[ "${1:-}" = "--dry-run" ] && dry=1

# 1) Fetch the secret first — empty ⇒ abort before sudo (faillock-safe).
pw="$(op read "$OP_SUDO_PATH" 2>/dev/null)" || true
[ -n "$pw" ] || {
  echo "ABORT: op read '$OP_SUDO_PATH' returned empty — approve the 1Password popup / unlock op CLI. sudo NOT touched." >&2
  exit 1
}

# 2) Idle guard — never reboot through a running sync/heal or an in-flight run.
state="$(ssh -o ConnectTimeout=6 "$CP_HOST" 'systemctl is-active node-maintenance-phase1.service node-maintenance-phase2.service node-maintenance-config.service node-maintenance-sync.service 2>/dev/null | paste -sd, -' 2>/dev/null || echo unknown)"
# `[ -x dir ]` proves the human account can traverse the state dir — at HOME 0750 it can't, so a
# bare `[ -e flag ]` false-negatives to "absent" and would ALLOW a reboot through a stuck flag
# (2026-06-20). No flag + not-traversable → "unknown" → the absent-guard below ABORTS (fail-safe).
pend="$(ssh -o ConnectTimeout=6 "$CP_HOST" 'd=/var/lib/node-maintenance; if [ -e "$d/phase2-pending" ]; then echo SET; elif [ -x "$d" ]; then echo absent; else echo unknown; fi' 2>/dev/null || echo unknown)"
echo "CP=$CP_HOST  maintenance=[$state]  phase2-pending=$pend"
[ "$state" = unknown ] && {
  echo "ABORT: cannot reach $CP_HOST to verify maintenance state." >&2
  exit 1
}
case "$state" in *activating*)
  echo "ABORT: a node-maintenance run is active (phase1/phase2/sync/heal) — wait for an idle window." >&2
  exit 1
  ;;
esac
[ "$pend" = absent ] || {
  echo "ABORT: phase2-pending=$pend (a maintenance run is already in flight)." >&2
  exit 1
}

# 3) Trigger — single attempt. --no-block so the SSH returns instead of hanging when the CP reboots.
if [ "$dry" = 1 ]; then
  echo "[dry-run] op read OK + window idle — WOULD run:"
  echo "  ssh $CP_HOST 'sudo -S systemctl start --no-block node-maintenance-phase1.service'  (password via stdin)"
  exit 0
fi
# shellcheck disable=SC2087  # $pw MUST expand client-side — it's the LOCAL secret fed to the remote
# `sudo -S` over stdin; quoting EOF would send the literal string "$pw" instead of the password.
out="$(
  ssh -o ConnectTimeout=8 "$CP_HOST" 'sudo -S -p "" systemctl start --no-block node-maintenance-phase1.service && echo PHASE1-TRIGGERED-OK || echo SUDO-FAILED' <<EOF
$pw
EOF
)" || true
unset pw
echo "$out"
case "$out" in
*PHASE1-TRIGGERED-OK*) echo "Triggered. Monitor with: $(dirname "$0")/watch-reboot.sh" ;;
*)
  echo "ABORT: phase1 trigger FAILED (sudo rejected or ssh died) — NOT triggered. Do not retry blindly (faillock deny=3)." >&2
  exit 1
  ;;
esac
