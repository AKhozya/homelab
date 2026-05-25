#!/usr/bin/env bash
# clusterip-probe.sh — verify k3s ClusterIP DNAT works from this node's host netns.
# Runs ON a node (host netns), no sudo, no args. Targets the WORKER kube-proxy wedge surface
# (2026-05-24): node kubelet-Ready but KUBE-SERVICES DNAT for 10.43.0.1 missing → pods crashloop
# on connection refused/timeout. The apiserver /healthz returns 401 unauthenticated when routed.
# Exit 0 = healthy (DNAT routed), 1 = wedged.
#
# Scope note: the CP control-plane reachability surface is DIFFERENT — k3s components dial the
# loopback loadbalancer (CP: 127.0.0.1:6443, workers: 127.0.0.1:6444). That wedge (2026-05-25) is
# gated separately + CP-only in phase2 PLAY 0 / watch-reboot, NOT here. host-netns 10.43.0.1 can
# also read 000 on the CP even when pod-netns is fine, so this probe is meaningful on workers.
#
# NOTE: this curl/`401|200` probe logic is duplicated in verify-clusterip.sh (over-SSH variant)
# — keep the two in sync if either is changed.
set -euo pipefail
# `|| code=000` (NOT `|| echo 000` inside the $()) avoids doubling curl's own "000" timeout output.
code="$(curl -sS -m5 -k -o /dev/null -w '%{http_code}' https://10.43.0.1:443/healthz 2>/dev/null)" || code=000
case "$code" in
401 | 200)
	echo "clusterip OK (api healthz=$code)"
	exit 0
	;;
*)
	echo "clusterip WEDGED (api healthz=$code — DNAT missing/blackholed)"
	exit 1
	;;
esac
