#!/usr/bin/env bash
# clusterip-heal.sh — node-local self-heal for the post-reboot kube-proxy ClusterIP DNAT wedge.
#
# WORKERS ONLY. Wired in node-config.yml Play 4 (hosts: workers) AND it acts on k3s-agent, which does
# not exist on the control-plane (the CP runs k3s.service). The CP host-netns path to 10.43.0.1 reads
# 000 even when healthy (documented quirk), and `systemctl restart k3s` on the CP HANGS
# (gotcha_k3s_reboot_ordering) — both facts keep this watchdog off the CP.
#
# Why: the legacy iptables kube-proxy programs services via one atomic iptables-restore. On reboot a
# stale nft chain ("CHAIN_USER_ADD failed (File exists)") makes that restore fail → KUBE-SERVICES (the
# 10.43.0.1 DNAT) is never programmed and the proxier retries the poisoned state forever, while the
# node stays kubelet-Ready. The ONLY recovery is `systemctl restart k3s-agent` (rebuilds chains clean).
# The phase2 ClusterIP gate restarts k3s-agent DURING a maintenance run, but a worker can re-wedge
# AFTER uncordon (2026-06-20: worker-node needed a manual restart). This watchdog makes that recovery
# automatic — on boot + every few minutes — so no human is needed.
#
# Scope: detects the HOST-NETNS-visible DNAT-missing wedge (clusterip-probe.sh: 10.43.0.1:443 +
# :10256). It does NOT see the CNI portmap masquerade wedge (2026-05-30, host-netns reads healthy) —
# that is handled by ufw-heal + the phase2 nat-jump gate.
#
# Safety: acts only when k3s-agent is active AND clusterip-probe.sh confirms WEDGED. A cooldown
# between restarts and a max-restarts-per-window cap stop a restart that does NOT fix the wedge from
# storming; past the cap it backs off and emits a give-up metric so an alert fires — a persistent
# wedge is a deeper fault, and masking it with endless restarts is worse than surfacing it.

set -euo pipefail

PROBE="/etc/node-maintenance/bin/clusterip-probe.sh"
STATE="/var/lib/node-maintenance/clusterip-heal.state" # "window_start count total last_restart"
METRIC_DIR="/var/lib/node_exporter/textfile"
METRIC="${METRIC_DIR}/clusterip_heal.prom"
# Shared cross-watchdog cooldown (also touched by node_isolation_heal's L1): neither
# watchdog restarts k3s-agent within COOLDOWN of the other's restart.
SHARED_RESTART_COOLDOWN="/var/lib/k3s-agent-restart/cooldown"

COOLDOWN=300    # min seconds between restarts (let the last one settle)
WINDOW=1800     # cap window (s)
MAX_RESTARTS=3  # max restarts within WINDOW before giving up + alerting
REPROBE_WAIT=15 # seconds to let k3s-agent reprogram before re-probing

log() {
	logger -t clusterip-heal -- "$*" 2>/dev/null || true
	echo "clusterip-heal: $*"
}

emit_metric() { # $1 wedged(0/1)  $2 restarts-total  $3 giveup(0/1)
	[ -d "$METRIC_DIR" ] || return 0
	local tmp
	tmp="$(mktemp "${METRIC}.XXXXXX")" || return 0
	if {
		printf '# HELP node_clusterip_heal_wedged Worker ClusterIP DNAT wedge detected (1=wedged).\n'
		printf '# TYPE node_clusterip_heal_wedged gauge\n'
		printf 'node_clusterip_heal_wedged %s\n' "$1"
		printf '# HELP node_clusterip_heal_restarts_total k3s-agent restarts issued by the heal watchdog.\n'
		printf '# TYPE node_clusterip_heal_restarts_total counter\n'
		printf 'node_clusterip_heal_restarts_total %s\n' "$2"
		printf '# HELP node_clusterip_heal_giveup Wedge persisted past MAX_RESTARTS (1=needs a human).\n'
		printf '# TYPE node_clusterip_heal_giveup gauge\n'
		printf 'node_clusterip_heal_giveup %s\n' "$3"
	} >"$tmp"; then
		# 0644 so a non-root node_exporter can scrape it (mktemp made it 0600; all sibling
		# *.prom in the textfile dir are 0644). Without this the wedged/giveup metrics are
		# never scraped → the give-up alert is silent.
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

# k3s-agent must exist + be active. This also makes the script a safe no-op on the CP (no k3s-agent).
if ! systemctl is-active --quiet k3s-agent.service; then
	log "k3s-agent not active here — nothing to heal (no-op on CP / agent down)."
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

# Healthy → clear wedge metric and exit.
if "$PROBE" >/dev/null 2>&1; then
	emit_metric 0 "$total" 0
	exit 0
fi

log "ClusterIP DNAT WEDGED on $(hostname)."

# Roll the cap window if it has elapsed.
if [ "$((now - win))" -gt "$WINDOW" ]; then
	win="$now"
	count=0
fi

# Cap reached → give up, alert via metric, do NOT restart again.
if [ "$count" -ge "$MAX_RESTARTS" ]; then
	log "still wedged after ${count} restart(s) in $((WINDOW / 60))min — giving up, NOT restarting. Deeper fault than the iptables-restore wedge; investigate."
	write_state "$win" "$count" "$total" "$last"
	emit_metric 1 "$total" 1
	exit 1
fi

# Serialize with node_isolation_heal: hold the shared lock from cooldown-check through
# restart+touch, so the two watchdogs can't interleave check→restart and double-restart
# k3s-agent. -n = never block the timer cycle; lock auto-releases on exit.
# Lock infra failing (no flock / fd open error) = fail CLOSED: skip the restart this cycle
# — never degrade to the racy mtime-only path; the wedged metric + alert still fire.
mkdir -p "$(dirname "$SHARED_RESTART_COOLDOWN")" 2>/dev/null || true
if ! command -v flock >/dev/null 2>&1 || ! exec 9>>"$SHARED_RESTART_COOLDOWN" 2>/dev/null; then
	log "restart-lock infrastructure unavailable (flock/fd open) — failing closed this cycle."
	emit_metric 1 "$total" 0
	exit 1
fi
if ! flock -n 9; then
	log "another watchdog holds the k3s-agent restart lock — waiting a cycle."
	emit_metric 1 "$total" 0
	exit 1
fi

# Cooldown → wait one cycle so the previous restart can settle. The shared file's mtime
# counts too, so an L1 restart by node_isolation_heal defers this watchdog (and vice versa).
last_any="$last"
if [ -f "$SHARED_RESTART_COOLDOWN" ]; then
	shared_last="$(stat -c %Y "$SHARED_RESTART_COOLDOWN" 2>/dev/null || echo 0)"
	if [ "$shared_last" -gt "$last_any" ]; then last_any="$shared_last"; fi
fi
if [ "$last_any" -ne 0 ] && [ "$((now - last_any))" -lt "$COOLDOWN" ]; then
	log "within ${COOLDOWN}s cooldown ($((now - last_any))s since last k3s-agent restart) — waiting a cycle."
	emit_metric 1 "$total" 0
	exit 1
fi

# Heal: restart k3s-agent to rebuild kube-proxy chains from a clean slate.
log "restarting k3s-agent to rebuild kube-proxy chains."
if systemctl restart k3s-agent.service; then
	count="$((count + 1))"
	total="$((total + 1))"
	last="$(date +%s)"
	: >"$SHARED_RESTART_COOLDOWN" 2>/dev/null || true
	write_state "$win" "$count" "$total" "$last"
	sleep "$REPROBE_WAIT"
	if "$PROBE" >/dev/null 2>&1; then
		log "ClusterIP DNAT recovered after restart #${count} this window."
		emit_metric 0 "$total" 0
		exit 0
	fi
	log "still wedged after restart #${count} — will re-evaluate next cycle."
	emit_metric 1 "$total" 0
	exit 1
fi

log "k3s-agent restart FAILED."
emit_metric 1 "$total" 0
exit 1
