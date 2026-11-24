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
# ufw_chains_hash in node-script-lib.sh reads these two.
# shellcheck disable=SC2034
IPTABLES_SAVE="/usr/sbin/iptables-save"
# shellcheck disable=SC2034
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
PHASE_B_RELOADED=0
PHASE_G_REASON=""
PHASE_H_REASON=""
# Seconds since boot (CLOCK_BOOTTIME), which a wall-clock change during boot cannot move.
uptime_s() {
    local up _
    read -r up _ </proc/uptime
    echo "${up%.*}"
}
# A boot or watchdog run must end inside its unit's TimeoutStartSec (5 min, 3 min). Bounded calls
# and sleeps reserve RESERVE_S for the alert. The script gives ufw reload and enable no timeout, so a
# slow one can use the reserve and reach the unit's deadline.
SCRIPT_DEADLINE=$(($(uptime_s) + 285))
RESERVE_S=15
budget_left() { echo $((SCRIPT_DEADLINE - RESERVE_S - $(uptime_s))); }
# If the budget expires before the command starts, bounded also returns 124. If a command ignores
# TERM, KILL follows 2 s later, and the budget counts those 2 s.
bounded() {
    local cap=$1 left
    shift
    left=$(($(budget_left) - 2))
    [ "$left" -ge 1 ] || return 124
    [ "$left" -lt "$cap" ] && cap=$left
    timeout -k 2 "$cap" "$@"
}
nap() {
    local n=$1 left
    left=$(budget_left)
    [ "$left" -lt "$n" ] && n=$left
    [ "$n" -ge 1 ] && sleep "$n"
    return 0
}

log() {
    logger -t "$LOG_TAG" -- "$*"
    echo "[ufw-heal] $*" >&2
}

# Shared helpers. NODE_SCRIPT_LIB lets the offline tests point at the repo copy.
NODE_SCRIPT_LIB="${NODE_SCRIPT_LIB:-/usr/local/lib/node-maintenance/node-script-lib.sh}"
# shellcheck source=../../base_config/files/node-script-lib.sh
if ! . "$NODE_SCRIPT_LIB" || ! declare -F ufw_chains_hash >/dev/null; then
    log "cannot load $NODE_SCRIPT_LIB — exiting."
    exit 1
fi

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


# Phase A — wait for UFW chain stability across N consecutive windows.
# Phase A logs nft monitor events for diagnostics only. 457c67a5 (2026-04-28) removed them
# as a settle gate here and in firewall-preflight.sh. In the phase-a logs of W1, W2 and the CP
# (2026-09-04 to 2026-10-04), the count varies between 0 and several hundred in back-to-back
# windows while the sampled UFW chain hash stays the same. So the count alone does not show
# that the UFW chains are stable.
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
    wait_kube_proxy_started
    for attempt in 1 2 3; do
        log "phase-b: ufw reload attempt $attempt/3"
        local out rc
        out=$("$UFW_BIN" reload 2>&1)
        rc=$?
        if [ $rc -eq 0 ] && ! echo "$out" | grep -qi "skipping reload\|not enabled"; then
            log "phase-b: reload succeeded (attempt $attempt)"
            PHASE_B_RELOADED=1
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
# loaded all rules. A second `ufw reload` while K3s is still loading rules at boot races
# iptables-restore and can fail, which causes UFW to flip ENABLED=no in config
# (observed 2026-05-16 05:45:39). Skipping avoids the race entirely.
phase_e_final_reload() {
    if [ "$RECOVERED_FROM_DISABLED" -eq 1 ]; then
        log "phase-e: SKIP — phase-b recovered from disabled (reload would re-race K3s)"
        return 0
    fi
    # A second reload can race K3s's own iptables writes at boot. If a failed reload leaves UFW
    # inactive, the watchdog's flush-all removes kube-proxy's IPv4 jumps.
    if [ "$PHASE_B_RELOADED" -eq 1 ]; then
        log "phase-e: SKIP — phase-b reloaded"
        return 0
    fi
    wait_kube_proxy_started
    local attempt s
    for attempt in 1 2 3; do
        [ "$attempt" -gt 1 ] && nap 10
        # Interrupting a reload can leave UFW partly configured, so a reload has no timeout.
        if [ "$(budget_left)" -lt 30 ]; then
            log "phase-e: no time left for reload attempt $attempt/3"
            return 1
        fi
        log "phase-e: final ufw reload attempt $attempt/3"
        # As in phase B, a reload that exits 0 but reports a skip did not reload.
        if s=$("$UFW_BIN" reload 2>&1) && ! grep -qi "skipping reload\|not enabled" <<<"$s"; then
            # If the reload succeeds but UFW's status is unclear, retry only the status read: a
            # second reload can race K3s.
            if ufw_active_confirmed; then
                log "phase-e: final reload succeeded"
                return 0
            fi
            log "phase-e: reload succeeded but UFW is not confirmed active — phase-f reports it"
            return 1
        fi
        if s=$(bounded 15 "$UFW_BIN" status 2>&1) && grep -qi '^Status: inactive' <<<"$s"; then
            log "phase-e: UFW inactive after a failed reload — phase-f reports it and the watchdog recovers it"
            return 1
        fi
    done
    log "phase-e: final reload failed"
    return 1
}

# If ufw status exits unsuccessfully, ignore any status text it printed. Only UFW's own status line
# counts: a rule comment can contain the word.
ufw_active_confirmed() {
    local s n
    for n in 1 2 3; do
        [ "$n" -gt 1 ] && nap 2
        s=$(bounded 15 "$UFW_BIN" status 2>&1) || continue
        grep -qi '^Status: active' <<<"$s" && return 0
        grep -qi '^Status: inactive' <<<"$s" && return 1
    done
    return 1
}

# Every node runs IPv4, so its mangle canary shows that kube-proxy has started; kube-proxy creates it
# before it finishes its first sync. If 100 s or less remain, stop waiting so the reload and the
# repairs have time to run.
wait_kube_proxy_started() {
    local ipt dir end
    ipt=$(k3s_iptables) || return 0
    dir=${ipt%/*}
    end=$(($(uptime_s) + 30))
    while [ "$(uptime_s)" -lt "$end" ]; do
        if [ "$(budget_left)" -le 100 ]; then
            log "wait: budget too short — reloading without the kube-proxy canary check"
            return 0
        fi
        bounded 3 "$dir/iptables" -w 1 -t mangle -S KUBE-PROXY-CANARY >/dev/null 2>&1 && return 0
        nap 2
    done
    log "wait: could not confirm kube-proxy's IPv4 canary within 30 s — reloading anyway"
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
# user chains and their rules. kube-proxy re-adds its jumps only in a full sync, which phase H
# requests if it confirms a missing jump. The portmap plugin runs only when a pod starts (k8s#93091), so its three entry rules stay gone
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
    if ! nat=$(bounded 10 "$IPTABLES" -w 5 -t nat -S 2>&1); then
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
    if ! state=$(cni_rule_state); then
        PHASE_G_REASON="cannot read the nat table, or no budget left"
        return 1
    fi
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
        PHASE_G_REASON="cannot find the iptables binary k3s uses"
        return 1
    fi
    # If the rule is absent, -C exits 1. If the check exits above 1, the rule may already exist:
    # phase G skips the insert to avoid a duplicate, and the final read decides.
    local chain rc unchecked=0
    for item in $state; do
        rc=0
        case $item in
            dnat-missing:*)
                chain=${item#dnat-missing:}
                bounded 10 "$ipt" -w 5 -t nat -C "$chain" "${CNI_DNAT_RULE[@]}" 2>/dev/null
                rc=$?
                [ "$rc" -eq 1 ] && bounded 10 "$ipt" -w 5 -t nat -A "$chain" "${CNI_DNAT_RULE[@]}"
                ;;
            masq-missing)
                bounded 10 "$ipt" -w 5 -t nat -C POSTROUTING "${CNI_MASQ_RULE[@]}" 2>/dev/null
                rc=$?
                [ "$rc" -eq 1 ] && bounded 10 "$ipt" -w 5 -t nat -I POSTROUTING 1 "${CNI_MASQ_RULE[@]}"
                ;;
        esac
        if [ "$rc" -gt 1 ]; then
            unchecked=$((unchecked + 1))
            log "phase-g: check exited $rc; skipping the insert for $item"
        fi
    done
    if ! state=$(cni_rule_state); then
        PHASE_G_REASON="cannot read the nat table after the restore, or no budget left"
        return 1
    fi
    if grep -q -- '-missing' <<<"$state"; then
        log "phase-g: portmap entry rules still missing after restore ($ipt): $(grep -- '-missing' <<<"$state" | tr '\n' ' ')"
        PHASE_G_REASON="portmap entry rules still missing after the restore"
        [ "$unchecked" -gt 0 ] && PHASE_G_REASON+=" ($unchecked could not be checked)"
        return 1
    fi
    log "phase-g: portmap entry rules restored and verified ($ipt)"
    return 0
}

# Phase H — make kube-proxy re-add its jumps after a flush-all.
# flush_builtins flushes the IPv4 nat built-in chains and deletes every filter user chain in both
# families. kube-proxy loses its IPv4 nat jumps and its filter jumps in both families, and re-adds
# jumps from built-in chains only in a full sync. If its mangle KUBE-PROXY-CANARY chain disappears,
# kube-proxy starts a full sync. The flush keeps that chain, so if phase H confirms a missing jump
# and the canary still exists, it deletes the canary. kube-router rebuilds its NetworkPolicy
# chains, which the flush also deletes, at its own next sync.
# Phase H checks every jump a kube-proxy full sync adds from a built-in chain (iptablesJumpChains
# and iptablesKubeletJumpChains, v1.37.2): if a second flush lands during a sync, any of them can be
# missing while others are back. A jump must match its whole line: a rule with the same comment and
# target but a narrower match (a source address) does not carry the same traffic. kube-proxy writes
# "-A <chain> <extra args> -m comment --comment <comment> -j <target>", its extra args (conntrack)
# first; the kubelet jumps have no comment.
# Each entry: <table>/<chain>|<target>|<comment>|<extra args>.
KP_NEW='-m conntrack --ctstate NEW'
KP_JUMPS=(
    "filter/INPUT|KUBE-EXTERNAL-SERVICES|kubernetes externally-visible service portals|$KP_NEW"
    "filter/FORWARD|KUBE-EXTERNAL-SERVICES|kubernetes externally-visible service portals|$KP_NEW"
    'filter/INPUT|KUBE-NODEPORTS|kubernetes health check service ports|'
    "filter/FORWARD|KUBE-SERVICES|kubernetes service portals|$KP_NEW"
    "filter/OUTPUT|KUBE-SERVICES|kubernetes service portals|$KP_NEW"
    'filter/FORWARD|KUBE-FORWARD|kubernetes forwarding rules|'
    "filter/INPUT|KUBE-PROXY-FIREWALL|kubernetes load balancer firewall|$KP_NEW"
    "filter/OUTPUT|KUBE-PROXY-FIREWALL|kubernetes load balancer firewall|$KP_NEW"
    "filter/FORWARD|KUBE-PROXY-FIREWALL|kubernetes load balancer firewall|$KP_NEW"
    'nat/OUTPUT|KUBE-SERVICES|kubernetes service portals|'
    'nat/PREROUTING|KUBE-SERVICES|kubernetes service portals|'
    'nat/POSTROUTING|KUBE-POSTROUTING|kubernetes postrouting rules|'
    'filter/INPUT|KUBE-FIREWALL||'
    'filter/OUTPUT|KUBE-FIREWALL||'
)
KP_CHAINS=(filter/INPUT filter/FORWARD filter/OUTPUT nat/PREROUTING nat/OUTPUT nat/POSTROUTING)

# The flush keeps the mangle canary and the nat KUBE-SERVICES chain, so their state shows whether
# kube-proxy runs IPv6. Prints present, absent (both reads exit 1, missing chain) or unknown (a read
# failed). If neither read confirms IPv6, phase H checks the markers again on the next poll.
kube_proxy_ipv6_markers() {
    local b=$1 rc1 rc2
    bounded 5 "$b" -w 2 -t mangle -S KUBE-PROXY-CANARY >/dev/null 2>&1
    rc1=$?
    if [ "$rc1" -eq 0 ]; then
        echo present
        return
    fi
    bounded 5 "$b" -w 2 -t nat -S KUBE-SERVICES >/dev/null 2>&1
    rc2=$?
    if [ "$rc2" -eq 0 ]; then
        echo present
    elif [ "$rc1" -eq 1 ] && [ "$rc2" -eq 1 ]; then
        echo absent
    else
        echo unknown
    fi
}

# Prints one word per jump, <table>/<chain>><target>=present|missing|unread, for the family of the
# iptables binary $1. One read of a chain supplies all its jumps' results.
kube_proxy_chain_reads() {
    local b=$1 spec rules ok entry target comment extra line
    for spec in "${KP_CHAINS[@]}"; do
        ok=1
        rules=$(bounded 5 "$b" -w 2 -t "${spec%/*}" -S "${spec#*/}" 2>/dev/null) || ok=0
        for entry in "${KP_JUMPS[@]}"; do
            [ "${entry%%|*}" = "$spec" ] || continue
            IFS='|' read -r _ target comment extra <<<"$entry"
            line="-A ${spec#*/} ${extra:+$extra }${comment:+-m comment --comment \"$comment\" }-j $target"
            if [ "$ok" -eq 0 ]; then
                echo "$spec>$target=unread"
            elif grep -qxF -- "$line" <<<"$rules"; then
                echo "$spec>$target=present"
            else
                echo "$spec>$target=missing"
            fi
        done
    done
}

# If the mangle delete succeeds, phase H counts one trigger. Deleting the nat canary too spares
# kube-proxy its wait for the other canaries.
# An absent mangle canary means kube-proxy's monitor starts a full sync at its next check, so it
# needs no delete. If the canary read ends at or after $2 (seconds since boot), there is no delete:
# phase H would have no time left to see the sync it starts.
kube_proxy_trigger() {
    local b=$1 end=$2
    bounded 5 "$b" -w 2 -t mangle -S KUBE-PROXY-CANARY >/dev/null 2>&1
    case $? in
        1)
            echo "canary already absent"
            return 0
            ;;
        0) ;;
        *)
            echo "canary read failed"
            return 1
            ;;
    esac
    if [ "$(uptime_s)" -ge "$end" ]; then
        echo "no time left before the canary delete"
        return 1
    fi
    if ! bounded 5 "$b" -w 2 -t mangle -X KUBE-PROXY-CANARY 2>/dev/null; then
        echo "canary delete failed"
        return 1
    fi
    bounded 5 "$b" -w 2 -t nat -X KUBE-PROXY-CANARY 2>/dev/null
    echo "canary deleted"
}

# If a read fails, phase H keeps that jump's last confirmed loss, so the trigger can still act on it.
# If kube-proxy recreates the canary while a jump is still missing, another delete can request
# another full sync: at most 3 deletes per family, at least 15 s after the previous one. A delete
# needs more than 10 s left, so that a later read can see its effect. After the 75 s, if enough
# budget remains, phase H reads once more; that read never deletes.
phase_h_kube_proxy_resync() {
    PHASE_H_REASON=""
    [ "$RECOVERED_FROM_DISABLED" -eq 1 ] || return 0
    local ipt dir fam end all out word key val v6="" note="" logged="" final=""
    local fams=(iptables)
    local -A lost=() unread=() fam_ok=() deletes=() last_delete=() last_out=() read_after_delete=()
    if ! ipt=$(k3s_iptables); then
        PHASE_H_REASON="cannot find the iptables binary k3s uses"
        log "phase-h: $PHASE_H_REASON — kube-proxy resync NOT triggered"
        return 1
    fi
    dir=${ipt%/*}
    end=$(($(uptime_s) + 75))
    while :; do
        if [ "$v6" != present ]; then
            v6=$(kube_proxy_ipv6_markers "$dir/ip6tables")
            [ "$v6" = present ] && fams+=(ip6tables)
        fi
        for fam in "${fams[@]}"; do
            phase_h_read "$fam"
        done
        # kube-proxy can create its IPv6 markers between this poll's marker read and its IPv4 reads.
        # If IPv4 reads ok and IPv6 read absent, read the markers once more before the trigger.
        if [ "$v6" = absent ] && [ -n "${fam_ok[iptables]}" ]; then
            v6=$(kube_proxy_ipv6_markers "$dir/ip6tables")
            if [ "$v6" = present ]; then
                fams+=(ip6tables)
                phase_h_read ip6tables
            fi
        fi
        all=1
        [ "$v6" = unknown ] && all=0
        for fam in "${fams[@]}"; do
            [ -n "${fam_ok[$fam]}" ] && continue
            all=0
            [ -z "$final" ] || continue
            [ -n "$(lost_chains "$fam" any)" ] || continue
            [ "$(uptime_s)" -lt "$(trigger_limit "$end")" ] || continue
            [ "${deletes[$fam]:-0}" -lt 3 ] || continue
            if [ -n "${last_delete[$fam]:-}" ]; then
                [ $(($(uptime_s) - ${last_delete[$fam]})) -ge 15 ] || continue
            fi
            out=$(kube_proxy_trigger "$dir/$fam" "$(trigger_limit "$end")")
            if [ "$out" = "canary deleted" ]; then
                deletes[$fam]=$((${deletes[$fam]:-0} + 1))
                last_delete[$fam]=$(uptime_s)
                read_after_delete[$fam]=""
            fi
            if [ "$out" != "${last_out[$fam]:-}" ] || [ "$out" = "canary deleted" ]; then
                log "phase-h: $fam: $out"
                last_out[$fam]=$out
            fi
        done
        if [ "$all" -eq 1 ]; then
            log "phase-h: kube-proxy jumps present in ${fams[*]}"
            [ "$v6" = absent ] && log "phase-h: no IPv6 kube-proxy markers observed during this run"
            return 0
        fi
        [ -z "$final" ] || break
        # Keep 3 s of the budget for the next read.
        nap $(($(budget_left) - 3 < 5 ? $(budget_left) - 3 : 5))
        if [ "$(budget_left)" -lt 3 ]; then
            note="budget spent"
            break
        fi
        if [ "$(uptime_s)" -ge "$end" ]; then
            note="75 s passed"
            final=1
        fi
    done
    local confirmed=0
    for fam in "${fams[@]}"; do
        [ -n "${fam_ok[$fam]:-}" ] && continue
        if [ "${deletes[$fam]:-0}" -gt 0 ] && [ -z "${read_after_delete[$fam]:-}" ]; then
            PHASE_H_REASON+="$fam: no successful read after the last delete, recovery unverified (before it: $(kube_proxy_chain_reads_summary "$fam")); "
            continue
        fi
        [ -n "$(lost_chains "$fam" confirmed)" ] && confirmed=1
        PHASE_H_REASON+="$fam: $(kube_proxy_chain_reads_summary "$fam"), canary deleted ${deletes[$fam]:-0} times; "
    done
    case $v6 in
        unknown) PHASE_H_REASON+="IPv6 markers could not be read; " ;;
        absent) log "phase-h: no IPv6 kube-proxy markers observed during this run" ;;
    esac
    PHASE_H_REASON+="($note)"
    if [ "$confirmed" -eq 1 ]; then
        log "phase-h: kube-proxy jumps not restored: $PHASE_H_REASON"
    else
        log "phase-h: could not confirm kube-proxy jumps: $PHASE_H_REASON"
    fi
    return 1
}

# phase_h_read FAMILY: one read of the family's jumps. It reads dir from phase H and updates phase
# H's local arrays lost, unread, fam_ok and read_after_delete and its string logged (bash dynamic
# scope).
phase_h_read() {
    local fam=$1 word key val
    fam_ok[$fam]=1
    for word in $(kube_proxy_chain_reads "$dir/$fam"); do
        key="$fam:${word%=*}" val=${word#*=}
        [ "$val" = unread ] || read_after_delete[$fam]=1
        case $val in
            present) lost[$key]="" unread[$key]="" ;;
            missing) lost[$key]=1 unread[$key]="" ;;
            *) unread[$key]=1 ;;
        esac
        [ "$val" = present ] || fam_ok[$fam]=""
    done
    if [[ " $logged " != *" $fam "* ]]; then
        log "phase-h: $fam: first read $(kube_proxy_chain_reads_summary "$fam")"
        logged+=" $fam"
    fi
}

# trigger_limit END: the cutoff (seconds since boot, exclusive) for a canary delete: 10 s before the
# earlier of END and the script's budget, so a later read can still see the sync it requests.
trigger_limit() {
    local now lim b
    now=$(uptime_s)
    lim=$(($1 - 10))
    b=$((now + $(budget_left) - 10))
    [ "$b" -lt "$lim" ] && lim=$b
    echo "$lim"
}

# lost_chains and kube_proxy_chain_reads_summary read phase H's local arrays lost and unread (bash
# dynamic scope), in KP_JUMPS order so the reason reads the same on every run.
# lost_chains FAMILY [any|confirmed|stale]: the jumps with a recorded loss; confirmed = the last read
# saw it missing, stale = a later read failed.
lost_chains() {
    local entry spec key out=""
    for entry in "${KP_JUMPS[@]}"; do
        spec=${entry%%|*} key=${entry#*|}
        key="$1:$spec>${key%%|*}"
        [ -n "${lost[$key]:-}" ] || continue
        case ${2:-any} in
            confirmed) [ -z "${unread[$key]:-}" ] || continue ;;
            stale) [ -n "${unread[$key]:-}" ] || continue ;;
        esac
        out+="${key#*:},"
    done
    echo "${out%,}"
}

kube_proxy_chain_reads_summary() {
    local entry key m s u=""
    m=$(lost_chains "$1" confirmed)
    s=$(lost_chains "$1" stale)
    for entry in "${KP_JUMPS[@]}"; do
        key=${entry#*|}
        key="$1:${entry%%|*}>${key%%|*}"
        [ -n "${unread[$key]:-}" ] && [ -z "${lost[$key]:-}" ] && u+="${key#*:},"
    done
    if [ -z "$m$s$u" ]; then
        echo ok
        return
    fi
    local out=()
    [ -n "$m" ] && out+=("missing:$m")
    [ -n "$s" ] && out+=("last seen missing, then unread:$s")
    [ -n "$u" ] && out+=("unread:${u%,}")
    echo "${out[*]}"
}

# Phase G runs first, so hostPort DNS does not wait for phase H. If either phase fails, the script
# sends one Telegram alert after both finish, naming each failed phase and its reason. The firewall role's rescue ignores this script's
# exit code. If the boot unit exits non-zero, it stays failed and NodeSystemdUnitFailed fires after
# 15 min. The watchdog's failed state clears on its next run if UFW is active by then.
run_cni_heal() {
    local failed=()
    phase_g_cni_heal || failed+=("phase G, hostPort traffic: ${PHASE_G_REASON:-see the journal}")
    phase_h_kube_proxy_resync || failed+=("phase H, kube-proxy jumps: ${PHASE_H_REASON}")
    [ "${#failed[@]}" -eq 0 ] && return 0
    /usr/local/sbin/telegram-notify.sh "⚠️ $(hostname): after a UFW flush-all, ufw-heal could not finish: $(printf '%s; ' "${failed[@]}")the clusterip heal restarts k3s if ClusterIP stays broken. See journalctl -t ufw-heal." || true
    return 1
}

main() {
    if [[ "${1:-}" == "--watchdog" ]]; then
        WATCHDOG_MODE=1
        SCRIPT_DEADLINE=$(($(uptime_s) + 165))
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
