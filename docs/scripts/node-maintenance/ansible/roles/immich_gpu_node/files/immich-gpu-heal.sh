#!/usr/bin/env bash
# immich-gpu-heal.sh — guest-local self-heal for the Immich GPU node (passed-through Intel iGPU).
#
# Runs on the Arch VM only (the `virtual` inventory group). Mirrors clusterip-heal.sh: bounded
# restart + node-exporter textfile metrics. PRIMARY heal: the passed-through i915 render node
# (renderD129) going missing — i915 unloaded, or load-i915.service not yet run — recovered by
# restarting load-i915.service (which modprobes i915 render-only). Bounded so a restart that does
# NOT fix it (a deeper fault: reset-bug wedge, vfio not bound) backs off + emits a give-up metric
# so an alert fires instead of storming pointless reloads.
#
# NOT healed here, by design:
#   - k3s-agent / node-NotReady → clusterip_heal owns that (this VM is a workers-group node). Two
#     watchdogs restarting k3s-agent would fight; render health is this one's only job.
#   - reset-bug guest wedge (recovers ONLY via a HOST cold-restart / vfio reset) → Tier-2 host
#     CronJob watchdog. A guest-local i915 reload can't reset a wedged IGD; the give-up here is the
#     signal that surfaces it for Tier 2.
#
# Deploy-safe pre-passthrough: no-ops (exit 0) when no Intel display GPU is on the PCI bus, so it
# stays inert until the domain gains <hostdev> (step 3) and never storms on absent hardware.
#
# Self-test: `immich-gpu-heal.sh --selfcheck` asserts the bounded decision + metric/state logic.

set -euo pipefail

STATE="/var/lib/node-maintenance/immich-gpu-heal.state" # "win count total last_restart last_qsv"
METRIC_DIR="/var/lib/node_exporter/textfile"
METRIC="${METRIC_DIR}/immich_gpu_heal.prom"
RENDER_NODE="/dev/dri/renderD129"       # Intel iGPU render node (virtio-gpu is renderD128)
LIBRARY_MOUNT="/var/lib/immich-library" # virtiofs library mount; healed only when a mount unit exists

COOLDOWN=300      # min seconds between load-i915 restarts (let the last settle)
WINDOW=1800       # give-up window (s)
MAX_RESTARTS=3    # restarts within WINDOW before giving up + alerting
REPROBE_WAIT=10   # seconds to let i915 settle before re-checking
QSV_INTERVAL=3600 # full vainfo probe at most hourly — do NOT contend with a live transcode every cycle
QSV_TIMEOUT=30    # bound a NORMAL vainfo hang; a D-state hang survives SIGKILL → surfaced via qsv_probe_stuck

log() {
	logger -t immich-gpu-heal -- "$*" 2>/dev/null || true
	echo "immich-gpu-heal: $*"
}

# Intel display GPU present on the PCI bus? sysfs only (no lspci dep). Pre-passthrough the guest has
# only virtio-gpu → false → the whole watchdog is inert. class 0x03xxxx = Display controller.
has_intel_gpu() {
	local d v c
	for d in /sys/bus/pci/devices/*; do
		[ -r "$d/vendor" ] && [ -r "$d/class" ] || continue
		v="$(cat "$d/vendor")"
		c="$(cat "$d/class")"
		if [ "$v" = "0x8086" ]; then
			case "$c" in
			0x03*) return 0 ;;
			esac
		fi
	done
	return 1
}

i915_loaded() { [ -d /sys/module/i915 ]; }
render_present() { [ -e "$RENDER_NODE" ]; }

library_unit() { systemd-escape -p --suffix=mount "$LIBRARY_MOUNT" 2>/dev/null || true; }

# echoes ok | down | absent  (absent = not configured yet → not a fault)
virtiofs_state() {
	local unit
	unit="$(library_unit)"
	if [ -z "$unit" ] || ! systemctl cat "$unit" >/dev/null 2>&1; then
		echo absent
		return 0
	fi
	if mountpoint -q "$LIBRARY_MOUNT"; then echo ok; else echo down; fi
}

# vainfo lists a QSV encode entrypoint on the Intel render node. rc 0=ok, 1=no-encode, 2=unverifiable.
# `timeout` bounds a NORMAL (killable) hang. The pre-Track-0 fbdev wedge hung vainfo in D-state where
# SIGKILL is ignored — timeout can't reap that; qsv_probe_stuck() catches the leftover instead (below).
qsv_probe() {
	command -v vainfo >/dev/null 2>&1 || return 2
	timeout -k 5 "$QSV_TIMEOUT" env LIBVA_DRIVER_NAME=iHD \
		vainfo --display drm --device "$RENDER_NODE" 2>/dev/null |
		grep -q 'VAEntrypointEncSlice'
}

# A prior hourly vainfo still alive = it wedged in D-state (timeout couldn't kill it). Detect it so the
# cycle surfaces the stuck probe instead of launching another that piles up (self-heal that self-harms).
qsv_probe_stuck() {
	pgrep -f "vainfo .*${RENDER_NODE}" >/dev/null 2>&1
}

# Pure bounded-restart decision (unit-testable, no systemctl). Applies the window roll, then picks
# the action. echoes: "<giveup|cooldown|heal> <win> <count>".
decide() { # $1 now  $2 win  $3 count  $4 last
	local now=$1 win=$2 count=$3 last=$4
	if [ "$((now - win))" -gt "$WINDOW" ]; then
		win=$now
		count=0
	fi
	if [ "$count" -ge "$MAX_RESTARTS" ]; then
		echo "giveup $win $count"
		return
	fi
	if [ "$last" -ne 0 ] && [ "$((now - last))" -lt "$COOLDOWN" ]; then
		echo "cooldown $win $count"
		return
	fi
	echo "heal $win $count"
}

emit_metric() { # $1 render_ok  $2 qsv(1/0/-1)  $3 virtiofs_ok  $4 restarts_total  $5 giveup(0/1)  [$6 qsv_stuck(0/1)]
	[ -d "$METRIC_DIR" ] || return 0
	local tmp stuck="${6:-0}"
	tmp="$(mktemp "${METRIC}.XXXXXX")" || return 0
	if {
		printf '# HELP immich_gpu_render_ok Intel i915 render node (renderD129) present + i915 loaded (1=ok).\n'
		printf '# TYPE immich_gpu_render_ok gauge\n'
		printf 'immich_gpu_render_ok %s\n' "$1"
		printf '# HELP immich_gpu_qsv_ok vainfo lists a QSV encode entrypoint (1=ok 0=no-encode -1=unverified; hourly).\n'
		printf '# TYPE immich_gpu_qsv_ok gauge\n'
		printf 'immich_gpu_qsv_ok %s\n' "$2"
		printf '# HELP immich_gpu_virtiofs_ok Immich library virtiofs mount present (1=ok/not-yet-configured 0=down).\n'
		printf '# TYPE immich_gpu_virtiofs_ok gauge\n'
		printf 'immich_gpu_virtiofs_ok %s\n' "$3"
		printf '# HELP immich_gpu_heal_restarts_total load-i915.service restarts issued by the heal watchdog.\n'
		printf '# TYPE immich_gpu_heal_restarts_total counter\n'
		printf 'immich_gpu_heal_restarts_total %s\n' "$4"
		printf '# HELP immich_gpu_heal_giveup Render fault persisted past MAX_RESTARTS (1=needs a human / host cold-restart).\n'
		printf '# TYPE immich_gpu_heal_giveup gauge\n'
		printf 'immich_gpu_heal_giveup %s\n' "$5"
		printf '# HELP immich_gpu_qsv_stuck A prior hourly QSV probe is wedged in D-state (1=needs a host cold-restart; probe not relaunched).\n'
		printf '# TYPE immich_gpu_qsv_stuck gauge\n'
		printf 'immich_gpu_qsv_stuck %s\n' "$stuck"
	} >"$tmp"; then
		# 0644 so a non-root node_exporter can scrape (mktemp made it 0600; sibling *.prom are 0644).
		chmod 0644 "$tmp"
		mv -f "$tmp" "$METRIC" || rm -f "$tmp"
	else
		rm -f "$tmp"
	fi
}

write_state() { # $1 win  $2 count  $3 total  $4 last  $5 last_qsv
	local tmp
	tmp="$(mktemp "${STATE}.XXXXXX")" || return 0
	if printf '%s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5" >"$tmp"; then
		mv -f "$tmp" "$STATE" || rm -f "$tmp"
	else
		rm -f "$tmp"
	fi
}

selfcheck() {
	local fail=0
	_a() { if [ "$2" = "$3" ]; then echo "ok: $1"; else
		echo "FAIL: $1 (got '$2' want '$3')"
		fail=1
	fi; }

	_a "fresh->heal" "$(decide 1000 0 0 0 | awk '{print $1}')" heal
	_a "cap->giveup" "$(decide 1000 900 "$MAX_RESTARTS" 950 | awk '{print $1}')" giveup
	_a "cooldown" "$(decide 1000 900 1 900 | awk '{print $1}')" cooldown
	_a "past-cooldown->heal" "$(decide 2000 1900 1 1000 | awk '{print $1}')" heal
	_a "windowroll->heal" "$(decide 5000 1000 "$MAX_RESTARTS" 4000 | awk '{print $1}')" heal
	_a "windowroll resets count" "$(decide 5000 1000 "$MAX_RESTARTS" 4000 | awk '{print $3}')" 0

	local sd
	sd="$(mktemp -d)"
	STATE="$sd/s"
	write_state 10 2 5 99 111
	read -r a b c d e <"$STATE"
	_a "state win" "$a" 10
	_a "state count" "$b" 2
	_a "state total" "$c" 5
	_a "state last" "$d" 99
	_a "state qsv" "$e" 111

	METRIC_DIR="$sd"
	METRIC="$sd/m.prom"
	emit_metric 1 -1 1 7 0
	_a "metric render" "$(grep -c '^immich_gpu_render_ok 1$' "$METRIC")" 1
	_a "metric qsv" "$(grep -c '^immich_gpu_qsv_ok -1$' "$METRIC")" 1
	_a "metric total" "$(grep -c '^immich_gpu_heal_restarts_total 7$' "$METRIC")" 1
	_a "metric stuck default" "$(grep -c '^immich_gpu_qsv_stuck 0$' "$METRIC")" 1
	emit_metric 1 -1 1 7 0 1
	_a "metric stuck set" "$(grep -c '^immich_gpu_qsv_stuck 1$' "$METRIC")" 1
	rm -rf "$sd"

	if [ "$fail" = 0 ]; then
		echo "SELFCHECK PASS"
		return 0
	else
		echo "SELFCHECK FAIL"
		return 1
	fi
}

if [ "${1:-}" = "--selfcheck" ]; then
	selfcheck
	exit $?
fi

# ---- read state (needed by every branch, incl. the inert exit) ----
win=0 count=0 total=0 last=0 last_qsv=0
if [ -r "$STATE" ]; then
	read -r win count total last last_qsv <"$STATE" 2>/dev/null || true
	win="${win:-0}" count="${count:-0}" total="${total:-0}" last="${last:-0}" last_qsv="${last_qsv:-0}"
fi
now="$(date +%s)"

# No Intel GPU on the bus → inert. Pre-passthrough (fine) OR the hostdev vanished (a HOST fault for
# Tier 2 — a guest reload can't bring back a detached PCI device). render_ok=0, giveup stays 0.
if ! has_intel_gpu; then
	log "no Intel display GPU on PCI bus — inert (pre-passthrough or GPU detached)."
	emit_metric 0 -1 1 "$total" 0
	exit 0
fi

# virtiofs: cheap, systemd-backoff-managed → just start the unit if configured-but-down (no custom bound).
vfs="$(virtiofs_state)"
vfs_ok=1
if [ "$vfs" = down ]; then
	vfs_ok=0
	log "virtiofs library mount $LIBRARY_MOUNT down — starting mount unit."
	systemctl start "$(library_unit)" || true
fi

# Hourly QSV probe (only when the render node exists; do not contend with a live transcode each cycle).
# If a prior probe is still stuck in D-state (the pre-Track-0 fbdev wedge signature), surface it via
# immich_gpu_qsv_stuck instead of launching another that accumulates unkillably.
qsv_metric=-1
qsv_stuck=0
if qsv_probe_stuck; then
	qsv_stuck=1
	log "prior vainfo QSV probe still stuck (D-state) — NOT launching another; immich_gpu_qsv_stuck=1 (needs a host cold-restart)."
elif render_present && [ "$((now - last_qsv))" -ge "$QSV_INTERVAL" ]; then
	if qsv_probe; then qsv_metric=1; else
		rc=$?
		[ "$rc" = 2 ] && qsv_metric=-1 || qsv_metric=0
	fi
	last_qsv="$now"
fi

if i915_loaded && render_present; then
	emit_metric 1 "$qsv_metric" "$vfs_ok" "$total" 0 "$qsv_stuck"
	write_state "$win" "$count" "$total" "$last" "$last_qsv"
	exit 0
fi

log "render node $RENDER_NODE missing / i915 not loaded (Intel GPU present)."

read -r action win count < <(decide "$now" "$win" "$count" "$last")

case "$action" in
giveup)
	log "render still down after ${count} load-i915 restart(s) in $((WINDOW / 60))min — giving up. Likely a reset-bug/vfio wedge needing a HOST cold-restart (Tier-2). NOT restarting again."
	write_state "$win" "$count" "$total" "$last" "$last_qsv"
	emit_metric 0 -1 "$vfs_ok" "$total" 1
	exit 1
	;;
cooldown)
	log "within ${COOLDOWN}s cooldown ($((now - last))s since last restart) — waiting a cycle."
	write_state "$win" "$count" "$total" "$last" "$last_qsv"
	emit_metric 0 -1 "$vfs_ok" "$total" 0
	exit 1
	;;
esac

log "restarting load-i915.service to reload i915 render driver."
if systemctl restart load-i915.service; then
	count="$((count + 1))"
	total="$((total + 1))"
	last="$(date +%s)"
	write_state "$win" "$count" "$total" "$last" "$last_qsv"
	sleep "$REPROBE_WAIT"
	if i915_loaded && render_present; then
		log "render recovered after restart #${count} this window."
		emit_metric 1 -1 "$vfs_ok" "$total" 0
		exit 0
	fi
	log "still down after restart #${count} — will re-evaluate next cycle."
	emit_metric 0 -1 "$vfs_ok" "$total" 0
	exit 1
fi

log "load-i915.service restart FAILED."
emit_metric 0 -1 "$vfs_ok" "$total" 0
exit 1
