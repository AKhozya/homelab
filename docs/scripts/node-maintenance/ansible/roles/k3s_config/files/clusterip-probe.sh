#!/usr/bin/env bash
# clusterip-probe.sh — verify a node's kube-proxy is actually healthy after (re)start, from the
# node's host netns. No sudo, no args. Two complementary signals, BOTH required per sample:
#   1. ClusterIP DNAT — curl https://10.43.0.1:443/healthz → 401|200 (kube-proxy programmed the
#      KUBE-SERVICES DNAT for the apiserver ClusterIP). 000/timeout = DNAT missing.
#   2. kube-proxy healthz — curl http://127.0.0.1:10256/healthz → 200 (the proxier's OWN last-sync
#      health). This directly catches the wedge ROOT CAUSE (2026-05-25 research): an iptables/nft
#      stale-chain conflict makes kube-proxy's atomic iptables-restore fail on reboot, so KUBE-SERVICES
#      never gets programmed and the proxier retries the poisoned state forever — :10256 goes unhealthy
#      while the node is still kubelet-Ready. Fix = restart k3s-agent (rebuilds chains clean).
#
# MULTI-SAMPLE: probes N times (default 3, override CLUSTERIP_PROBE_SAMPLES); ALL N must pass both
# checks. Defeats an INTERMITTENT/flapping wedge that a one-shot probe passes on a lucky reading.
# Exit 0 = all N healthy, 1 = at least one sample wedged.
#
# Scope: the CP control-plane reachability surface is DIFFERENT (k3s loopback LB 127.0.0.1:6443/6444),
# gated separately + CP-only in phase2 PLAY 0 / watch-reboot. host-netns 10.43.0.1 can read 000 on the
# CP even when healthy — so this probe is meaningful on WORKERS (where the phase2 gate uses it).
# NOTE: the dual curl/`401|200`+`:10256` logic is duplicated in verify-clusterip.sh — keep in sync.
set -euo pipefail
samples="${CLUSTERIP_PROBE_SAMPLES:-3}"

# Prints the HTTP status (curl's -w already emits "000" on connect/timeout failure; `|| true` keeps
# set -e from aborting and avoids the double-"000" of an `|| echo 000`).
http() { curl -sS -m5 -k -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true; }

ok=0
bad=0
detail=""
for _ in $(seq 1 "$samples"); do
	cip="$(http https://10.43.0.1:443/healthz)"
	kp="$(http http://127.0.0.1:10256/healthz)"
	detail="$detail [cip=${cip:-000} kp=${kp:-000}]"
	if { [ "$cip" = 401 ] || [ "$cip" = 200 ]; } && [ "$kp" = 200 ]; then
		ok=$((ok + 1))
	else
		bad=$((bad + 1))
	fi
	sleep 1
done

if [ "$bad" -eq 0 ]; then
	echo "node-net OK ($ok/$samples healthy:$detail)"
	exit 0
fi
echo "node-net WEDGED ($bad/$samples failed:$detail — ClusterIP DNAT missing and/or kube-proxy proxier unhealthy)"
exit 1
