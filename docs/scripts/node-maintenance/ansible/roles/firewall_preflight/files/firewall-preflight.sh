#!/bin/bash
# firewall-preflight.sh
# Settle barrier + per-chain repair, run BEFORE any community.general.ufw or
# /usr/sbin/ufw call from ansible during drift-heal.
#
# Why this exists separately from firewall role's pre-heal:
#   - The firewall role's pre-heal runs INSIDE the firewall role tasks. If a
#     prior role (or earlier task in the same play) calls community.general.ufw
#     directly or indirectly, it can fail before the pre-heal runs.
#   - This script is invoked by the firewall_preflight role which runs first
#     in the playbook, providing a settle barrier for the whole play.
#
# Sequence:
#   1. Settle: nft monitor + iptables-save sha256 stability (3× 5s windows)
#   2. Modprobe expanded netfilter module set
#   3. Per-chain repair (idempotent iptables -N)
#
# Always exits 0 — preflight is best-effort. Hard failures surface in
# subsequent ufw tasks.

set -uo pipefail

LOG_TAG="firewall-preflight"
IPTABLES=/usr/sbin/iptables
IP6TABLES=/usr/sbin/ip6tables
IPTABLES_SAVE=/usr/sbin/iptables-save
IP6TABLES_SAVE=/usr/sbin/ip6tables-save
NFT_BIN=/usr/sbin/nft

SETTLE_MAX_SEC=${SETTLE_MAX_SEC:-60}
SETTLE_WINDOW_SEC=${SETTLE_WINDOW_SEC:-5}
SETTLE_STABLE_WINDOWS=${SETTLE_STABLE_WINDOWS:-3}

MODULES=(
    ip6_tables
    ip6table_filter
    ip6table_nat
    ip6table_mangle
    ip6table_raw
    iptable_filter
    iptable_nat
    iptable_mangle
    iptable_raw
    nf_conntrack
)

log() {
    logger -t "$LOG_TAG" -- "$*"
    echo "[$LOG_TAG] $*" >&2
}

# Phase 1: settle wait
phase_settle() {
    log "settle: max=${SETTLE_MAX_SEC}s window=${SETTLE_WINDOW_SEC}s stable=${SETTLE_STABLE_WINDOWS}"
    local nft_available=1
    if ! "$NFT_BIN" list ruleset >/dev/null 2>&1; then
        nft_available=0
        log "settle: nft unavailable, hash-only mode"
    fi
    local deadline=$(( $(date +%s) + SETTLE_MAX_SEC ))
    local prev=""
    local stable=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local events=0
        if [ "$nft_available" -eq 1 ]; then
            events=$(timeout "$SETTLE_WINDOW_SEC" "$NFT_BIN" monitor 2>/dev/null | wc -l)
        else
            sleep "$SETTLE_WINDOW_SEC"
        fi
        local h
        h=$( { "$IPTABLES_SAVE" 2>/dev/null; "$IP6TABLES_SAVE" 2>/dev/null; } | sha256sum | awk '{print $1}' )
        if [ "$events" -eq 0 ] && [ -n "$h" ] && [ "$h" = "$prev" ]; then
            stable=$((stable + 1))
            if [ "$stable" -ge "$SETTLE_STABLE_WINDOWS" ]; then
                log "settle: ok"
                return 0
            fi
        else
            stable=0
            prev=$h
        fi
    done
    log "settle: timeout (proceeding)"
    return 0
}

# Phase 2: ensure netfilter modules loaded
phase_modprobe() {
    log "modprobe: ensuring ${#MODULES[@]} modules loaded"
    local loaded=0
    local failed=0
    for m in "${MODULES[@]}"; do
        if /usr/bin/modprobe "$m" 2>/dev/null; then
            loaded=$((loaded + 1))
        else
            failed=$((failed + 1))
            log "modprobe: failed $m"
        fi
    done
    log "modprobe: loaded=$loaded failed=$failed"
}

# Phase 3: per-chain repair from UFW rules files
phase_chain_repair() {
    log "chain-repair: starting"
    local repaired=0
    local v4_files=(/etc/ufw/before.rules /etc/ufw/after.rules /etc/ufw/user.rules)
    local v6_files=(/etc/ufw/before6.rules /etc/ufw/after6.rules /etc/ufw/user6.rules)
    for f in "${v4_files[@]}"; do
        [ -f "$f" ] || continue
        while read -r chain; do
            [ -z "$chain" ] && continue
            if ! "$IPTABLES" -L "$chain" -n >/dev/null 2>&1; then
                "$IPTABLES" -N "$chain" 2>/dev/null && repaired=$((repaired + 1))
            fi
        done < <(grep -E '^:[a-zA-Z0-9_-]+' "$f" 2>/dev/null | awk -F'[: ]' '{print $2}')
    done
    for f in "${v6_files[@]}"; do
        [ -f "$f" ] || continue
        while read -r chain; do
            [ -z "$chain" ] && continue
            if ! "$IP6TABLES" -L "$chain" -n >/dev/null 2>&1; then
                "$IP6TABLES" -N "$chain" 2>/dev/null && repaired=$((repaired + 1))
            fi
        done < <(grep -E '^:[a-zA-Z0-9_-]+' "$f" 2>/dev/null | awk -F'[: ]' '{print $2}')
    done
    log "chain-repair: repaired=$repaired"
}

main() {
    log "starting (pid=$$)"
    phase_settle
    phase_modprobe
    phase_chain_repair
    log "complete"
}

main "$@"
