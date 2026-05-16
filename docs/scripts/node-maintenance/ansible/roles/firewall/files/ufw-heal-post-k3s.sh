#!/bin/bash
# ufw-heal-post-k3s.sh  (v5 — 2026-05-16)
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
# v5 changes (2026-05-16 incident — kernel 6.18.29→31 reboot):
#   - Phase B: after successful --force enable, pin ENABLED=yes in config AND
#     verify ufw status immediately (K3s races can undo the enable within 1s)
#   - Phase E: SKIP if phase-b just recovered (the enable already loaded rules;
#     a second reload during K3s boot-storm races and flips config back)
#   - Phase F: if phase-b recovered, inactive = FAIL (exit 1 → alert fires)
#   - Support --watchdog mode: skip phase-a settle (for periodic timer calls)
#
# Sequence (revised 2026-05-16):
#   A. Settle wait — nft monitor + iptables-save sha256 stability (3x 5s
#      consecutive identical windows). Max 90s. Skipped in --watchdog mode.
#   C. Per-chain repair FIRST — single-syscall `iptables -N` is race-free,
#      gives reload a clean skeleton to restore over
#   B. ufw reload (up to 3 attempts, 10s gap). On recovery from disabled,
#      pins config + verifies state survived.
#   E. Final reload (skipped if phase-b recovered — avoids re-race)
#   D. Verify probe set — v4 + v6 canary chains
#   F. Status check (authoritative). FAIL if recovery was attempted but
#      UFW is inactive.
#
# Never exits non-zero from Phase A timeout — boot must proceed.
# Exits non-zero from Phase F if UFW should be active but isn't → systemd
# marks service failed → alerts fire.

set -uo pipefail

LOG_TAG="ufw-heal"
UFW_BIN="/usr/sbin/ufw"
UFW_CONF="/etc/ufw/ufw.conf"
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

# State tracking
RECOVERED_FROM_DISABLED=0
WATCHDOG_MODE=0

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

# Pin ENABLED=yes in /etc/ufw/ufw.conf — prevents reload failure from flipping
# the config back to ENABLED=no (observed 2026-05-16).
pin_ufw_enabled() {
    if grep -q '^ENABLED=yes' "$UFW_CONF" 2>/dev/null; then
        return 0
    fi
    sed -i 's/^ENABLED=.*/ENABLED=yes/' "$UFW_CONF" 2>/dev/null
    log "pinned ENABLED=yes in $UFW_CONF"
}

# Phase B — ufw reload with retries (after chains pre-created).
# If reload reports "firewall not enabled, skipping reload" → ufw flipped to
# disabled mid-runtime (e.g. post-pacman kernel-module wipe → ip6tables errors).
# Recover via `ufw-init flush-all` (clears stale kernel chains from previous
# session that block re-enable with "iptables-restore line 2: No chain/target")
# + `ufw --force enable`. Pattern observed 2026-05-02 W1 incident.
#
# v5 fix: after force-enable succeeds, immediately pin config + verify status
# survives (K3s can race the enable and flip it back within <1s).
phase_b_reload() {
    for attempt in 1 2 3; do
        log "phase-b: ufw reload attempt $attempt/3"
        local out rc
        out=$("$UFW_BIN" reload 2>&1)
        rc=$?
        if [ $rc -eq 0 ] && ! echo "$out" | grep -qi "skipping reload\|not enabled"; then
            log "phase-b: reload succeeded (attempt $attempt)"
            return 0
        fi
        log "phase-b: reload no-op (ufw disabled) — recovering: flush-all + force-enable"
        /lib/ufw/ufw-init flush-all >/dev/null 2>&1 || log "phase-b: flush-all errored (continuing)"

        # Pin config BEFORE enable — so even if enable's internal reload races
        # and fails, the config stays ENABLED=yes for next boot/retry.
        pin_ufw_enabled

        local enable_out
        enable_out=$("$UFW_BIN" --force enable 2>&1)
        if echo "$enable_out" | grep -qi "Firewall is active"; then
            log "phase-b: recovered from disabled state (attempt $attempt)"
            RECOVERED_FROM_DISABLED=1

            # Re-pin (enable may have written config) + verify it stuck
            pin_ufw_enabled
            sleep 2  # brief settle — let any in-flight kube-proxy writes land

            # Verify status survived the race window
            local verify_status
            verify_status=$("$UFW_BIN" status 2>&1 || true)
            if echo "$verify_status" | grep -qi "Status: active"; then
                log "phase-b: post-enable verify PASS — ufw active"
                return 0
            fi
            log "phase-b: post-enable verify FAIL — ufw got raced, retrying"
            sleep 5
            continue
        fi
        log "phase-b: recovery failed: $enable_out"
        sleep 10
    done
    log "phase-b: all reload attempts failed"
    return 1
}

# Phase E — final reload attempt.
# v5: SKIP if phase-b just recovered from disabled. The `--force enable` already
# loaded all rules. A second `ufw reload` during K3s boot-storm races
# iptables-restore and can fail, which causes UFW to flip ENABLED=no in config
# (observed 2026-05-16 05:45:39). Skipping avoids the race entirely.
phase_e_final_reload() {
    if [ "$RECOVERED_FROM_DISABLED" -eq 1 ]; then
        log "phase-e: SKIP — phase-b recovered from disabled (reload would re-race K3s)"
        return 0
    fi
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

# Phase F — status check (authoritative).
# v5: if we recovered from disabled (phase-b set RECOVERED_FROM_DISABLED=1),
# then inactive is NOT acceptable — it means the recovery failed and UFW is
# down. Exit non-zero → systemd marks failed → alert fires.
phase_f_status() {
    local status
    status=$("$UFW_BIN" status 2>&1 || true)
    if echo "$status" | grep -qi "Status: active"; then
        log "phase-f: ufw active — heal OK"
        return 0
    fi
    if echo "$status" | grep -qiE "inactive|not enabled"; then
        if [ "$RECOVERED_FROM_DISABLED" -eq 1 ]; then
            log "phase-f: FAIL — recovery was attempted but ufw is INACTIVE (firewall down!)"
            return 1
        fi
        # Config says ENABLED=no and we didn't try to recover → user-disabled, not our problem
        log "phase-f: ufw inactive (ENABLED=no, no recovery attempted) — exiting clean"
        return 0
    fi
    log "phase-f: ufw unhealthy: $status"
    return 1
}

main() {
    # Parse args
    if [[ "${1:-}" == "--watchdog" ]]; then
        WATCHDOG_MODE=1
    fi

    if [ "$WATCHDOG_MODE" -eq 1 ]; then
        # Quick-check: if UFW is already active, exit immediately (no-op for timer)
        local quick_status
        quick_status=$("$UFW_BIN" status 2>&1 || true)
        if echo "$quick_status" | grep -qi "Status: active"; then
            # Silent exit — don't spam journal every 5min
            exit 0
        fi
        log "watchdog: ufw not active — starting heal"
    else
        log "starting heal sequence (pid=$$)"
    fi

    # Phase A: settle (skip in watchdog — system already booted and stable)
    if [ "$WATCHDOG_MODE" -eq 0 ]; then
        phase_a_settle
    fi

    phase_c_repair
    phase_b_reload || true
    phase_e_final_reload || true
    phase_d_verify || log "WARN: probe set still unhealthy after repair"
    phase_f_status
}

main "$@"
