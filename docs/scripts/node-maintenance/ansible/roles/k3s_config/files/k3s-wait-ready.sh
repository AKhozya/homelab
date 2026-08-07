#!/bin/bash
# k3s-wait-ready.sh
# Wait until K3s is truly ready, then touch /run/k3s-ready sentinel.
#
# "Truly ready" means:
#   - (CP only) API server returns /healthz OK
#   - (CP only) coredns pods Ready
#   - All nodes: ufw-chain sha256 stable across 3× 5s windows
#
# Why: systemd `After=k3s.service` only guarantees k3s.service STARTED, not
# that K3s/kube-router/kube-proxy have finished writing iptables rules.
# Downstream services (ufw-heal-post-k3s) race against in-flight rule writes
# without this barrier.
#
# Always touches the sentinel even on partial failure — boot must proceed.
# Downstream services use ConditionPathExists=/run/k3s-ready to gate.
#
# Tunables (env):
#   K3S_READY_TIMEOUT         total budget seconds (default 300)
#   K3S_READY_API_TIMEOUT     phase-1 budget (default 90)
#   K3S_READY_PODS_TIMEOUT    phase-2 budget (default 60)
#   K3S_READY_SETTLE_TIMEOUT  phase-3 budget (default 120)

set -uo pipefail

SENTINEL=/run/k3s-ready
TIMEOUT_SEC=${K3S_READY_TIMEOUT:-300}
# Per-phase budgets. They must sum to less than TIMEOUT_SEC so a phase that times out
# still leaves the phases after it a window — see phase_deadline().
API_TIMEOUT_SEC=${K3S_READY_API_TIMEOUT:-90}
PODS_TIMEOUT_SEC=${K3S_READY_PODS_TIMEOUT:-60}
SETTLE_TIMEOUT_SEC=${K3S_READY_SETTLE_TIMEOUT:-120}
GLOBAL_DEADLINE=0
# Pod selectors phase 2 waits on. coredns proves the DNS path works. kube-router is NOT here:
# K3s runs it inside the k3s process, so `k8s-app=kube-router` matches zero pods and the wait
# could only ever time out.
CRITICAL_POD_LABELS=("k8s-app=kube-dns")
KUBECONFIG_PATH=/etc/rancher/k3s/k3s.yaml
K3S_BIN=/usr/local/bin/k3s
IPTABLES_SAVE=/usr/sbin/iptables-save
IP6TABLES_SAVE=/usr/sbin/ip6tables-save
LOG_TAG=k3s-wait-ready

log() {
    logger -t "$LOG_TAG" -- "$*"
    echo "[$LOG_TAG] $*" >&2
}

# Deadline for one phase: its own budget, never past the global deadline. Each phase gets a
# private budget because they used to share one — on 2026-08-07 the CP's phase-2 selector
# matched nothing, burned all 300s, and phase 3 (the ufw settle this barrier exists for) ran
# with an already-expired deadline and never took a single sample.
phase_deadline() {
    local budget=$1 d
    d=$(( $(date +%s) + budget ))
    [ "$d" -gt "$GLOBAL_DEADLINE" ] && d=$GLOBAL_DEADLINE
    echo "$d"
}

is_control_plane() {
    [ -f "$KUBECONFIG_PATH" ] && [ -x "$K3S_BIN" ]
}

kubectl_cmd() {
    KUBECONFIG="$KUBECONFIG_PATH" "$K3S_BIN" kubectl "$@"
}

# Phase 1 — wait for K3s API /healthz (CP only)
wait_api() {
    local deadline=$1
    log "api: waiting for /healthz"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if kubectl_cmd get --raw='/healthz' >/dev/null 2>&1; then
            log "api: ready"
            return 0
        fi
        sleep 2
    done
    log "api: timeout"
    return 1
}

# Phase 2 — wait for critical kube-system pods Ready (CP only)
wait_critical_pods() {
    local deadline=$1
    local labels=("${CRITICAL_POD_LABELS[@]}")
    log "pods: waiting for critical kube-system pods"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local all_ready=1
        for sel in "${labels[@]}"; do
            local total ready
            total=$(kubectl_cmd -n kube-system get pods -l "$sel" --no-headers 2>/dev/null | wc -l)
            if [ "$total" -eq 0 ]; then
                all_ready=0
                break
            fi
            ready=$(kubectl_cmd -n kube-system get pods -l "$sel" \
                -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
                2>/dev/null | grep -c '^True$' || true)
            if [ "$ready" -lt "$total" ]; then
                all_ready=0
                break
            fi
        done
        if [ "$all_ready" -eq 1 ]; then
            log "pods: critical pods ready"
            return 0
        fi
        sleep 3
    done
    log "pods: timeout"
    return 1
}

# Hash UFW-managed chains only — workers always churn kube-* chains, full-ruleset
# hash never stabilises (kube-router/kube-proxy reconcile pod routes continuously).
# UFW chains we control => bounded drift => meaningful stability signal.
ufw_chains_hash() {
    {
        "$IPTABLES_SAVE" 2>/dev/null | grep -E '^:ufw-|^-A ufw-' || true
        "$IP6TABLES_SAVE" 2>/dev/null | grep -E '^:ufw6-|^-A ufw6-' || true
    } | sha256sum | awk '{print $1}'
}

# Phase 3 — wait for ufw-chain hash stability (3× 5s windows of identical hash).
# Means ufw rules quiesced; kube-* churn ignored (out of our control).
wait_iptables_stable() {
    local deadline=$1
    local prev=""
    local stable=0
    log "iptables: waiting for ufw-chain stability"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local h
        h=$(ufw_chains_hash)
        if [ -n "$h" ] && [ "$h" = "$prev" ]; then
            stable=$((stable + 1))
            log "iptables: stable ${stable}/3 (ufw_hash=${h:0:12})"
            if [ "$stable" -ge 3 ]; then
                log "iptables: settled"
                return 0
            fi
        else
            stable=0
            prev=$h
        fi
        sleep 5
    done
    log "iptables: timeout (last_stable=$stable/3)"
    return 1
}

main() {
    log "starting (pid=$$, timeout=${TIMEOUT_SEC}s)"
    local start
    start=$(date +%s)
    GLOBAL_DEADLINE=$((start + TIMEOUT_SEC))

    local mode="worker"
    if is_control_plane; then
        mode="control-plane"
        wait_api "$(phase_deadline "$API_TIMEOUT_SEC")" || log "WARN: api not ready"
        wait_critical_pods "$(phase_deadline "$PODS_TIMEOUT_SEC")" || log "WARN: critical pods not ready"
    fi
    log "mode=$mode"

    wait_iptables_stable "$(phase_deadline "$SETTLE_TIMEOUT_SEC")" || log "WARN: iptables not stable"

    # Always touch sentinel — boot must proceed even on timeout.
    # Downstream services treat sentinel as "best-effort wait done", not
    # absolute readiness guarantee.
    touch "$SENTINEL"
    chmod 0644 "$SENTINEL"
    local elapsed=$(( $(date +%s) - start ))
    log "complete (elapsed=${elapsed}s, sentinel=$SENTINEL)"
}

# tests/test-wait-ready.sh sources this with K3S_WAIT_READY_LIB=1 to exercise phase_deadline
# without running the barrier.
[ "${K3S_WAIT_READY_LIB:-0}" = 1 ] || main "$@"
