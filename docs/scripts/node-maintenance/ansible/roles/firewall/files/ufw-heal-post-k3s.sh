#!/bin/bash
# ufw-heal-post-k3s.sh
# Heals UFW state when K3s (kube-proxy + flannel) + fail2ban race-mutate
# kernel netfilter state against UFW's iptables-restore.
#
# Context: on Arch + iptables-nft, UFW's reload calls iptables-restore which
# loads tables sequentially. Concurrent netlink writes from kube-proxy/flannel
# can interrupt the restore, leaving some UFW chains (typically
# ufw6-logging-deny, ufw6-user-*) missing in kernel even though declared in
# /etc/ufw/before6.rules / user6.rules. Symptom: `ufw status verbose` returns
# "ERROR: problem running ip6tables" → wedged half-state.
#
# Sequence (revised 2026-04-28):
#   A. Settle wait — nft monitor + iptables-save sha256 stability (3x 5s
#      consecutive identical windows). Max 90s.
#   C. Per-chain repair FIRST — single-syscall `iptables -N` is race-free,
#      gives reload a clean skeleton to restore over
#   B. ufw reload (up to 3 attempts, 10s gap)
#   E. Final reload
#   D. Verify probe set — v4 + v6 canary chains
#   F. Status check (authoritative)
#
# Never exits non-zero from Phase A timeout — boot must proceed.
# Exits non-zero only from Phase F status-check fail → systemd marks service
# failed → alerts fire.

set -uo pipefail

LOG_TAG="ufw-heal"
UFW_BIN="/usr/sbin/ufw"
IPTABLES="/usr/sbin/iptables"
IP6TABLES="/usr/sbin/ip6tables"
IPTABLES_SAVE="/usr/sbin/iptables-save"
IP6TABLES_SAVE="/usr/sbin/ip6tables-save"
NFT_BIN="/usr/sbin/nft"

PROBE_CHAINS_V4=(ufw-logging-deny ufw-user-input)
PROBE_CHAINS_V6=(ufw6-logging-deny ufw6-user-input)

# Phase A tunables
SETTLE_MAX_SEC=90
SETTLE_WINDOW_SEC=5
SETTLE_STABLE_WINDOWS=3

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

# Compute hash of UFW-managed chains only (ignore kube-router/kube-proxy churn).
# UFW chains start with `ufw-` or `ufw6-` — both chain declarations (`:ufw-...`)
# and rules (`-A ufw-...`). Workers always churn iptables for pod network
# reconciliation, so full-ruleset hash never stabilises; ufw-only hash does.
ufw_chains_hash() {
    {
        "$IPTABLES_SAVE" 2>/dev/null | grep -E '^:ufw-|^-A ufw-' || true
        "$IP6TABLES_SAVE" 2>/dev/null | grep -E '^:ufw6-|^-A ufw6-' || true
    } | sha256sum | awk '{print $1}'
}

# Phase A — wait for UFW chain stability across N consecutive windows.
# nft monitor logged for diagnostics but NOT gating (kube-* always churns it).
# Hash gate is on ufw chains only: rules we control + chains UFW manages.
# Falls through on timeout — never blocks heal.
phase_a_settle() {
    log "phase-a: waiting for ufw-chain stability (max ${SETTLE_MAX_SEC}s, ${SETTLE_WINDOW_SEC}s windows, ${SETTLE_STABLE_WINDOWS}× stable)"

    local nft_available=1
    if ! "$NFT_BIN" list ruleset >/dev/null 2>&1; then
        nft_available=0
    fi

    local deadline=$(( $(date +%s) + SETTLE_MAX_SEC ))
    local prev_hash=""
    local stable=0

    while [ "$(date +%s)" -lt "$deadline" ]; do
        local events=0
        if [ "$nft_available" -eq 1 ]; then
            events=$(timeout "$SETTLE_WINDOW_SEC" "$NFT_BIN" monitor 2>/dev/null | wc -l)
        else
            sleep "$SETTLE_WINDOW_SEC"
        fi

        local curr_hash
        curr_hash=$(ufw_chains_hash)

        if [ -n "$curr_hash" ] && [ "$curr_hash" = "$prev_hash" ]; then
            stable=$((stable + 1))
            log "phase-a: stable ${stable}/${SETTLE_STABLE_WINDOWS} (nft_events=$events, ufw_hash=${curr_hash:0:12})"
            if [ "$stable" -ge "$SETTLE_STABLE_WINDOWS" ]; then
                log "phase-a: settled"
                return 0
            fi
        else
            stable=0
            prev_hash="$curr_hash"
        fi
    done

    log "phase-a: timeout — proceeding anyway (last_stable=$stable/$SETTLE_STABLE_WINDOWS)"
    return 0
}

# Phase C — per-chain repair (race-free: individual iptables -N calls).
# Run BEFORE ufw reload so iptables-restore has all declared chains pre-created.
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

# Phase B — ufw reload with retries (after chains pre-created)
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

# Phase E — final reload attempt
phase_e_final_reload() {
    log "phase-e: final ufw reload"
    if "$UFW_BIN" reload >/dev/null 2>&1; then
        log "phase-e: final reload succeeded"
        return 0
    fi
    log "phase-e: final reload failed"
    return 1
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
    phase_c_repair
    phase_b_reload || true
    phase_e_final_reload || true
    phase_d_verify || log "WARN: probe set still unhealthy after repair"
    phase_f_status
}

main "$@"
