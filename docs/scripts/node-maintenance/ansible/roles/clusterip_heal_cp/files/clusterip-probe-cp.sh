#!/usr/bin/env bash
# clusterip-probe-cp.sh — CONTROL-PLANE pod-netns ClusterIP probe.
#
# The host-netns probe (clusterip-probe.sh) false-reads 000 on the CP even when healthy, so it
# cannot detect the CP's post-reboot kube-proxy ClusterIP DNAT wedge. This probes from a REAL pod's
# netns instead: nsenter into the coredns-ha pod (DaemonSet → always on the CP) and curl the
# apiserver ClusterIP healthz. Validated 2026-06-29: a CP-pinned pod (uptime-kuma) could not reach
# 10.43.0.1 / 10.43.0.10 post-reboot while the host and BOTH workers were fine; a `systemctl restart
# k3s` reprogrammed the DNAT and cleared it.
#
# THREE-STATE CONTRACT (the heal script auto-restarts k3s on the CP, so a false WEDGED is costly —
# unlike the workers' cheap k3s-agent restart, this probe is deliberately conservative):
#   exit 0 = HEALTHY  — the ClusterIP was reachable on at least one sample.
#   exit 1 = WEDGED   — EVERY sample was a confirmed connect failure (curl 000). ONLY this restarts k3s.
#   exit 2 = UNKNOWN  — could not probe (no coredns pod / stale netns / nsenter error) OR a mixed read.
#                       The heal script no-ops on UNKNOWN and does NOT touch metrics.
# Multi-sample (default 3) so a single transient blip can never reach WEDGED on its own.
set -euo pipefail
samples="${CLUSTERIP_PROBE_SAMPLES:-3}"

# Prefer a standalone crictl; fall back to the k3s-bundled one. The absolute path / `k3s` command
# never re-enters this function, so no recursion.
crictl() {
	if command -v /usr/local/bin/crictl >/dev/null 2>&1; then
		/usr/local/bin/crictl "$@"
	else
		k3s crictl "$@"
	fi
}

# Ready coredns sandbox on THIS node; its netns is a usable pod netns. Cannot find one → UNKNOWN
# (NEVER fall through to a k3s restart on an unverifiable read).
sandbox="$(crictl pods --namespace kube-system --label k8s-app=kube-dns --state Ready -q 2>/dev/null | head -1 || true)"
if [ -z "$sandbox" ]; then
	echo "probe-cp: no Ready coredns sandbox on this node — cannot probe pod-netns (UNKNOWN)."
	exit 2
fi
pid="$(crictl inspectp "$sandbox" 2>/dev/null | jq -r '.info.pid // empty' 2>/dev/null || true)"
if [ -z "$pid" ] || [ "$pid" = "null" ] || [ "$pid" = "0" ]; then
	echo "probe-cp: could not resolve coredns netns PID (UNKNOWN)."
	exit 2
fi

ok=0
fail=0
unknown=0
detail=""
for _ in $(seq 1 "$samples"); do
	# curl prints the HTTP code (000 on connect failure) whenever it actually RUNS; EMPTY output means
	# nsenter/curl could not run at all (stale netns / exec error) — that is "unknown", not a wedge.
	code="$(nsenter -t "$pid" -n curl -sS -m5 -k -o /dev/null -w '%{http_code}' https://10.43.0.1:443/healthz 2>/dev/null || true)"
	case "$code" in
	200 | 401)
		detail="$detail [$code]"
		ok=$((ok + 1))
		;;
	000)
		# curl ran but could not connect → apiserver ClusterIP DNAT unreachable = the wedge signal.
		detail="$detail [000]"
		fail=$((fail + 1))
		;;
	"")
		# no output → nsenter/curl could not run (stale PID, exec error) = UNKNOWN, NOT a wedge.
		detail="$detail [unk]"
		unknown=$((unknown + 1))
		;;
	*)
		# Any other HTTP status (5xx, etc.) → apiserver reachable (DNAT present), just unhealthy — not
		# a ClusterIP-DNAT wedge, so do NOT count it toward a k3s restart.
		detail="$detail [$code]"
		ok=$((ok + 1))
		;;
	esac
	sleep 1
done

# Reachable even once → the DNAT is programmed → healthy (conservative: never restart if it worked).
if [ "$ok" -ge 1 ]; then
	echo "cp-pod-net OK (ok=$ok fail=$fail unknown=$unknown:$detail)"
	exit 0
fi
# EVERY sample was a confirmed connect failure (no successes, no unknowns) → genuinely wedged.
if [ "$fail" -eq "$samples" ]; then
	echo "cp-pod-net WEDGED ($fail/$samples connect-failed:$detail — apiserver ClusterIP DNAT unreachable from pod-netns)"
	exit 1
fi
# Anything else (unknowns present, or a mix) → cannot confirm a wedge; take NO action.
echo "cp-pod-net UNKNOWN (ok=$ok fail=$fail unknown=$unknown:$detail)"
exit 2
