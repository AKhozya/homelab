#!/bin/bash
# firewall-preflight.sh
# Settle barrier + per-chain repair, run BEFORE any community.general.ufw or
# /usr/sbin/ufw call from ansible during drift-heal.
#
# 2026-04-29 settle-signal swap:
#   - Old signal: `nft monitor` event count. Found unreliable — emits 0 even
#     when iptables-nft compat is actively churning (kube-proxy, flannel),
#     leading to false-positive "settled" reports.
#   - New signal: `flock -n /run/xtables.lock` probe + ufw-chain hash stable
#     across N consecutive windows. Lock-free + hash-stable = real quiescence.
#
# Sequence:
#   1. Settle: xtables-lock-free + ufw-hash-stable (3× 5s windows). Max 90s.
#   2. Modprobe expanded netfilter module set
#   3. Per-chain repair (idempotent iptables -N)
#
# Always exits 0 — preflight is best-effort. Hard failures surface in
# subsequent ufw tasks. Settle outcome (ok/timeout) emitted as a metric line
# for node-exporter textfile collector.

set -uo pipefail

LOG_TAG="firewall-preflight"
IPTABLES=/usr/sbin/iptables
IP6TABLES=/usr/sbin/ip6tables
IPTABLES_SAVE=/usr/sbin/iptables-save
IP6TABLES_SAVE=/usr/sbin/ip6tables-save
NFT_BIN=/usr/sbin/nft
XTABLES_LOCK=/run/xtables.lock
METRIC_FILE=/var/lib/node_exporter/textfile/firewall_preflight.prom

SETTLE_MAX_SEC=${SETTLE_MAX_SEC:-90}
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

emit_metric() {
    # $1=settle_ok (0|1), $2=elapsed_sec, $3=stable_count, $4=lock_busy_count
    local ok=$1 elapsed=$2 stable=$3 lock_busy=$4 ts node
    ts=$(date +%s)
    node=$(hostname)
    install -d -m 0755 /var/lib/node_exporter/textfile 2>/dev/null || true
    {
        echo "# HELP firewall_preflight_settle_ok Last preflight settle: 1=stable, 0=timeout"
        echo "# TYPE firewall_preflight_settle_ok gauge"
        echo "firewall_preflight_settle_ok{node=\"${node}\"} ${ok}"
        echo "# HELP firewall_preflight_settle_elapsed_seconds Last preflight settle elapsed time"
        echo "# TYPE firewall_preflight_settle_elapsed_seconds gauge"
        echo "firewall_preflight_settle_elapsed_seconds{node=\"${node}\"} ${elapsed}"
        echo "# HELP firewall_preflight_settle_stable_windows Last preflight: consecutive stable windows reached"
        echo "# TYPE firewall_preflight_settle_stable_windows gauge"
        echo "firewall_preflight_settle_stable_windows{node=\"${node}\"} ${stable}"
        echo "# HELP firewall_preflight_xtables_lock_busy_total Last preflight: count of xtables-lock-busy probes"
        echo "# TYPE firewall_preflight_xtables_lock_busy_total gauge"
        echo "firewall_preflight_xtables_lock_busy_total{node=\"${node}\"} ${lock_busy}"
        echo "# HELP firewall_preflight_last_run_ts Last preflight run timestamp"
        echo "# TYPE firewall_preflight_last_run_ts gauge"
        echo "firewall_preflight_last_run_ts{node=\"${node}\"} ${ts}"
    } > "${METRIC_FILE}.tmp" 2>/dev/null && mv "${METRIC_FILE}.tmp" "${METRIC_FILE}" 2>/dev/null || true
}

ufw_chains_hash() {
    {
        "$IPTABLES_SAVE" 2>/dev/null | grep -E '^:ufw-|^-A ufw-' || true
        "$IP6TABLES_SAVE" 2>/dev/null | grep -E '^:ufw6-|^-A ufw6-' || true
    } | sha256sum | awk '{print $1}'
}

# Probe xtables-lock — non-blocking. Returns 0 if free, 1 if held.
xtables_lock_free() {
    [ -e "$XTABLES_LOCK" ] || return 0
    if /usr/bin/flock -n "$XTABLES_LOCK" /bin/true 2>/dev/null; then
        return 0
    fi
    return 1
}

# Phase 1: settle wait — gate on xtables-lock-free AND ufw-hash stability.
phase_settle() {
    log "settle: max=${SETTLE_MAX_SEC}s window=${SETTLE_WINDOW_SEC}s stable=${SETTLE_STABLE_WINDOWS} (signal=xtables-lock+ufw-hash)"
    local start
    start=$(date +%s)
    local deadline=$(( start + SETTLE_MAX_SEC ))
    local prev=""
    local stable=0
    local lock_busy_count=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
        sleep "$SETTLE_WINDOW_SEC"
        local lock_state=free
        if ! xtables_lock_free; then
            lock_state=busy
            lock_busy_count=$((lock_busy_count + 1))
        fi
        local h
        h=$(ufw_chains_hash)
        if [ "$lock_state" = "free" ] && [ -n "$h" ] && [ "$h" = "$prev" ]; then
            stable=$((stable + 1))
            if [ "$stable" -ge "$SETTLE_STABLE_WINDOWS" ]; then
                local elapsed=$(( $(date +%s) - start ))
                log "settle: ok (lock=free ufw_hash=${h:0:12} stable=${stable} elapsed=${elapsed}s lock_busy=${lock_busy_count})"
                emit_metric 1 "$elapsed" "$stable" "$lock_busy_count"
                return 0
            fi
        else
            stable=0
            prev=$h
        fi
    done
    local elapsed=$(( $(date +%s) - start ))
    log "settle: TIMEOUT after ${elapsed}s (last_stable=${stable}/${SETTLE_STABLE_WINDOWS} lock_busy=${lock_busy_count}) — proceeding"
    emit_metric 0 "$elapsed" "$stable" "$lock_busy_count"
    return 0
}

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
