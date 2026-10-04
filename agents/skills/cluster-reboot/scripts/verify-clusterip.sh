#!/usr/bin/env bash
# verify-clusterip.sh <ssh-config-host> — run the ClusterIP probe on a node over SSH.
# Host must be an ~/.ssh/config Host: worker-node | worker-node-2 | gmk-k3s-control-plane | immich-vm
# (NOT a zsh alias like ssh_worker_node — those aren't visible to bash). ssh_config carries
# User + Port 65300 (worker-node-2 = z3us, others = akhozya), so we pass neither here.
# Probes ClusterIP DNAT (10.43.0.1:443) — the worker kube-proxy wedge surface. The CP loopback
# loadbalancer (127.0.0.1:6443) is a SEPARATE, CP-only surface gated in phase2 PLAY 0 / watch-reboot.
# Pure verdict only, no remediation — callers own that.
# BLIND SPOT (2026-05-30): this probes from the node's HOST netns. It does NOT detect the
# CNI-HOSTPORT-MASQ masquerade wedge (ufw-heal flush-all deletes -j CNI-HOSTPORT-MASQ; portmap not
# a daemon, k8s#93091): host OUTPUT→10.43.0.1 + :10256 both PASS while pod→ClusterIP/DNS is dead.
# That surface needs a root nat check (`iptables -t nat -S POSTROUTING | grep CNI-HOSTPORT-MASQ`) —
# done in phase2's gate (root) + auto-healed by ufw-heal phase-G. watch-reboot.sh flags the symptom
# via kube-dns ready-endpoint count. Do NOT treat a green verdict here as "pod network healthy".
# Exit 0 healthy / 1 wedged / 2 bad args / 3 unreachable-or-unknown.
set -euo pipefail
host="${1:?usage: verify-clusterip.sh <worker-node|worker-node-2|gmk-k3s-control-plane|immich-vm>}"
case "$host" in
worker-node | worker-node-2 | gmk-k3s-control-plane | immich-vm) ;;
*)
  echo "verify-clusterip.sh: unknown host '$host' (use an ~/.ssh/config Host, not a zsh alias)" >&2
  exit 2
  ;;
esac
# Single-quoted on purpose: the loop / $(...) must expand on the REMOTE node, not here.
# MULTI-SAMPLE + DUAL-SIGNAL: 3 probes; each must pass BOTH ClusterIP DNAT (10.43.0.1:443 → 401|200)
# AND kube-proxy's own healthz (127.0.0.1:10256 → 200). ALL 3 must pass. The :10256 check catches the
# wedge root cause (stale-chain iptables-restore fail → proxier unhealthy) directly; multi-sample
# defeats the flap a one-shot probe would pass on a lucky reading (2026-05-25). `|| c=000`/`|| k=000`
# (not `|| echo`) avoids doubling curl's own "000" output.
# NOTE: this dual multi-sample logic is duplicated in clusterip-probe.sh — keep the two in sync.
# shellcheck disable=SC2016
probe='bad=0; for _ in 1 2 3; do c=$(curl -sS -m5 -k -o /dev/null -w "%{http_code}" https://10.43.0.1:443/healthz 2>/dev/null) || c=000; k=$(curl -sS -m5 -o /dev/null -w "%{http_code}" http://127.0.0.1:10256/healthz 2>/dev/null) || k=000; if { [ "$c" = 401 ] || [ "$c" = 200 ]; } && [ "$k" = 200 ]; then :; else bad=$((bad+1)); fi; sleep 1; done; [ "$bad" -eq 0 ]'
# OpenSSH returns 255 on its OWN connection failure; the remote command's exit
# code passes through otherwise. `|| rc=$?` keeps `set -e` from aborting here.
rc=0
ssh -o ConnectTimeout=5 "$host" "$probe" || rc=$?
case "$rc" in
0)
  echo "[$host] clusterip OK"
  exit 0
  ;;
1)
  echo "[$host] clusterip WEDGED (DNAT missing/blackholed — node up, kube-proxy not programming service rules)"
  exit 1
  ;;
255)
  echo "[$host] UNREACHABLE (ssh transport failed — host down/connect timeout/auth)" >&2
  exit 3
  ;;
*)
  echo "[$host] UNKNOWN (ssh rc=$rc)" >&2
  exit 3
  ;;
esac
