#!/usr/bin/env bash
# clusterip-probe.sh — verify k3s ClusterIP DNAT works from this node's host netns.
# Runs ON a node (host netns), no sudo, no args. Targets the WORKER kube-proxy wedge surface
# (2026-05-24): node kubelet-Ready but KUBE-SERVICES DNAT for 10.43.0.1 missing → pods crashloop
# on connection refused/timeout. The apiserver /healthz returns 401 unauthenticated when routed.
#
# MULTI-SAMPLE: probes N times (default 3, override CLUSTERIP_PROBE_SAMPLES) and requires ALL of them
# to return 401|200. ANY timeout/non-2xx among the samples = WEDGED. A single probe is fooled by an
# INTERMITTENT/flapping wedge: 2026-05-25 worker-node flapped 401↔000, a one-shot gate caught a lucky
# 401 and passed, uncordoned, then the node stayed wedged. Requiring N clean samples refuses a flapper.
# Exit 0 = all N healthy, 1 = at least one sample wedged.
#
# Scope note: the CP control-plane reachability surface is DIFFERENT — k3s components dial the loopback
# loadbalancer (CP: 127.0.0.1:6443, workers: 127.0.0.1:6444). That wedge (2026-05-25) is gated
# separately + CP-only in phase2 PLAY 0 / watch-reboot, NOT here. host-netns 10.43.0.1 can also read
# 000 on the CP even when pod-netns is fine, so this probe is meaningful on workers.
#
# NOTE: this multi-sample curl/`401|200` logic is duplicated in verify-clusterip.sh (over-SSH variant)
# — keep the two in sync if either is changed.
set -euo pipefail
samples="${CLUSTERIP_PROBE_SAMPLES:-3}"
ok=0
bad=0
codes=""
for _ in $(seq 1 "$samples"); do
	# `|| code=000` (NOT `|| echo 000` inside the $()) avoids doubling curl's own "000" timeout output.
	code="$(curl -sS -m5 -k -o /dev/null -w '%{http_code}' https://10.43.0.1:443/healthz 2>/dev/null)" || code=000
	codes="$codes $code"
	case "$code" in
	401 | 200) ok=$((ok + 1)) ;;
	*) bad=$((bad + 1)) ;;
	esac
	sleep 1
done
if [ "$bad" -eq 0 ]; then
	echo "clusterip OK ($ok/$samples healthy, codes:$codes)"
	exit 0
fi
echo "clusterip WEDGED ($bad/$samples failed, codes:$codes — DNAT missing/intermittent)"
exit 1
