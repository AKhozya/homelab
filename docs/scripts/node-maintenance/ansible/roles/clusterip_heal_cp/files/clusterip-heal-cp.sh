#!/usr/bin/env bash
# clusterip-heal-cp.sh — CONTROL-PLANE self-heal for the post-reboot kube-proxy ClusterIP DNAT wedge.
#
# CP counterpart of clusterip-heal.sh (workers). The CP runs k3s.service (not k3s-agent) and its
# host-netns ClusterIP probe false-reads wedged, so this uses the POD-NETNS probe
# (clusterip-probe-cp.sh) and restarts k3s. The old "restart-k3s-on-CP hangs" caveat was DISPROVEN
# 2026-06-29 (a manual `systemctl restart k3s` returned cleanly in ~30-60s and reprogrammed the DNAT);
# the restart is nonetheless `timeout`-guarded here so a future hang can NEVER wedge the control plane
# indefinitely — it converts to a give-up + alert instead.
#
# Same guard model as the worker heal: act only when POSITIVELY wedged, with a cooldown between
# restarts and a max-per-window cap; past the cap, back off and emit a give-up metric (alert) — a
# persistent wedge is a deeper fault, and storming `restart k3s` on the CP is worse than surfacing it.

set -euo pipefail

PROBE="/usr/local/sbin/clusterip-probe-cp.sh"
STATE="/var/lib/node-maintenance/clusterip-heal-cp.state" # "window_start count total last_restart"
METRIC_DIR="/var/lib/node_exporter/textfile"
METRIC="${METRIC_DIR}/clusterip_heal_cp.prom"

COOLDOWN=300        # min seconds between restarts (let the last one settle)
WINDOW=1800         # cap window (s)
MAX_RESTARTS=3      # max restarts within WINDOW before giving up + alerting
RESTART_TIMEOUT=120 # hard cap on `systemctl restart k3s` (gate: clean restart ~30-60s)
REPROBE_WAIT=30     # k3s + kube-proxy take longer than k3s-agent to come up + reprogram

log() {
	logger -t clusterip-heal-cp -- "$*" 2>/dev/null || true
	echo "clusterip-heal-cp: $*"
}

emit_metric() { # $1 wedged(0/1)  $2 restarts-total  $3 giveup(0/1)
	[ -d "$METRIC_DIR" ] || return 0
	local tmp
	tmp="$(mktemp "${METRIC}.XXXXXX")" || return 0
	if {
		printf '# HELP node_clusterip_heal_wedged ClusterIP DNAT wedge detected (1=wedged).\n'
		printf '# TYPE node_clusterip_heal_wedged gauge\n'
		printf 'node_clusterip_heal_wedged %s\n' "$1"
		printf '# HELP node_clusterip_heal_restarts_total k3s restarts issued by the heal watchdog.\n'
		printf '# TYPE node_clusterip_heal_restarts_total counter\n'
		printf 'node_clusterip_heal_restarts_total %s\n' "$2"
		printf '# HELP node_clusterip_heal_giveup Wedge persisted past MAX_RESTARTS (1=needs a human).\n'
		printf '# TYPE node_clusterip_heal_giveup gauge\n'
		printf 'node_clusterip_heal_giveup %s\n' "$3"
	} >"$tmp"; then
		# 0644 so a non-root node_exporter can scrape it (mktemp made it 0600). Without this the
		# wedged/giveup metrics never reach Prometheus → the give-up alert is silent.
		chmod 0644 "$tmp"
		mv -f "$tmp" "$METRIC" || rm -f "$tmp"
	else
		rm -f "$tmp"
	fi
}

write_state() { # $1 win  $2 count  $3 total  $4 last
	local tmp
	tmp="$(mktemp "${STATE}.XXXXXX")" || return 0
	if printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >"$tmp"; then
		mv -f "$tmp" "$STATE" || rm -f "$tmp"
	else
		rm -f "$tmp"
	fi
}

# k3s.service must exist + be active. This also makes the script a safe no-op off the CP (no k3s.service).
if ! systemctl is-active --quiet k3s.service; then
	log "k3s.service not active here — nothing to heal (no-op off the CP)."
	exit 0
fi

if [ ! -x "$PROBE" ]; then
	log "probe $PROBE missing/not executable — cannot verify; skipping."
	exit 0
fi

win=0 count=0 total=0 last=0
if [ -r "$STATE" ]; then
	read -r win count total last <"$STATE" 2>/dev/null || true
	win="${win:-0}" count="${count:-0}" total="${total:-0}" last="${last:-0}"
fi
now="$(date +%s)"

# Three-state probe contract: 0=healthy, 1=confirmed wedged, 2=unknown (could not probe).
prc=0
"$PROBE" >/dev/null 2>&1 || prc=$?
if [ "$prc" -eq 0 ]; then
	# Confirmed healthy → clear the wedge metric.
	emit_metric 0 "$total" 0
	exit 0
fi
if [ "$prc" -ne 1 ]; then
	# UNKNOWN (or any non-{0,1}) → could not confirm a wedge → do NOTHING: no restart, and do NOT
	# touch metrics (preserve any prior wedged/give-up so a real alert is not silently cleared).
	log "pod-netns probe returned UNKNOWN (rc=$prc) — skipping (no restart, metrics preserved)."
	exit 0
fi

log "ClusterIP DNAT WEDGED on $(hostname) (pod-netns probe)."

# Roll the cap window if it has elapsed.
if [ "$((now - win))" -gt "$WINDOW" ]; then
	win="$now"
	count=0
fi

# Cap reached → give up, alert via metric, do NOT restart again.
if [ "$count" -ge "$MAX_RESTARTS" ]; then
	log "still wedged after ${count} k3s restart(s) in $((WINDOW / 60))min — giving up, NOT restarting. Deeper fault than the iptables-restore wedge; investigate."
	write_state "$win" "$count" "$total" "$last"
	emit_metric 1 "$total" 1
	exit 1
fi

# Cooldown → wait one cycle so the previous restart can settle.
if [ "$last" -ne 0 ] && [ "$((now - last))" -lt "$COOLDOWN" ]; then
	log "within ${COOLDOWN}s cooldown ($((now - last))s since last restart) — waiting a cycle."
	emit_metric 1 "$total" 0
	exit 1
fi

# Heal: timeout-guarded `systemctl restart k3s` to rebuild kube-proxy chains from a clean slate.
log "restarting k3s (timeout ${RESTART_TIMEOUT}s) to rebuild kube-proxy chains."
rc=0
timeout "$RESTART_TIMEOUT" systemctl restart k3s.service || rc=$?

if [ "$rc" -eq 0 ]; then
	count="$((count + 1))"
	total="$((total + 1))"
	last="$(date +%s)"
	write_state "$win" "$count" "$total" "$last"
	sleep "$REPROBE_WAIT"
	rprc=0
	"$PROBE" >/dev/null 2>&1 || rprc=$?
	if [ "$rprc" -eq 0 ]; then
		log "ClusterIP DNAT recovered after k3s restart #${count} this window."
		emit_metric 0 "$total" 0
		exit 0
	fi
	# Only a CONFIRMED-healthy reprobe (rc=0) counts as recovered; rc 1 (still wedged) or 2 (unknown)
	# → leave wedged so the next cycle re-evaluates under the cap.
	log "not confirmed-healthy after k3s restart #${count} (probe rc=$rprc) — will re-evaluate next cycle."
	emit_metric 1 "$total" 0
	exit 1
fi

if [ "$rc" -eq 124 ]; then
	# `timeout` killed the systemctl client (k3s itself keeps restarting under systemd). Count it so
	# the cap/give-up still applies, and surface it — a restart that does not return in time is a
	# regression of the 2026-06-29 clean-restart gate and must not be retried blindly.
	count="$((count + 1))"
	total="$((total + 1))"
	last="$(date +%s)"
	write_state "$win" "$count" "$total" "$last"
	log "k3s restart exceeded ${RESTART_TIMEOUT}s and was killed (timeout) — surfacing as wedged."
	emit_metric 1 "$total" 0
	exit 1
fi

log "k3s restart FAILED (rc=$rc)."
emit_metric 1 "$total" 0
exit 1
