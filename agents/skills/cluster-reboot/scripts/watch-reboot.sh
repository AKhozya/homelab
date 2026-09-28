#!/usr/bin/env bash
# watch-reboot.sh — agent-side, no-sudo monitor for a triggered cluster rolling reboot.
#
# Run this DURING / AFTER a user-triggered node-maintenance reboot (phase1 → phase2).
# It does NOT trigger or remediate anything — read-only verdicts + remediation one-liners only.
#
# What it watches each iteration, for all 4 nodes (CP + 3 workers, immich-vm included):
#   1. Node.Ready    — kubectl Ready condition (kubelet-level health).
#   2. ClusterIP DNAT — verify-clusterip.sh <host> (worker kube-proxy wedge surface, 10.43.0.1:443).
#   3. CP loopback LB — gmk-k3s-control-plane ONLY: 127.0.0.1:6443/healthz (CP-only surface that
#                       verify-clusterip.sh does NOT cover; wedged → embedded controllers stall silently).
#   4. phase2-pending — /var/lib/node-maintenance/phase2-pending on the CP (maintenance in flight).
#   5. kube-dns ready — CoreDNS ready-endpoint count via kubectl (no sudo). 0 ready = pod-network
#                       wedged. Catches the CNI-HOSTPORT-MASQ masquerade wedge (2026-05-30) that
#                       host-netns ClusterIP + :10256 BOTH pass through — see verify-clusterip.sh blind spot.
#   6. pkg-upgrade    — node_pkg_upgrade_success per node via VMSingle. The worker yay is rescue-wrapped,
#                       so an unpatched node exits the run looking healthy on every surface above.
#   7. pod-health     — _shared/pod-health.sh --count baseline (warn-only, never gates exit).
#
# A node can report Ready while ClusterIP, the CP loopback, OR pod→ClusterIP/DNS is wedged — that is
# the entire reason this skill exists (2026-05-24 / 2026-05-25 / 2026-05-30 incidents). On such a
# state we print the sanctioned remediation; we never run it (no sudo).
#
# Exit 0 ONLY when: all 4 nodes Ready + ClusterIP-healthy, CP loopback healthy, phase2-pending absent,
# the package upgrade VERIFIED clean on every reporting node (unverifiable counts as failure — exit-0
# asserts "packages upgraded"), AND the phase1/phase2 reboot run is idle (NOT
# mid-rollout). The phase-run check is essential because
# phase2-pending reads `absent` during the phase1→phase2 gap, so without it a snapshot in that window
# would falsely report COMPLETE while workers are still being rolled (2026-05-25).
# Otherwise: with --once exit 1; in loop mode keep polling until the deadline, then exit 1.
#
# Usage: watch-reboot.sh [--once] [--interval SEC] [--max-iter N]
#   --once         single snapshot, then exit (0 healthy / 1 not-yet/wedged).
#   --interval SEC poll interval, default 30.
#   --max-iter N   max iterations before giving up, default 60 (~30 min at 30s).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$SCRIPT_DIR/verify-clusterip.sh"
POD_HEALTH="$HOME/.agents/skills/_shared/pod-health.sh"

CP="gmk-k3s-control-plane"
WORKERS=("worker-node" "worker-node-2" "immich-vm")
ALL_NODES=("$CP" "${WORKERS[@]}")

ONCE=0
INTERVAL=30
MAX_ITER=60

while [ $# -gt 0 ]; do
  case "$1" in
  --once) ONCE=1 ;;
  --interval)
    INTERVAL="${2:?--interval needs a value}"
    shift
    ;;
  --max-iter)
    MAX_ITER="${2:?--max-iter needs a value}"
    shift
    ;;
  *)
    echo "watch-reboot.sh: unknown arg '$1'" >&2
    echo "usage: watch-reboot.sh [--once] [--interval SEC] [--max-iter N]" >&2
    exit 2
    ;;
  esac
  shift
done

# Node.Ready condition via kubectl. Echoes True/False/Unknown (Unknown on any failure).
node_ready() {
  local h="$1" status
  status="$(kubectl get node "$h" \
    -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' \
    2>/dev/null)" || status=""
  echo "${status:-Unknown}"
}

# CP loopback loadbalancer probe (127.0.0.1:6443 ON the CP). 401/200 = healthy.
# This is the CP-only surface verify-clusterip.sh deliberately skips. Returns 0 ok / 1 wedged.
cp_loopback_ok() {
  local code rc=0
  # Single-quoted: $code / $(...) expand on the REMOTE CP, not here.
  # `|| true`, not `|| echo 000`: curl already prints "000" on failure, and the exit stays 0 so
  # that only an ssh failure sets rc.
  # shellcheck disable=SC2016
  code="$(ssh -o ConnectTimeout=5 "$CP" \
    'curl -sS -m5 -k -o /dev/null -w "%{http_code}" https://127.0.0.1:6443/healthz 2>/dev/null || true' \
    2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "WEDGED-OR-UNREACHABLE (ssh rc=$rc)"
    return 1
  fi
  case "$code" in
  401 | 200)
    echo "OK (healthz=$code)"
    return 0
    ;;
  *)
    echo "WEDGED (healthz=${code:-000})"
    return 1
    ;;
  esac
}

# phase2-pending interlock. test -e on that path needs no sudo. Echoes present/absent/unknown.
phase2_pending_state() {
  local out rc=0
  # Distinguish genuinely-absent from can't-traverse: at HOME 0750 the human account can't
  # search the dir → `[ -e flag ]` false-negatives to "absent" (masked a stuck flag 2026-06-20,
  # fixed by HOME 0751). `[ -x dir ]` proves traversal — no flag + traversable = truly absent;
  # no flag + not-traversable = unknown (do NOT trust "absent").
  out="$(ssh -o ConnectTimeout=5 "$CP" \
    'd=/var/lib/node-maintenance; if [ -e "$d/phase2-pending" ]; then echo present; elif [ -x "$d" ]; then echo absent; else echo unknown; fi' \
    2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "unknown"
    return 0
  fi
  echo "$out"
}

# Reboot-run interlock. phase1/phase2 service `activating` = the rolling reboot is still in
# progress — the worker rolls happen INSIDE phase2 even while phase2-pending reads `absent` (the
# phase1→phase2 gap). Without this, "phase2-pending absent + nodes healthy" falsely reads COMPLETE
# in that gap (2026-05-25). Echoes running/idle/unknown (unknown = CP unreachable).
phase_run_state() {
  local out rc=0
  out="$(ssh -o ConnectTimeout=5 "$CP" \
    'systemctl is-active node-maintenance-phase1.service node-maintenance-phase2.service 2>/dev/null | paste -sd, -' \
    2>/dev/null)" || rc=$?
  [ "$rc" -ne 0 ] && {
    echo "unknown"
    return 0
  }
  case "$out" in
  *activating*) echo "running" ;;
  *) echo "idle" ;;
  esac
}

# Why this metric exists at all: the worker/VM `yay` call sites are deliberately best-effort (a hard
# failure there strands phase2-pending and gates drift-heal cluster-wide, 2026-06-20), so a node
# whose upgrade failed exits the run with phase2 reporting success. Ready + ClusterIP + loopback +
# DNS ALL pass on an unpatched node. The GPU-VM play's rescue does fire a Telegram warning, but the
# worker play's does not and Telegram is transient anyway (missed 2026-07-11, 2026-07-18), so
# node_pkg_upgrade_success is the only durable, latching signal. 2026-08-01: phase2 completed clean
# and this script exited 0 while worker-node and worker-node-2 both sat on a failed AUR upgrade.
#
# Runs one query, echoes raw JSON. Empty output = could not query.
vm_query() {
  local pod="$1" enc
  # @uri-encode: the PromQL below carries {, }, ", ~, = and spaces, which wget will not send raw.
  enc="$(jq -rn --arg q "$2" '$q|@uri' 2>/dev/null)" || return 0
  kubectl -n monitoring exec "$pod" -- \
    wget -qO- "http://127.0.0.1:8429/prometheus/api/v1/query?query=$enc" 2>/dev/null || true
}

# Sets PKG_FAILED to: a space-separated list of failing instances, "" if every node reported OK, or
# "unavailable" when the state could not be established. On "unavailable" PKG_DETAIL carries the
# reason for the operator.
#
# Fails CLOSED on everything it cannot fully account for, because each of these otherwise renders as
# an empty failure list — byte-identical to "every node is fine":
#   - non-success status, empty body, or jq erroring (the trailing || catches the last one; set -e
#     cannot be relied on because snapshot() is invoked as an `if` condition, where -e is suppressed)
#   - .data.result not an array, or an entry with no usable .metric.instance, or duplicate instances
#   - any value that is not exactly "0" or "1"
#   - a node-exporter target that is UP but has NO package metric at all
#
# That last one is the subtle one and it is NOT covered by alerting: NodePackageUpgradeFailed is
# `node_pkg_upgrade_success == 0` (vmrules.yaml), which a MISSING series can never satisfy, and the
# scrape-down alerts stay green because node-exporter itself is healthy — only the textfile is gone.
# So absence is checked here, against the live node-exporter target set rather than a hardcoded
# count (this script must not bake in a fleet size; immich-vm joined 2026-07-10 and would have
# invalidated one).
# Sets PKG_FAILED and PKG_DETAIL; returns nothing on stdout. It must NOT be called via command
# substitution — that runs it in a subshell and both globals are discarded in the parent.
PKG_FAILED=""
PKG_DETAIL=""
pkg_upgrade_failures() {
  local vmpod out parsed node_ips have_ips missing ip
  PKG_FAILED=""
  PKG_DETAIL=""
  vmpod="$(kubectl -n monitoring get pod -l app.kubernetes.io/name=vmsingle \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || true
  [ -n "$vmpod" ] || {
    PKG_DETAIL="no vmsingle pod found"
    PKG_FAILED="unavailable"
    return 0
  }

  # The cluster's Node list is the inventory this check compares against, NOT `up`. A metrics-derived
  # inventory cannot detect the case it most needs to: if a node-exporter target disappears from
  # service discovery, it has no `up` series either, so it is absent from both sides of any
  # `up`-based absence query and reads as "nothing missing". kubectl is the authoritative source and
  # stays correct as nodes join or leave — no fleet size is hardcoded anywhere.
  node_ips="$(kubectl get nodes \
    -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
    2>/dev/null)" || true
  [ -n "$node_ips" ] || {
    PKG_DETAIL="could not list cluster nodes for the coverage check"
    PKG_FAILED="unavailable"
    return 0
  }

  # Exporter reporting DOWN: its package metric may still resolve from cache inside the lookbehind
  # window, so the value we would read is stale. Treat stale as unverified.
  out="$(vm_query "$vmpod" 'up{job=~".*node-exporter.*"} == 0')"
  [ -n "$out" ] || {
    PKG_DETAIL="exporter-down query returned nothing"
    PKG_FAILED="unavailable"
    return 0
  }
  # Decide on the RESULT COUNT, never on the joined instance string: an entry whose instance label is
  # an empty string joins to "" and would read as "no gaps". jq's // only substitutes null/false, so
  # it does not rescue "" either.
  parsed="$(printf '%s' "$out" | jq -r '
    if .status != "success" or (.data.result | type) != "array" then "BADQUERY"
    elif (.data.result | length) == 0 then "OK"
    else "GAP " + ([.data.result[] | if (.metric.instance | type) == "string" and .metric.instance != "" then .metric.instance else "<no-instance-label>" end] | join(" "))
    end' 2>/dev/null)" || parsed="BADQUERY"
  case "$parsed" in
  OK) ;;
  GAP\ *)
    PKG_DETAIL="node-exporter DOWN on: ${parsed#GAP } (package metric would be stale)"
    PKG_FAILED="unavailable"
    return 0
    ;;
  *)
    PKG_DETAIL="exporter-down query malformed"
    PKG_FAILED="unavailable"
    return 0
    ;;
  esac

  out="$(vm_query "$vmpod" 'node_pkg_upgrade_success')"
  [ -n "$out" ] || {
    PKG_DETAIL="package-metric query returned nothing"
    PKG_FAILED="unavailable"
    return 0
  }
  parsed="$(printf '%s' "$out" | jq -r '
    def instances: [.data.result[].metric.instance];
    if .status != "success" then "BAD:status"
    elif (.data.result | type) != "array" then "BAD:result-not-array"
    elif (.data.result | length) == 0 then "BAD:no-series"
    elif any(.data.result[]; (.metric.instance | type) != "string" or (.metric.instance == "")) then "BAD:no-instance-label"
    elif (instances | length) != (instances | unique | length) then "BAD:duplicate-instances"
    elif any(.data.result[]; (.value[1] == "0" or .value[1] == "1") | not) then "BAD:non-binary-value"
    else [.data.result[] | select(.value[1] == "0") | .metric.instance] | join(" ")
    end' 2>/dev/null)" || parsed="BAD:jq-failed"
  case "$parsed" in
  BAD:*)
    PKG_DETAIL="package metric ${parsed#BAD:}"
    PKG_FAILED="unavailable"
    return 0
    ;;
  esac

  # Every cluster Node must appear in the metric. Compare on the IP half of instance ("IP:port") so
  # the exporter's port number is not baked in here.
  have_ips="$(printf '%s' "$out" | jq -r '[.data.result[].metric.instance | split(":")[0]] | join("\n")' 2>/dev/null)" || have_ips=""
  missing=""
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    printf '%s\n' "$have_ips" | grep -qxF "$ip" || missing="$missing $ip"
  done <<<"$node_ips"
  [ -z "$missing" ] || {
    PKG_DETAIL="cluster nodes absent from the package metric:$missing"
    PKG_FAILED="unavailable"
    return 0
  }

  PKG_FAILED="$parsed"
}

# One full snapshot. Returns 0 iff fully healthy + idle, 1 otherwise.
snapshot() {
  local healthy=1
  echo "=== cluster-reboot watch @ $(date '+%Y-%m-%d %H:%M:%S') ==="

  # phase2-pending interlock.
  local pending
  pending="$(phase2_pending_state)"
  echo "phase2-pending: $pending"
  if [ "$pending" != "absent" ]; then
    # present → run in flight; unknown → best-effort, don't claim healthy.
    healthy=0
  fi

  # Reboot-run interlock — guards the phase1→phase2 gap where phase2-pending reads absent but
  # the worker rollout is still running inside phase2 (else we'd falsely report COMPLETE).
  local phase_run
  phase_run="$(phase_run_state)"
  echo "phase run-state: $phase_run"
  if [ "$phase_run" != "idle" ]; then
    healthy=0
  fi

  local h ready cip_rc
  for h in "${ALL_NODES[@]}"; do
    ready="$(node_ready "$h")"
    cip_rc=0
    # verify-clusterip.sh prints its own one-line verdict on stdout/stderr.
    bash "$VERIFY" "$h" || cip_rc=$?
    echo "  node $h: Ready=$ready  (clusterip exit=$cip_rc)"

    if [ "$ready" != "True" ]; then
      healthy=0
    fi
    # CP host-netns 10.43.0.1 probe is unreliable — reads wedged while the cluster is healthy
    # (documented quirk; verify-clusterip.sh is "meaningful on WORKERS"). The CP's real API-role
    # ClusterIP health is the loopback-LB + kube-dns checks below — so gate the verdict on WORKER
    # clusterips only and print the CP's as advisory. Else exit-0 false-negatives on every CP quirk
    # (cost real manual disambiguation via :10256 throughout 2026-06-20).
    # CAVEAT (2026-06-29): this host-netns advisory does NOT see a CP POD-NETNS ClusterIP wedge — a
    # CP-pinned pod (e.g. uptime-kuma) can be EAI_AGAIN-dead on every ClusterIP while host + workers
    # are fine. The clusterip_heal_cp watchdog (its own nsenter pod-netns probe) auto-heals that; if a
    # CP-pinned pod is unhealthy post-reboot, check the node_clusterip_heal_* metric — don't dismiss this.
    if [ "$cip_rc" -ne 0 ]; then
      if [ "$h" = "$CP" ]; then
        echo "    (CP clusterip advisory — host-netns quirk for the CP API role; gated by loopback LB + kube-dns. NB: does NOT cover a CP pod-netns wedge — if a CP-pinned pod is unhealthy, check the clusterip_heal_cp metric.)"
      else
        healthy=0
      fi
    fi

    # Ready-but-wedged worker → sanctioned remediation (we never run it).
    if [ "$ready" = "True" ] && [ "$cip_rc" -eq 1 ]; then
      case "$h" in
      worker-node | worker-node-2 | immich-vm)
        if [ "$phase_run" = "running" ]; then
          echo "    (reboot run ACTIVE — do NOT restart k3s-agent manually: phase2 gates each worker on its reboot, and transient ClusterIP flaps during post-reboot churn settle as the run finishes. Wait for completion.)"
        else
          echo "    REMEDIATE: ssh -t $h \"sudo systemctl restart k3s-agent\""
          echo "    (multi-node wedge → use sanctioned playbook rolling-restart-k3s.yml instead)"
        fi
        ;;
      esac
    fi

    # Worker UNREACHABLE (ssh transport failed) during a reboot run → it is either still
    # rebooting OR wedged in LATE systemd-shutdown (final unmount/reboot() stuck; kernel alive
    # but sshd already gone, so it looks "dead"). The HW watchdog (RebootWatchdogSec=2min on
    # these nodes) force-resets a hung reboot — do NOT power-cycle before that window elapses.
    # 2026-06-20: worker-node hung exactly here and was power-cycled at <2min. See
    # reference-incidents.md.
    if [ "$cip_rc" -eq 3 ] && [ "$ready" != "True" ]; then
      case "$h" in
      worker-node | worker-node-2)
        if [ "$phase_run" = "running" ]; then
          echo "    (worker UNREACHABLE mid reboot-run — still rebooting OR wedged in late shutdown."
          echo "     HW watchdog RebootWatchdogSec=2min self-resets a hang; WAIT ~4min (2min watchdog"
          echo "     + ~2min boot) from when it went silent before any manual power-cycle. Still down"
          echo "     at ~5min = watchdog did NOT fire (hardware) → manual reset warranted.)"
        fi
        ;;
      esac
    fi
  done

  # CP loopback LB (CP-only surface verify-clusterip skips).
  local cp_lb cp_lb_rc=0
  cp_lb="$(cp_loopback_ok)" || cp_lb_rc=$?
  echo "  CP loopback 127.0.0.1:6443: $cp_lb"
  if [ "$cp_lb_rc" -ne 0 ]; then
    healthy=0
    if [ "$(node_ready "$CP")" = "True" ]; then
      if [ "$phase_run" = "running" ]; then
        echo "    (reboot run ACTIVE — do NOT reboot the CP manually; let phase2 finish, then re-check.)"
      else
        echo "    REMEDIATE: ssh -t $CP \"sudo reboot\""
        echo "    (CP loopback wedge → reboot the CP; do NOT 'restart k3s' on the CP — it HANGS)"
      fi
    fi
  fi

  # Pod-network wedge symptom — the CNI-HOSTPORT-MASQ masquerade wedge (2026-05-30) that the
  # host-netns ClusterIP probe + kube-proxy :10256 BOTH pass through (verify-clusterip.sh is
  # structurally BLIND to it: host OUTPUT→ClusterIP works while pod→ClusterIP/DNS is dead). The
  # observable tell, no-sudo: cluster DNS is down. Count READY kube-dns (CoreDNS) endpoints. 0
  # ready while nodes are Ready = pod-network wedged (root cause: ufw-heal flush-all deletes
  # -j CNI-HOSTPORT-MASQ; portmap not a daemon, k8s#93091). Auto-healed by the phase2 nat-jump
  # gate + ufw-heal phase-G; flagged here so a snapshot can't read COMPLETE during it.
  local dns_ready
  dns_ready="$(kubectl get endpoints kube-dns -n kube-system \
    -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null | grep -c . || true)"
  echo "  kube-dns ready endpoints: ${dns_ready:-0}"
  if [ "${dns_ready:-0}" -lt 1 ]; then
    healthy=0
    echo "    WEDGE SYMPTOM: 0 ready CoreDNS endpoints — pod-network/DNS down. host-netns ClusterIP"
    echo "    probes are BLIND to this (CNI-HOSTPORT-MASQ masquerade wedge). If a worker is"
    echo "    Ready-but-wedged: ssh -t <worker> \"sudo systemctl restart k3s-agent\"  (an ~/.ssh/config Host; it carries user + port)"
  fi

  # Did the packages actually move? Gates the verdict — an unpatched node is a failed run even
  # though every network surface above is green.
  # Called bare, NOT as "$(pkg_upgrade_failures)" — command substitution forks a subshell and the
  # PKG_FAILED/PKG_DETAIL it sets would never reach here.
  pkg_upgrade_failures
  case "$PKG_FAILED" in
  unavailable)
    # Fail closed. An unverifiable patch state must not produce a positive attestation — exit-0
    # asserts "packages upgraded", and we cannot back that claim here. The loop is bounded, so this
    # blocks a false green without deadlocking. Causes: VMSingle down/rescheduling, kubectl exec or
    # wget failing, jq missing, or a malformed/empty query response.
    healthy=0
    echo "  pkg-upgrade: UNVERIFIED — patch state UNKNOWN, not a pass (${PKG_DETAIL:-no detail})"
    ;;
  "")
    echo "  pkg-upgrade: OK (all nodes)"
    ;;
  *)
    healthy=0
    echo "  pkg-upgrade: FAILED on $PKG_FAILED"
    echo "    Node(s) left UNPATCHED — phase2's rescue swallows this, so the run still reported success."
    echo "    Log: ssh -p 65300 $CP \"sudo grep -iE 'validity check|Failed to install' \\"
    echo "         /var/log/node-maintenance/phase2-\$(date -u +%d-%m-%Y).log\""
    echo "    A stale AUR source tarball shadowing a corrected upstream checksum is one cause"
    echo "    (2026-08-01, flux-bin) — see reference-incidents.md."
    ;;
  esac

  # Pod-health baseline — warn-only, never gates the exit verdict.
  local ph
  ph="$(bash "$POD_HEALTH" --count 2>/dev/null)" || ph="unavailable"
  echo "  pod-health (warn-only): $ph"

  [ "$healthy" -eq 1 ]
}

if [ "$ONCE" -eq 1 ]; then
  if snapshot; then
    echo "RESULT: all nodes Ready + ClusterIP-healthy, CP loopback OK, packages upgraded, phase2-pending absent, reboot run idle."
    exit 0
  fi
  echo "RESULT: not-yet-healthy (see verdicts above)."
  exit 1
fi

iter=0
while [ "$iter" -lt "$MAX_ITER" ]; do
  iter=$((iter + 1))
  echo "--- iteration $iter/$MAX_ITER ---"
  if snapshot; then
    echo "RESULT: healthy after $iter iteration(s)."
    exit 0
  fi
  if [ "$iter" -lt "$MAX_ITER" ]; then
    sleep "$INTERVAL"
  fi
done

echo "RESULT: gave up after $MAX_ITER iterations (~$((MAX_ITER * INTERVAL / 60)) min) — still not healthy." >&2
exit 1
