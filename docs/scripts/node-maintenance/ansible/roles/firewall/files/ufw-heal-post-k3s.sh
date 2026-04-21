#!/bin/bash
# ufw-heal-post-k3s.sh
# Heals UFW state after K3s (+ kube-router + fail2ban) race-mutates ip6tables at boot.
#
# Context: on Arch + iptables-nft, ufw-init's ip6tables-restore can silently
# partial-load when another process (kube-router, fail2ban) concurrently mutates
# kernel nft state. Result: some ufw chains (ufw6-logging-deny, ufw6-user-*)
# missing → subsequent `ufw status verbose` returns "ERROR: problem running
# ip6tables" → UFW wedged in half-state.
#
# Sequence:
#   A. Wait for kube-router quiescence (chain exists + line count stable)
#   B. ufw reload (up to 3 attempts, 10s gap)
#   C. Per-chain repair (idempotent ip6tables -N for missing chains)
#   D. Verify probe set — v4 + v6 canary chains
#   E. Final reload
#   F. Status check
#
# Never exits non-zero from Phase A timeout — boot must proceed.
# Exits non-zero only from Phase F status-check fail → systemd marks service failed → alerts fire.

set -uo pipefail

LOG_TAG="ufw-heal"
UFW_BIN="/usr/sbin/ufw"
IPTABLES="/usr/sbin/iptables"
IP6TABLES="/usr/sbin/ip6tables"

PROBE_CHAINS_V4=(ufw-logging-deny ufw-user-input)
PROBE_CHAINS_V6=(ufw6-logging-deny ufw6-user-input)

log() {
    logger -t "$LOG_TAG" -- "$*"
    echo "[ufw-heal] $*" >&2
}

# Extract ":<chain>" declarations from UFW rules files → list of chain names
extract_chains() {
    local file="$1"
    grep -E '^:[a-zA-Z0-9_-]+' "$file" 2>/dev/null | awk -F'[: ]' '{print $2}'
}

# Idempotent chain ensure: create if missing, no-op if exists.
ensure_chain() {
    local iptables_bin="$1"
    local chain="$2"
    if "$iptables_bin" -L "$chain" -n >/dev/null 2>&1; then
        return 0
    fi
    if "$iptables_bin" -N "$chain" 2>/dev/null; then
        log "created missing chain: $iptables_bin $chain"
        return 0
    fi
    log "WARN: failed to create chain: $iptables_bin $chain"
    return 1
}

# Phase A — wait for kube-router quiescence (best-effort, never blocks boot)
phase_a_settle() {
    local deadline=$(( $(date +%s) + 120 ))
    local prev_count=-1
    local stable_samples=0

    log "phase-a: waiting for kube-router quiescence (max 120s)"

    while [ "$(date +%s)" -lt "$deadline" ]; do
        if "$IP6TABLES" -L KUBE-ROUTER-INPUT -n >/dev/null 2>&1; then
            local count
            count=$("$IP6TABLES"-save 2>/dev/null | wc -l || echo 0)
            if [ "$count" = "$prev_count" ] && [ "$count" -gt 0 ]; then
                stable_samples=$((stable_samples + 1))
                if [ "$stable_samples" -ge 2 ]; then
                    log "phase-a: settled (line_count=$count stable)"
                    return 0
                fi
            else
                stable_samples=0
            fi
            prev_count=$count
        fi
        sleep 5
    done

    log "phase-a: timeout — continuing anyway"
    return 0
}

# Phase B — ufw reload with retries
phase_b_reload() {
    for attempt in 1 2 3; do
        log "phase-b: ufw reload attempt $attempt/3"
        if "$UFW_BIN" reload >/dev/null 2>&1; then
            log "phase-b: reload succeeded (attempt $attempt)"
            return 0
        fi
        sleep 10
    done
    log "phase-b: all reload attempts failed"
    return 1
}

# Phase C — per-chain repair (race-free: individual ip6tables -N calls)
phase_c_repair() {
    log "phase-c: per-chain repair starting"

    local v4_files=(/etc/ufw/before.rules /etc/ufw/after.rules /etc/ufw/user.rules)
    local v6_files=(/etc/ufw/before6.rules /etc/ufw/after6.rules /etc/ufw/user6.rules)

    for f in "${v4_files[@]}"; do
        [ -f "$f" ] || continue
        while read -r chain; do
            [ -z "$chain" ] && continue
            ensure_chain "$IPTABLES" "$chain"
        done < <(extract_chains "$f")
    done

    for f in "${v6_files[@]}"; do
        [ -f "$f" ] || continue
        while read -r chain; do
            [ -z "$chain" ] && continue
            ensure_chain "$IP6TABLES" "$chain"
        done < <(extract_chains "$f")
    done

    log "phase-c: repair complete"
}

# Phase D — verify probe set
phase_d_verify() {
    local missing=()
    for c in "${PROBE_CHAINS_V4[@]}"; do
        "$IPTABLES" -L "$c" -n >/dev/null 2>&1 || missing+=("iptables:$c")
    done
    for c in "${PROBE_CHAINS_V6[@]}"; do
        "$IP6TABLES" -L "$c" -n >/dev/null 2>&1 || missing+=("ip6tables:$c")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        log "phase-d: probe-set UNHEALTHY — missing: ${missing[*]}"
        return 1
    fi
    log "phase-d: probe-set healthy"
    return 0
}

# Phase E — final reload attempt after repair
phase_e_final_reload() {
    log "phase-e: final ufw reload"
    if "$UFW_BIN" reload >/dev/null 2>&1; then
        log "phase-e: final reload succeeded"
        return 0
    fi
    log "phase-e: final reload failed"
    return 1
}

# Phase F — status check (authoritative)
phase_f_status() {
    local status
    status=$("$UFW_BIN" status 2>&1 || true)
    if echo "$status" | grep -qi "Status: active"; then
        log "phase-f: ufw active — heal OK"
        return 0
    fi
    if echo "$status" | grep -qiE "inactive|not enabled"; then
        log "phase-f: ufw inactive (expected if ENABLED=no) — exiting clean"
        return 0
    fi
    log "phase-f: ufw unhealthy: $status"
    return 1
}

main() {
    log "starting heal sequence (pid=$$)"

    phase_a_settle
    phase_b_reload || true
    phase_c_repair
    phase_e_final_reload || true
    phase_d_verify || log "WARN: probe set still unhealthy after repair"
    phase_f_status
}

main "$@"
