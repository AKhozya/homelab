# shellcheck shell=bash
# Shared helpers for the node-maintenance scripts, installed by base_config as
# /usr/local/lib/node-maintenance/node-script-lib.sh. Sourced, never run.
#
# Function definitions only. A caller sources this file inside an `if`, where errexit is off,
# so a failing top-level command here would go unnoticed (lib/tests/test-node-script-lib.sh
# fails the build if one appears).

# Reads stdin into a temp file beside PATH, sets MODE, then renames it over PATH. The temp
# name does not end in .prom, so node-exporter never reads a half-written file. If any step
# fails it reads the rest of stdin (so the writer upstream gets no SIGPIPE under pipefail),
# removes the temp file, leaves PATH as it was, and returns 1.
_nsl_atomic_write() { # PATH MODE
	local path=$1 mode=$2 tmp
	if ! tmp="$(mktemp "${path}.XXXXXX")"; then
		cat >/dev/null
		return 1
	fi
	if ! cat >"$tmp"; then
		cat >/dev/null
		rm -f "$tmp"
		return 1
	fi
	if ! chmod "$mode" "$tmp" || ! mv -f "$tmp" "$path"; then
		rm -f "$tmp"
		return 1
	fi
}

# A node-exporter textfile metric: mode 0644, because node-exporter scrapes as a non-root user.
# Returns 1 on failure; the heal watchdogs call it with `|| true` so a full disk never stops them.
textfile_write() { # PATH < metric text
	_nsl_atomic_write "$1" 0644
}

# A watchdog state file ("field field ..." on one line), mode 0600 as mktemp creates it.
# Returns 1 if the write fails. A watchdog saves its restart count before it acts and skips the
# action on 1, because a count it cannot save cannot enforce the restart cap.
state_write() { # PATH FIELD...
	local path=$1
	shift
	local IFS=' '
	printf '%s\n' "$*" | _nsl_atomic_write "$path" 0600
}

# sha256 of the ufw/ufw6 chain declarations and rules only. kube-router and kube-proxy rewrite
# the kube-* chains all the time, so a whole-ruleset hash never settles on a worker.
# The caller sets IPTABLES_SAVE and IP6TABLES_SAVE.
ufw_chains_hash() {
	: "${IPTABLES_SAVE:?set by the caller}" "${IP6TABLES_SAVE:?set by the caller}"
	{
		"$IPTABLES_SAVE" 2>/dev/null | grep -E '^:ufw-|^-A ufw-' || true
		"$IP6TABLES_SAVE" 2>/dev/null | grep -E '^:ufw6-|^-A ufw6-' || true
	} | sha256sum | awk '{print $1}'
}
