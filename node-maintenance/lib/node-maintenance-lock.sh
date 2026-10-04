#!/usr/bin/env bash
# node-maintenance-lock.sh <skip|wait> -- <command> [args...]
#
# Serializes node-maintenance runs behind one flock (/run/node-maintenance.lock) so a
# drift-heal (config), a sync and a reboot (phase1/phase2) never run at once. Unlocked, the
# ~9-min heal could overlap itself (the 10-min sync re-triggers it) or run during the
# phase1→phase2 reboot window, so ansible runs raced on node config and the
# /etc/node-maintenance/ansible rsync (2026-05-25).
#
#   skip : if the lock is held, exit 0 WITHOUT running. For the frequent, idempotent heals
#          (config) — don't pile up; the next cycle / timer will catch up.
#   wait : block up to 15 min for the lock, then run. For the reboot (phase1/phase2), which must
#          run and must not be skipped — it waits out an in-progress heal instead.
#
# The lock lives in /run (tmpfs): flock auto-creates the file, and it's cleared each boot so a
# crash can never leave a stale lock across a reboot.
set -euo pipefail
LOCK=/run/node-maintenance.lock
mode="${1:?usage: node-maintenance-lock.sh <skip|wait> -- <cmd...>}"
shift
[ "${1:-}" = "--" ] && shift
[ "$#" -ge 1 ] || {
	echo "node-maintenance-lock.sh: no command given" >&2
	exit 2
}

case "$mode" in
skip)
	# -E 75: a distinct exit code when the lock is BUSY, so a caller can tell "lock held" apart from
	# the wrapped command's own failures (which must still propagate + alert).
	rc=0
	flock -n -E 75 "$LOCK" "$@" || rc=$?
	[ "$rc" = 75 ] && {
		echo "[node-maintenance-lock] another node-maintenance run holds the lock — skipping this run." >&2
		exit 0
	}
	exit "$rc"
	;;
wait)
	exec flock -w 900 "$LOCK" "$@"
	;;
*)
	echo "node-maintenance-lock.sh: mode must be 'skip' or 'wait' (got '$mode')" >&2
	exit 2
	;;
esac
