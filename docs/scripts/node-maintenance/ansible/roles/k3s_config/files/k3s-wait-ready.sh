#!/bin/bash
# k3s-wait-ready.sh
# Wait until K3s is truly ready, then touch /run/k3s-ready sentinel.
#
# "Truly ready" means:
#   - (CP only) API server returns /healthz OK
#   - (CP only) Critical kube-system pods Ready (kube-router, coredns)
#   - All nodes: iptables-save sha256 stable across 3× 5s windows
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
#   K3S_READY_TIMEOUT  total budget seconds (default 180)

set -uo pipefail

SENTINEL=/run/k3s-ready
TIMEOUT_SEC=${K3S_READY_TIMEOUT:-180}
KUBECONFIG_PATH=/etc/rancher/k3s/k3s.yaml
K3S_BIN=/usr/local/bin/k3s
IPTABLES_SAVE=/usr/sbin/iptables-save
IP6TABLES_SAVE=/usr/sbin/ip6tables-save
LOG_TAG=k3s-wait-ready

log() {
    logger -t "$LOG_TAG" -- "$*"
    echo "[$LOG_TAG] $*" >&2
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
# kube-router writes iptables; coredns proves DNS path works.
wait_critical_pods() {
    local deadline=$1
    local labels=("k8s-app=kube-dns" "k8s-app=kube-router")
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
    local deadline=$((start + TIMEOUT_SEC))

    local mode="worker"
    if is_control_plane; then
        mode="control-plane"
        wait_api "$deadline" || log "WARN: api not ready"
        wait_critical_pods "$deadline" || log "WARN: critical pods not ready"
    fi
    log "mode=$mode"

    wait_iptables_stable "$deadline" || log "WARN: iptables not stable"

    # Always touch sentinel — boot must proceed even on timeout.
    # Downstream services treat sentinel as "best-effort wait done", not
    # absolute readiness guarantee.
    touch "$SENTINEL"
    chmod 0644 "$SENTINEL"
    local elapsed=$(( $(date +%s) - start ))
    log "complete (elapsed=${elapsed}s, sentinel=$SENTINEL)"
}

main "$@"
