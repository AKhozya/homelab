#!/usr/bin/env bash
# node-isolation-heal.sh — worker self-recovery when the node is isolated from the
# control-plane (k3s-agent tunnel to the CP wedged / can't reach the apiserver) while the
# HOST is still alive. WORKERS ONLY (wired in node-config.yml Play 4, hosts: workers; also
# no-ops where the k3s-agent unit is absent = the control-plane).
#
# Origin: 2026-07-10 worker-node-2 was isolated ~90 min (NotReady + host SSH blackholed)
# and recovered only by a manual power-cycle. No existing watchdog acted: clusterip_heal
# needs an active agent + a ClusterIP DNAT wedge; ufw_heal needs UFW inactive. This is
# defense-in-depth for the CLASS — the specific trigger (the firewall role's gratuitous
# `ufw reload`) is already fixed in ff2b486b.
#
# Signals (see docs/plans/2026-07-10-node-isolation-heal.md):
#   tunnel   : curl https://127.0.0.1:6444/cacerts   k3s-agent client LB → CP apiserver
#   cp_direct: TCP 192.168.1.127:6443                CP apiserver, LB-independent
#   kubelet  : curl http://127.0.0.1:10248/healthz   kubelet local healthz (logged only)
#   gateway  : ping 192.168.1.1                       LAN reachability (logged only)
# ISOLATED = tunnel down (agent can't reach the CP). kubelet stays healthy during isolation
# so it does NOT gate. cp_direct + gateway are the discriminators — cp_direct GATES the
# reboot (only reboot when the node genuinely can't reach the CP, not a mere LB glitch);
# kubelet + gateway are recorded for soak tuning.
#
# Ladder, only after ISOLATED past a debounce (L1 is always tried before L2):
#   L1  restart k3s-agent (rebuild tunnel/LB/CNI)     wedged >= RESTART_AFTER_S
#   L2  controlled self-reboot (LAST RESORT — the      wedged >= REBOOT_BASE_S + NODE_INDEX
#       only thing that recovered W2), STAGGERED per      * REBOOT_STAGGER_S, AND cp_direct
#       node so two simultaneously-isolated workers        down, AND an L1 already tried.
#       never reboot together (leaderless rolling reboot → HA DB loses ≤1 replica).
#
# DRY_RUN=1 (safe script fallback — the ansible-managed env file sets the live value):
# probe + log the decision it WOULD take + emit metrics; take NO destructive action.
# Active mode (0) relies on the interlocks: worker-local maint-hold set by phase2;
# shared k3s-agent restart cooldown honored by clusterip_heal too.

set -uo pipefail

# ── config (env, from /etc/node-isolation-heal/env; defaults are the safe fallback) ──
DRY_RUN="${NIH_DRY_RUN:-1}"
NODE_INDEX="${NIH_NODE_INDEX:-0}"                   # reboot stagger index (W1=0, W2=1)
FAIL_MIN="${NIH_FAIL_CONSECUTIVE:-2}"               # consecutive isolated cycles before acting
RESTART_AFTER_S="${NIH_RESTART_AFTER_S:-360}"       # wedged >= 6min  → L1 restart
REBOOT_BASE_S="${NIH_REBOOT_BASE_S:-900}"           # wedged >= 15min → L2 reboot (base, index 0)
REBOOT_STAGGER_S="${NIH_REBOOT_STAGGER_S:-480}"     # + index*8min (index 1 → 23min)
MIN_UPTIME_S="${NIH_MIN_UPTIME_S:-1800}"            # boot-loop guard (no reboot if uptime < 30min)
REBOOT_GAP_S="${NIH_REBOOT_GAP_S:-86400}"           # <= 1 reboot / 24h
RESTART_COOLDOWN_S="${NIH_RESTART_COOLDOWN_S:-300}" # min seconds between k3s-agent restarts
CURL_TIMEOUT="${NIH_CURL_TIMEOUT:-5}"
MAINT_HOLD_MAX_AGE_S="${NIH_MAINT_HOLD_MAX_AGE_S:-3600}" # ignore a stuck hold older than 1h

TUNNEL_URL="https://127.0.0.1:6444/cacerts"
KUBELET_URL="http://127.0.0.1:10248/healthz" # HTTP (verified: kubelet healthz is not TLS)
CP_HOST="192.168.1.127"
CP_PORT="6443"
GW_HOST="192.168.1.1"

STATE_DIR="${NIH_STATE_DIR:-/var/lib/node-isolation-heal}" # NIH_STATE_DIR: test override
STATE="${STATE_DIR}/state"                                 # "first_fail consecutive last_restart last_reboot"
MAINT_HOLD="${STATE_DIR}/maint-hold"
SHARED_RESTART_COOLDOWN="${NIH_SHARED_COOLDOWN:-/var/lib/k3s-agent-restart/cooldown}" # shared w/ clusterip_heal
METRIC_DIR="${NIH_METRIC_DIR:-/var/lib/node_exporter/textfile}"                       # NIH_METRIC_DIR: test override
METRIC="${METRIC_DIR}/node_isolation_heal.prom"

# signal state (set by the probe section; read by emit_metric)
tunnel_up=0 cp_up=0 kubelet_up=0 gw_up=0

log() {
	logger -t node-isolation-heal -- "$*" 2>/dev/null || true
	echo "node-isolation-heal: $*"
}

emit_metric() { # wedged(0/1) wedged_seconds pending(0none/1restart/2reboot) giveup(0/1)
	[ -d "$METRIC_DIR" ] || return 0
	local tmp
	tmp="$(mktemp "${METRIC}.XXXXXX")" || return 0
	if {
		printf '# HELP node_isolation_heal_wedged Worker isolated from control-plane (1=isolated).\n'
		printf '# TYPE node_isolation_heal_wedged gauge\n'
		printf 'node_isolation_heal_wedged %s\n' "$1"
		printf '# HELP node_isolation_heal_wedged_seconds Seconds the node has been continuously isolated.\n'
		printf '# TYPE node_isolation_heal_wedged_seconds gauge\n'
		printf 'node_isolation_heal_wedged_seconds %s\n' "$2"
		printf '# HELP node_isolation_heal_pending_action Action the ladder selected (0=none,1=restart,2=reboot).\n'
		printf '# TYPE node_isolation_heal_pending_action gauge\n'
		printf 'node_isolation_heal_pending_action %s\n' "$3"
		printf '# HELP node_isolation_heal_giveup Escalation exhausted (cap/guard) — needs a human (1=yes).\n'
		printf '# TYPE node_isolation_heal_giveup gauge\n'
		printf 'node_isolation_heal_giveup %s\n' "$4"
		printf '# HELP node_isolation_heal_dryrun Watchdog in dry-run (1=logs only, takes no action).\n'
		printf '# TYPE node_isolation_heal_dryrun gauge\n'
		printf 'node_isolation_heal_dryrun %s\n' "$DRY_RUN"
		printf '# HELP node_isolation_heal_signal_up Per-signal health (1=up). label: tunnel|cp_direct|kubelet|gateway.\n'
		printf '# TYPE node_isolation_heal_signal_up gauge\n'
		printf 'node_isolation_heal_signal_up{signal="tunnel"} %s\n' "$tunnel_up"
		printf 'node_isolation_heal_signal_up{signal="cp_direct"} %s\n' "$cp_up"
		printf 'node_isolation_heal_signal_up{signal="kubelet"} %s\n' "$kubelet_up"
		printf 'node_isolation_heal_signal_up{signal="gateway"} %s\n' "$gw_up"
		# Persists across the reboot via the state file — the durable signal for the
		# NodeIsolationHealRebooted alert. pending_action can't carry this: the active
		# reboot path deliberately emits 0 before rebooting (the textfile survives the
		# boot and a stale 2 would double-fire PendingReboot).
		printf '# HELP node_isolation_heal_last_reboot_timestamp Unix time of the last watchdog self-reboot (0=never).\n'
		printf '# TYPE node_isolation_heal_last_reboot_timestamp gauge\n'
		printf 'node_isolation_heal_last_reboot_timestamp %s\n' "${last_reboot:-0}"
	} >"$tmp"; then
		chmod 0644 "$tmp" # node_exporter scrapes as non-root; mktemp made it 0600
		mv -f "$tmp" "$METRIC" || rm -f "$tmp"
	else
		rm -f "$tmp"
	fi
}

write_state() { # first_fail consecutive last_restart last_reboot
	local tmp
	tmp="$(mktemp "${STATE}.XXXXXX")" || return 0
	if printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >"$tmp"; then
		mv -f "$tmp" "$STATE" || rm -f "$tmp"
	else
		rm -f "$tmp"
	fi
}

# probes — each honors an NIH_MOCK_* return-code override for the offline test harness.
probe_tunnel() {
	[ -n "${NIH_MOCK_TUNNEL:-}" ] && return "$NIH_MOCK_TUNNEL"
	curl -sk --max-time "$CURL_TIMEOUT" "$TUNNEL_URL" >/dev/null 2>&1
}
probe_cp() {
	[ -n "${NIH_MOCK_CP:-}" ] && return "$NIH_MOCK_CP"
	timeout "$CURL_TIMEOUT" bash -c "exec 3<>/dev/tcp/${CP_HOST}/${CP_PORT}" 2>/dev/null
}
probe_kubelet() {
	[ -n "${NIH_MOCK_KUBELET:-}" ] && return "$NIH_MOCK_KUBELET"
	curl -s --max-time "$CURL_TIMEOUT" "$KUBELET_URL" >/dev/null 2>&1
}
probe_gw() {
	[ -n "${NIH_MOCK_GW:-}" ] && return "$NIH_MOCK_GW"
	ping -c1 -W2 "$GW_HOST" >/dev/null 2>&1
}
uptime_s() { echo "${NIH_UPTIME_OVERRIDE:-$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)}"; } # NIH_UPTIME_OVERRIDE: test

# ── workers-only guard: no k3s-agent unit → this is the CP (or a non-node) → no-op ──
if ! systemctl cat k3s-agent.service >/dev/null 2>&1; then
	log "no k3s-agent unit here (control-plane?) — no-op."
	exit 0
fi

# ── maintenance interlock: skip while an orchestrated (phase2) reboot holds this worker ──
if [ -f "$MAINT_HOLD" ]; then
	hold_age="$(($(date +%s) - $(stat -c %Y "$MAINT_HOLD" 2>/dev/null || echo 0)))"
	if [ "$hold_age" -lt "$MAINT_HOLD_MAX_AGE_S" ]; then
		log "maintenance hold present (${hold_age}s old) — skipping this cycle."
		exit 0
	fi
	log "maintenance hold STALE (${hold_age}s > ${MAINT_HOLD_MAX_AGE_S}s) — ignoring."
fi

# ── read state ──
first_fail=0 consecutive=0 last_restart=0 last_reboot=0
if [ -r "$STATE" ]; then
	read -r first_fail consecutive last_restart last_reboot <"$STATE" 2>/dev/null || true
	first_fail="${first_fail:-0}" consecutive="${consecutive:-0}"
	last_restart="${last_restart:-0}" last_reboot="${last_reboot:-0}"
fi
now="$(date +%s)"

# ── probe signals ──
probe_tunnel && tunnel_up=1
probe_cp && cp_up=1
probe_kubelet && kubelet_up=1
probe_gw && gw_up=1

# tunnel up → the agent reaches the CP → node is a functioning member → clear the episode.
if [ "$tunnel_up" -eq 1 ]; then
	[ "$consecutive" -ne 0 ] && log "recovered (tunnel up; cp=$cp_up kubelet=$kubelet_up gw=$gw_up) — clearing episode."
	write_state 0 0 "$last_restart" "$last_reboot"
	emit_metric 0 0 0 0
	exit 0
fi

# ── isolated (tunnel down) ──
[ "$first_fail" -eq 0 ] && first_fail="$now"
consecutive="$((consecutive + 1))"
wedged_s="$((now - first_fail))"
log "ISOLATED (tunnel down; cp_direct=$cp_up kubelet=$kubelet_up gw=$gw_up) consecutive=$consecutive wedged=${wedged_s}s dry_run=$DRY_RUN"

# Debounce: need FAIL_MIN consecutive isolated cycles before any action.
if [ "$consecutive" -lt "$FAIL_MIN" ]; then
	write_state "$first_fail" "$consecutive" "$last_restart" "$last_reboot"
	emit_metric 1 "$wedged_s" 0 0
	exit 0
fi

reboot_threshold="$((REBOOT_BASE_S + NODE_INDEX * REBOOT_STAGGER_S))"
restarted_this_episode=0
if [ "$last_restart" -ne 0 ] && [ "$last_restart" -ge "$first_fail" ]; then restarted_this_episode=1; fi

# do_l1: k3s-agent restart rung (cooldown → dry-run → real), then exit the script.
do_l1() {
	# Hold the shared restart lock through check→restart→touch so this and clusterip_heal
	# can't interleave and double-restart k3s-agent. -n: never block; busy = wait a cycle.
	# Lock infra failing (no flock / fd open error) = fail CLOSED: skip the restart this
	# cycle — never degrade to the racy mtime-only path; wedged metric + Acting alert still
	# fire. NIH_SKIP_LOCK=1 is ONLY for the offline test harness (macOS has no flock);
	# production nodes always ship util-linux.
	if [ "${NIH_SKIP_LOCK:-0}" != "1" ]; then
		mkdir -p "$(dirname "$SHARED_RESTART_COOLDOWN")" 2>/dev/null || true
		if ! command -v flock >/dev/null 2>&1 || ! exec 9>>"$SHARED_RESTART_COOLDOWN" 2>/dev/null; then
			log "L1: restart-lock infrastructure unavailable (flock/fd open) — failing closed this cycle."
			write_state "$first_fail" "$consecutive" "$last_restart" "$last_reboot"
			emit_metric 1 "$wedged_s" 1 0
			exit 0
		fi
		if ! flock -n 9; then
			log "L1: another watchdog holds the k3s-agent restart lock — waiting a cycle."
			write_state "$first_fail" "$consecutive" "$last_restart" "$last_reboot"
			emit_metric 1 "$wedged_s" 1 0
			exit 0
		fi
	fi
	local shared_last=0 last_any="$last_restart"
	[ -f "$SHARED_RESTART_COOLDOWN" ] && shared_last="$(stat -c %Y "$SHARED_RESTART_COOLDOWN" 2>/dev/null || echo 0)"
	[ "$shared_last" -gt "$last_any" ] && last_any="$shared_last"
	if [ "$last_any" -ne 0 ] && [ "$((now - last_any))" -lt "$RESTART_COOLDOWN_S" ]; then
		log "L1 cooldown: last k3s-agent restart $((now - last_any))s ago < ${RESTART_COOLDOWN_S}s — waiting a cycle."
		write_state "$first_fail" "$consecutive" "$last_restart" "$last_reboot"
		emit_metric 1 "$wedged_s" 1 0
		exit 0
	fi
	emit_metric 1 "$wedged_s" 1 0
	if [ "$DRY_RUN" = "1" ]; then
		# Record the SIMULATED L1 so the ladder progresses to the reboot rung in the soak.
		log "DRY_RUN: WOULD restart k3s-agent now (wedged ${wedged_s}s >= ${RESTART_AFTER_S}s). Taking NO action."
		write_state "$first_fail" "$consecutive" "$now" "$last_reboot"
		exit 0
	fi
	log "L1: restarting k3s-agent (isolated ${wedged_s}s)."
	: >"$SHARED_RESTART_COOLDOWN" 2>/dev/null || true
	write_state "$first_fail" "$consecutive" "$now" "$last_reboot"
	systemctl restart k3s-agent.service || log "L1: k3s-agent restart FAILED."
	exit 0
}

# L1 ALWAYS precedes L2: if no L1 tried yet this episode, do it now — even if already past
# the reboot threshold (try the cheap fix first). This also prevents the infinite-defer loop.
if [ "$wedged_s" -ge "$RESTART_AFTER_S" ] && [ "$restarted_this_episode" -eq 0 ]; then
	do_l1
fi

# L2 reboot: only when the node ALSO can't reach the CP directly (true network isolation,
# not just a wedged LB), an L1 was already tried, and the guards pass.
if [ "$wedged_s" -ge "$reboot_threshold" ] && [ "$cp_up" -eq 0 ]; then
	up="$(uptime_s)"
	if [ "$up" -lt "$MIN_UPTIME_S" ]; then
		log "reboot GUARD: uptime ${up}s < ${MIN_UPTIME_S}s (boot-loop) — giving up, alerting."
		write_state "$first_fail" "$consecutive" "$last_restart" "$last_reboot"
		emit_metric 1 "$wedged_s" 2 1
		exit 1
	fi
	if [ "$last_reboot" -ne 0 ] && [ "$((now - last_reboot))" -lt "$REBOOT_GAP_S" ]; then
		log "reboot GUARD: last self-reboot $((now - last_reboot))s ago < ${REBOOT_GAP_S}s (daily cap) — giving up, alerting."
		write_state "$first_fail" "$consecutive" "$last_restart" "$last_reboot"
		emit_metric 1 "$wedged_s" 2 1
		exit 1
	fi
	if [ "$DRY_RUN" = "1" ]; then
		emit_metric 1 "$wedged_s" 2 0
		log "DRY_RUN: WOULD self-reboot now (wedged ${wedged_s}s >= ${reboot_threshold}s, index=$NODE_INDEX, cp_direct down, prior L1 tried). Taking NO action."
		write_state "$first_fail" "$consecutive" "$last_restart" "$last_reboot"
		exit 0
	fi
	log "SELF-REBOOT: isolated ${wedged_s}s, cannot reach CP, L1 didn't recover — rebooting (staggered index=$NODE_INDEX)."
	# pending_action goes to the textfile under /var/lib, which SURVIVES the reboot —
	# node-exporter would re-expose a stale 2 for ~2min post-boot (watchdog OnBootSec)
	# and double-fire PendingReboot on top of Rebooted. Emit 0 before rebooting; the
	# completed reboot is signaled by node_isolation_heal_last_reboot_timestamp alone.
	emit_metric 1 "$wedged_s" 0 0
	write_state "$first_fail" "$consecutive" "$last_restart" "$now"
	systemctl reboot
	exit 0
fi

# L1 retry: still wedged, either not yet at the reboot threshold OR network is fine (cp_up=1)
# so a reboot is not warranted — keep trying the restart (cooldown inside bounds the rate).
if [ "$wedged_s" -ge "$RESTART_AFTER_S" ]; then
	do_l1
fi

# ── isolated but below the L1 threshold: keep waiting ──
log "isolated ${wedged_s}s (< ${RESTART_AFTER_S}s L1 threshold) — waiting."
write_state "$first_fail" "$consecutive" "$last_restart" "$last_reboot"
emit_metric 1 "$wedged_s" 0 0
exit 0
