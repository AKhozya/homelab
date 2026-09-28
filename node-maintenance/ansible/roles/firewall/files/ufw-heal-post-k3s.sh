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
# Sequence (the letters are historical; this is the run order):
#   A. Settle wait — nft monitor + iptables-save sha256 stability (3x 5s
#      consecutive identical windows). Max 90s. Skipped in --watchdog mode.
#   C. Per-chain repair FIRST — single-syscall `iptables -N` is race-free,
#      gives reload a clean skeleton to restore over
#   B. ufw reload (up to 3 attempts, 10s gap). On recovery from disabled,
#      pins config + verifies state survived.
#   E. Final reload (skipped if phase-b recovered — avoids re-race)
#   D. Verify probe set — v4 + v6 canary chains
#   G. portmap CNI rule restore — only after a disabled-recovery (see phase_g_cni_heal)
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

# Idempotent: no-op when the chain already exists.
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
# After a force-enable succeeds, pin the config and verify the status survives:
# K3s can race the enable and flip it back inside 1s (2026-05-16).
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
# SKIP if phase-b just recovered from disabled. The `--force enable` already
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
# If phase-b set RECOVERED_FROM_DISABLED=1, inactive is NOT acceptable: the recovery
# failed and the firewall is down. Exit non-zero so systemd marks the unit failed and
# the alert fires.
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
        # ENABLED=no with no recovery attempt means an operator disabled it deliberately.
        log "phase-f: ufw inactive (ENABLED=no, no recovery attempted) — exiting clean"
        return 0
    fi
    log "phase-f: ufw unhealthy: $status"
    return 1
}

# Phase G — restore the portmap CNI plugin's entry rules after a flush-all.
# `/lib/ufw/ufw-init flush-all` (phase-b disabled-recovery, and firewall-preflight.sh through
# --cni-heal) flushes the built-in nat chains PREROUTING, OUTPUT and POSTROUTING. It keeps the
# user chains and their rules. flannel and kube-proxy are daemons and re-add their own jumps.
# The portmap plugin runs only when a pod starts (k8s#93091), so its three entry rules stay gone
# and hostPort traffic (the servicelb svclb pods) loses its DNAT and masquerade.
# These are the exact rules chain.setup() in portmap_iptables.go writes (rancher/plugins
# v1.9.1-k3s1, the version k3s v1.37.0+k3s1 bundles; k3s's CNI conflist runs portmap with the
# default iptables backend):
#   PREROUTING, OUTPUT (appended):  -m addrtype --dst-type LOCAL -j CNI-HOSTPORT-DNAT
#   POSTROUTING (inserted first):   -m comment --comment "CNI portfwd requiring masquerade" -j CNI-HOSTPORT-MASQ
# Rejected: restarting k3s-agent. A restart requires a cooldown, a shared lock and a retry file,
# and k3s-agent runs only on workers.
# Returns 0 if the rules are present afterwards (or the node has none of the chains), else 1.
CNI_DNAT_RULE=(-m addrtype --dst-type LOCAL -j CNI-HOSTPORT-DNAT)
CNI_MASQ_RULE=(-m comment --comment "CNI portfwd requiring masquerade" -j CNI-HOSTPORT-MASQ)

# The iptables binary portmap itself runs. k3s re-execs itself with a PATH that puts its bundled
# bin/aux before the host PATH when prefer-bundled-bin is set (cmd/k3s/main.go stageAndRun), and
# containerd passes that PATH on to the CNI plugins.
k3s_iptables() {
    local unit pid path
    for unit in k3s-agent.service k3s.service; do
        systemctl is-active --quiet "$unit" || continue
        pid=$(systemctl show -p MainPID --value "$unit") || return 1
        [ "${pid:-0}" -gt 0 ] || return 1
        path=$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^PATH=//p') || return 1
        [ -n "$path" ] || return 1
        PATH="$path" command -v iptables
        return
    done
    return 1
}

# Prints which of the portmap chains exist and which entry rules are missing, one word per line:
# dnat-chain, masq-chain, dnat-missing:<CHAIN>, masq-missing. Returns 1 if the read fails.
cni_rule_state() {
    local nat
    if ! nat=$("$IPTABLES" -w 5 -t nat -S 2>&1); then
        log "phase-g: cannot read the nat table: $nat"
        return 1
    fi
    if grep -qx -- '-N CNI-HOSTPORT-DNAT' <<<"$nat"; then
        echo dnat-chain
        grep -qx -- '-A PREROUTING -m addrtype --dst-type LOCAL -j CNI-HOSTPORT-DNAT' <<<"$nat" \
            || echo dnat-missing:PREROUTING
        grep -qx -- '-A OUTPUT -m addrtype --dst-type LOCAL -j CNI-HOSTPORT-DNAT' <<<"$nat" \
            || echo dnat-missing:OUTPUT
    fi
    if grep -qx -- '-N CNI-HOSTPORT-MASQ' <<<"$nat"; then
        echo masq-chain
        grep -q -- '^-A POSTROUTING .*-j CNI-HOSTPORT-MASQ$' <<<"$nat" || echo masq-missing
    fi
}

phase_g_cni_heal() {
    [ "$RECOVERED_FROM_DISABLED" -eq 1 ] || return 0
    local state ipt item
    state=$(cni_rule_state) || return 1
    if ! grep -q -- '-missing' <<<"$state"; then
        if [ -z "$state" ]; then
            log "phase-g: no portmap chains (no hostPort pods here) — nothing to restore"
        else
            log "phase-g: portmap entry rules present — nothing to restore"
        fi
        return 0
    fi
    if ! ipt=$(k3s_iptables); then
        log "phase-g: cannot find the iptables binary k3s uses — portmap rules NOT restored"
        return 1
    fi
    for item in $state; do
        case $item in
            dnat-missing:*)
                "$ipt" -w 5 -t nat -C "${item#dnat-missing:}" "${CNI_DNAT_RULE[@]}" 2>/dev/null \
                    || "$ipt" -w 5 -t nat -A "${item#dnat-missing:}" "${CNI_DNAT_RULE[@]}" ;;
            masq-missing)
                "$ipt" -w 5 -t nat -C POSTROUTING "${CNI_MASQ_RULE[@]}" 2>/dev/null \
                    || "$ipt" -w 5 -t nat -I POSTROUTING 1 "${CNI_MASQ_RULE[@]}" ;;
        esac
    done
    state=$(cni_rule_state) || return 1
    if grep -q -- '-missing' <<<"$state"; then
        log "phase-g: portmap entry rules still missing after restore ($ipt): $(grep -- '-missing' <<<"$state" | tr '\n' ' ')"
        return 1
    fi
    log "phase-g: portmap entry rules restored and verified ($ipt)"
    return 0
}

# A failure sends one Telegram alert. The boot unit, the watchdog and the firewall role's rescue
# do not alert on this script's exit code.
run_cni_heal() {
    phase_g_cni_heal && return 0
    /usr/local/sbin/telegram-notify.sh "⚠️ $(hostname): after a UFW flush-all, ufw-heal could not restore the portmap CNI rules (CNI-HOSTPORT-DNAT/MASQ jumps). hostPort traffic (svclb) may be broken until k3s restarts. See journalctl -t ufw-heal." || true
    return 1
}

main() {
    if [[ "${1:-}" == "--watchdog" ]]; then
        WATCHDOG_MODE=1
    fi
    # firewall-preflight.sh calls this after its own flush-all recovery.
    if [[ "${1:-}" == "--cni-heal" ]]; then
        RECOVERED_FROM_DISABLED=1
        run_cni_heal
        exit $?
    fi

    if [ "$WATCHDOG_MODE" -eq 1 ]; then
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
    local cni_rc=0
    run_cni_heal || { cni_rc=1; log "WARN: CNI heal did not complete"; }
    phase_f_status || return 1
    return "$cni_rc"
}

main "$@"
