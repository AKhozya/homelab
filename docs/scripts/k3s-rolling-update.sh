#!/usr/bin/env bash
# k3s-rolling-update.sh — Weekly rolling OS update for K3s homelab cluster
#
# Runs from control-plane. Updates + reboots nodes sequentially:
#   1. gmk-k3s-control-plane (self — two-phase: reboot, then resume)
#   2. worker-node
#   3. worker-node-2
#
# Per node: checkupdates → pacman -Syu → reboot → 3min reboot → 3min stabilize
# After all: 5min settle → reconcile Flux → fix alerts → cleanup stale
#
# No drain/uncordon — kubelet graceful shutdown (120s) handles pod termination.
# Rebuilderd auto-starts 10min after boot (rebuilderd-worker-boot.timer).
#
# Usage:
#   sudo /usr/local/bin/k3s-rolling-update.sh [--dry-run] [--resume]
#
# Deploy: sudo bash docs/scripts/setup-rolling-update.sh

set -euo pipefail

# ========================== Configuration ==========================

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

STATE_DIR="/var/lib/k3s-rolling-update"
STATE_FILE="${STATE_DIR}/state"
LOCK_FILE="${STATE_DIR}/lock"
LOG_FILE="/var/log/k3s-rolling-update.log"

SSH_PORT=65300
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o BatchMode=yes -p ${SSH_PORT}"

# Node definitions: name|ip|ssh_user
# Order: control-plane first (reboots self), then workers
NODES=(
    "gmk-k3s-control-plane|192.168.1.127|akhozya"
    "worker-node|192.168.1.129|akhozya"
    "worker-node-2|192.168.1.126|z3us"
)

# Timeouts (seconds)
REBOOT_WAIT=180           # 3 minutes for node to reboot and become Ready
NODE_STABILIZE=180        # 3 minutes post-Ready stabilization per node
FINAL_STABILIZE=300       # 5 minutes after all nodes rebooted
HEALTH_CHECK_INTERVAL=15  # Poll interval for node Ready check

# Alertmanager silence duration (3 hours, generous buffer)
SILENCE_DURATION_HOURS=3

# Alerts to silence during rolling update
SILENCE_REGEX="NodeDown|KubeletDown|NodeNotReady|PodCrashLooping|PodNotReady|DeploymentReplicasMismatch|StatefulSetReplicasMismatch|DaemonSetNotScheduled|PodsPending|TooManyPodsPending|RebuilderdWorkerDown|PrometheusTargetDown|PostgreSQLPodNotRunning|MySQLPodNotRunning|MySQLHAProxyNotRunning|MySQLOrchestratorNotRunning|RedisDown|RedisPodNotRunning|CouchDBDown|CouchDBPodNotRunning|PostgreSQLDown|MySQLDown|ContainerOOMKilled|AlloyDown"

# ========================== Globals ==========================

DRY_RUN=false
RESUME=false
SILENCE_ID=""
BOT_TOKEN=""
CHAT_ID=""
PF_PID=""
UPDATE_START=""
UPDATED_NODES=()
SKIPPED_NODES=()
TOTAL_PACKAGES=0

# ========================== Logging ==========================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "${LOG_FILE}" >&2
}

# ========================== Telegram ==========================

send_telegram() {
    local message="$1"
    if [[ -z "${BOT_TOKEN}" || -z "${CHAT_ID}" ]]; then
        log "Telegram not configured, skipping notification"
        return 0
    fi
    if ${DRY_RUN}; then
        log "[DRY-RUN] Telegram: ${message}"
        return 0
    fi
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d parse_mode="HTML" \
        -d text="${message}" \
        -d disable_web_page_preview=true >/dev/null 2>&1 || \
        log "Warning: Failed to send Telegram notification"
}

load_telegram_credentials() {
    log "Loading Telegram credentials from K8s secret..."
    BOT_TOKEN=$(kubectl get secret alertmanager-telegram -n monitoring \
        -o jsonpath='{.data.bot_token}' 2>/dev/null | base64 -d) || true
    CHAT_ID=$(kubectl get secret alertmanager-telegram -n monitoring \
        -o jsonpath='{.data.chat_id}' 2>/dev/null | base64 -d) || true

    if [[ -z "${BOT_TOKEN}" || -z "${CHAT_ID}" ]]; then
        log "Warning: Could not load Telegram credentials"
    else
        log "Telegram credentials loaded (chat_id: ${CHAT_ID})"
    fi
}

# ========================== Locking ==========================

acquire_lock() {
    mkdir -p "${STATE_DIR}"
    if [[ -f "${LOCK_FILE}" ]]; then
        local lock_age
        lock_age=$(( $(date +%s) - $(stat -c %Y "${LOCK_FILE}" 2>/dev/null || echo 0) ))
        if (( lock_age > 7200 )); then
            log "Stale lock file (${lock_age}s old), removing"
            rm -f "${LOCK_FILE}"
        else
            log_error "Another instance is running (lock file age: ${lock_age}s)"
            exit 1
        fi
    fi
    echo $$ > "${LOCK_FILE}"
    trap 'cleanup' EXIT
}

cleanup() {
    if [[ -n "${PF_PID}" ]]; then
        kill "${PF_PID}" 2>/dev/null || true
        wait "${PF_PID}" 2>/dev/null || true
    fi
    rm -f "${LOCK_FILE}"
}

# ========================== SSH Helpers ==========================

ssh_cmd() {
    local user="$1" ip="$2"
    shift 2
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "${user}@${ip}" "$@"
}

ssh_cmd_sudo() {
    local user="$1" ip="$2"
    shift 2
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "${user}@${ip}" "sudo $*"
}

# ========================== Alertmanager Silence ==========================

start_port_forward() {
    kubectl port-forward svc/kube-prometheus-stack-alertmanager -n monitoring 19093:9093 &>/dev/null &
    PF_PID=$!
    sleep 3
    if ! kill -0 "${PF_PID}" 2>/dev/null; then
        log_error "Port-forward to Alertmanager failed"
        PF_PID=""
        return 1
    fi
}

stop_port_forward() {
    if [[ -n "${PF_PID}" ]]; then
        kill "${PF_PID}" 2>/dev/null || true
        wait "${PF_PID}" 2>/dev/null || true
        PF_PID=""
    fi
}

create_silence() {
    if ${DRY_RUN}; then
        log "[DRY-RUN] Would create Alertmanager silence"
        SILENCE_ID="dry-run-silence-id"
        return 0
    fi

    log "Creating Alertmanager silence..."
    start_port_forward || return 1

    local start_time end_time
    start_time=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
    end_time=$(date -u -d "+${SILENCE_DURATION_HOURS} hours" +"%Y-%m-%dT%H:%M:%S.000Z")

    SILENCE_ID=$(curl -s -X POST http://localhost:19093/api/v2/silences \
        -H "Content-Type: application/json" \
        -d '{
            "matchers": [{
                "name": "alertname",
                "value": "'"${SILENCE_REGEX}"'",
                "isRegex": true,
                "isEqual": true
            }],
            "startsAt": "'"${start_time}"'",
            "endsAt": "'"${end_time}"'",
            "createdBy": "k3s-rolling-update",
            "comment": "Automated rolling OS update '"$(date +%Y-%m-%d)"'"
        }' 2>/dev/null | jq -r '.silenceID // empty') || true

    stop_port_forward

    if [[ -z "${SILENCE_ID}" ]]; then
        log "Warning: Failed to create silence, continuing anyway"
    else
        log "Created Alertmanager silence: ${SILENCE_ID}"
    fi
}

delete_silence() {
    local sid="${1:-${SILENCE_ID}}"
    if [[ -z "${sid}" || "${sid}" == "dry-run-silence-id" ]]; then
        return 0
    fi

    if ${DRY_RUN}; then
        log "[DRY-RUN] Would delete Alertmanager silence ${sid}"
        return 0
    fi

    log "Removing Alertmanager silence ${sid}..."
    start_port_forward || return 1
    curl -s -X DELETE "http://localhost:19093/api/v2/silence/${sid}" >/dev/null 2>&1 || \
        log "Warning: Failed to delete silence ${sid}"
    stop_port_forward
    log "Silence removed"
}

# ========================== Node Operations ==========================

parse_node() {
    local node_def="$1"
    NODE_NAME=$(echo "${node_def}" | cut -d'|' -f1)
    NODE_IP=$(echo "${node_def}" | cut -d'|' -f2)
    NODE_USER=$(echo "${node_def}" | cut -d'|' -f3)
}

is_control_plane() {
    [[ "${NODE_NAME}" == "gmk-k3s-control-plane" ]]
}

check_updates() {
    local updates
    if is_control_plane; then
        updates=$(checkupdates 2>/dev/null || true)
    else
        updates=$(ssh_cmd "${NODE_USER}" "${NODE_IP}" "checkupdates 2>/dev/null" || true)
    fi
    echo "${updates}"
}

run_update() {
    log "  Running pacman -Syu on ${NODE_NAME}..."
    if ${DRY_RUN}; then
        log "  [DRY-RUN] Would run pacman -Syu --noconfirm"
        return 0
    fi

    if is_control_plane; then
        pacman -Syu --noconfirm 2>&1 | tail -20 | tee -a "${LOG_FILE}" || {
            log_error "  pacman -Syu failed on ${NODE_NAME}"
            return 1
        }
    else
        ssh_cmd_sudo "${NODE_USER}" "${NODE_IP}" "pacman -Syu --noconfirm" 2>&1 | tail -20 | tee -a "${LOG_FILE}" || {
            log_error "  pacman -Syu failed on ${NODE_NAME}"
            return 1
        }
    fi
    log "  Update completed on ${NODE_NAME}"
}

reboot_node() {
    log "  Rebooting ${NODE_NAME}..."
    if ${DRY_RUN}; then
        log "  [DRY-RUN] Would reboot ${NODE_NAME}"
        return 0
    fi

    if is_control_plane; then
        # Control-plane reboots itself — Phase 2 handles the rest
        reboot &
        sleep 2
        exit 0
    else
        # SSH reboot — connection will drop, that's expected
        ssh_cmd_sudo "${NODE_USER}" "${NODE_IP}" "reboot" 2>/dev/null || true
    fi
}

wait_for_ready() {
    log "  Waiting up to ${REBOOT_WAIT}s for ${NODE_NAME} to reboot and become Ready..."
    if ${DRY_RUN}; then
        log "  [DRY-RUN] Would wait for node Ready"
        return 0
    fi

    local elapsed=0
    # Brief pause for node to actually go down
    sleep 15

    while (( elapsed < REBOOT_WAIT )); do
        local status
        status=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [[ "${status}" == "True" ]]; then
            log "  ${NODE_NAME} is Ready (took ${elapsed}s)"
            return 0
        fi
        sleep "${HEALTH_CHECK_INTERVAL}"
        elapsed=$(( elapsed + HEALTH_CHECK_INTERVAL ))
    done

    log_error "  ${NODE_NAME} did not become Ready within ${REBOOT_WAIT}s"
    return 1
}

node_stabilize() {
    log "  Waiting ${NODE_STABILIZE}s for ${NODE_NAME} to stabilize..."
    if ${DRY_RUN}; then
        log "  [DRY-RUN] Would wait ${NODE_STABILIZE}s"
        return 0
    fi
    sleep "${NODE_STABILIZE}"
    log "  ${NODE_NAME} stabilization complete"
}

# ========================== Post-All-Nodes Finalization ==========================

final_stabilize() {
    log ""
    log "=== All nodes rebooted — final stabilization ==="

    if ${DRY_RUN}; then
        log "[DRY-RUN] Would wait 5min, reconcile Flux, fix alerts, cleanup stale"
        return 0
    fi

    # 1. Wait 5 minutes for everything to fully settle
    log "Waiting ${FINAL_STABILIZE}s for full cluster stabilization..."
    sleep "${FINAL_STABILIZE}"

    # 2. Reconcile Flux kustomizations
    log "Reconciling Flux kustomizations..."
    for ks in flux-system infrastructure-controllers infrastructure-configs apps monitoring-controllers monitoring-configs; do
        flux reconcile kustomization "${ks}" --timeout=60s &>/dev/null || \
            log "  Warning: Failed to reconcile ${ks}"
    done
    local flux_not_ready
    flux_not_ready=$(flux get kustomizations 2>/dev/null | grep -c "False" || true)
    if (( flux_not_ready > 0 )); then
        log "  Warning: ${flux_not_ready} Flux kustomizations not ready"
    else
        log "  All Flux kustomizations reconciled ✓"
    fi

    # 3. Fix alerts — remove silence so Alertmanager re-evaluates cleanly
    delete_silence "${SILENCE_ID}"

    # 4. Check database health
    log "Checking database health..."
    local pg_status mysql_status redis_status
    pg_status=$(kubectl get cluster main-postgres -n databases -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    mysql_status=$(kubectl get ps main-mysql -n databases -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
    redis_status=$(kubectl get pods -n databases -l app=redis -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "unknown")
    log "  PostgreSQL: ${pg_status}"
    log "  MySQL: ${mysql_status}"
    log "  Redis: ${redis_status}"

    # 5. Cleanup completed pods
    local completed
    completed=$(kubectl get pods -A --field-selector='status.phase=Succeeded' --no-headers 2>/dev/null | wc -l || echo 0)
    if (( completed > 0 )); then
        kubectl delete pods -A --field-selector='status.phase=Succeeded' &>/dev/null || true
        log "Cleaned ${completed} completed pods"
    fi

    # 6. Cleanup orphaned ReplicaSets (0/0/0 replicas)
    local orphaned_rs=0
    while IFS=' ' read -r ns name; do
        kubectl delete rs "${name}" -n "${ns}" &>/dev/null || true
        orphaned_rs=$(( orphaned_rs + 1 ))
    done < <(kubectl get rs -A --no-headers 2>/dev/null | awk '$3==0 && $4==0 && $5==0 {print $1, $2}')
    if (( orphaned_rs > 0 )); then
        log "Cleaned ${orphaned_rs} orphaned ReplicaSets"
    fi

    # 7. Final pod health check
    local bad_pods
    bad_pods=$(kubectl get pods -A --no-headers 2>/dev/null | \
        grep -v "Running\|Completed\|Succeeded" | \
        grep -v "^$" || true)
    if [[ -n "${bad_pods}" ]]; then
        log "Warning: Some pods not Running after stabilization:"
        echo "${bad_pods}" | head -10 | tee -a "${LOG_FILE}"
    else
        log "All pods healthy ✓"
    fi

    log "=== Final stabilization complete ==="
}

# ========================== Cluster Health ==========================

check_cluster_health() {
    log "Checking cluster health..."
    local all_ready=true

    for node_def in "${NODES[@]}"; do
        parse_node "${node_def}"
        local status
        status=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [[ "${status}" != "True" ]]; then
            log_error "  ${NODE_NAME} is not Ready (status: ${status})"
            all_ready=false
        fi
    done

    if ! ${all_ready}; then
        log_error "Cluster is not healthy — aborting"
        return 1
    fi

    log "All nodes Ready"
}

# ========================== State Management ==========================

save_state() {
    mkdir -p "${STATE_DIR}"
    cat > "${STATE_FILE}" <<EOF
SILENCE_ID=${SILENCE_ID}
UPDATE_START=${UPDATE_START}
BOT_TOKEN=${BOT_TOKEN}
CHAT_ID=${CHAT_ID}
UPDATED_NODES=${UPDATED_NODES[*]:-}
SKIPPED_NODES=${SKIPPED_NODES[*]:-}
TOTAL_PACKAGES=${TOTAL_PACKAGES}
EOF
    log "State saved to ${STATE_FILE}"
}

load_state() {
    if [[ ! -f "${STATE_FILE}" ]]; then
        log_error "No state file found at ${STATE_FILE}"
        return 1
    fi

    local state_age
    state_age=$(( $(date +%s) - $(stat -c %Y "${STATE_FILE}") ))
    if (( state_age > 86400 )); then
        log_error "State file is stale (${state_age}s old), removing"
        rm -f "${STATE_FILE}"
        return 1
    fi

    # shellcheck disable=SC1090
    source "${STATE_FILE}"

    # shellcheck disable=SC2206
    UPDATED_NODES=(${UPDATED_NODES:-})
    # shellcheck disable=SC2206
    SKIPPED_NODES=(${SKIPPED_NODES:-})

    log "State loaded (silence: ${SILENCE_ID:-none}, started: ${UPDATE_START:-unknown})"
}

# ========================== Main: Phase 1 ==========================

run_phase1() {
    UPDATE_START=$(date '+%Y-%m-%d %H:%M:%S')
    log "=========================================="
    log "Rolling update started at ${UPDATE_START}"
    log "=========================================="

    # Prerequisites
    for cmd in kubectl jq curl ssh checkupdates pacman; do
        if ! command -v "${cmd}" &>/dev/null; then
            log_error "Missing required command: ${cmd}"
            exit 1
        fi
    done

    load_telegram_credentials
    check_cluster_health

    create_silence

    send_telegram "🔄 <b>Rolling OS Update Started</b>

🕐 $(date '+%H:%M %Z')
📋 Order: control-plane → worker-node → worker-node-2
🔇 Alertmanager silenced for ${SILENCE_DURATION_HOURS}h"

    # Process each node sequentially
    for node_def in "${NODES[@]}"; do
        parse_node "${node_def}"
        log ""
        log "--- Processing ${NODE_NAME} ---"

        # Check for updates
        local updates update_count
        updates=$(check_updates)
        update_count=$(echo "${updates}" | grep -c "." || true)
        if [[ -z "${updates}" || "${update_count}" -eq 0 ]]; then
            log "  ${NODE_NAME}: 0 updates, skipping"
            SKIPPED_NODES+=("${NODE_NAME}")
            continue
        fi

        log "  ${NODE_NAME}: ${update_count} updates available"
        log "  Packages: $(echo "${updates}" | head -5 | tr '\n' ', ')..."

        # Control-plane is first — save state, update, reboot self (Phase 2 continues)
        if is_control_plane; then
            TOTAL_PACKAGES=$(( TOTAL_PACKAGES + update_count ))
            save_state

            run_update || {
                send_telegram "❌ <b>Rolling Update Failed</b>

Node: <code>${NODE_NAME}</code>
Stage: pacman -Syu"
                return 1
            }

            send_telegram "🔄 <b>${NODE_NAME}</b>: Updated ${update_count} packages, rebooting...

Phase 2 will resume after reboot."

            # This calls reboot and exits
            reboot_node
            return 0
        fi

        # Worker node: update → reboot → 3min reboot → 3min stabilize
        run_update || {
            send_telegram "❌ <b>Rolling Update Failed</b>

Node: <code>${NODE_NAME}</code>
Stage: pacman -Syu
✅ Updated: ${UPDATED_NODES[*]:-none}"
            return 1
        }

        reboot_node

        wait_for_ready || {
            send_telegram "❌ <b>Rolling Update Failed</b>

Node: <code>${NODE_NAME}</code>
Stage: reboot (did not come back within ${REBOOT_WAIT}s)
✅ Updated: ${UPDATED_NODES[*]:-none}

⚠️ Node may need manual intervention"
            return 1
        }

        node_stabilize

        UPDATED_NODES+=("${NODE_NAME}:${update_count}")
        TOTAL_PACKAGES=$(( TOTAL_PACKAGES + update_count ))

        send_telegram "✅ <b>${NODE_NAME}</b>: Updated ${update_count} packages, back online"
        log "  ${NODE_NAME} completed successfully"
    done

    # All nodes done (or skipped) — final stabilization
    final_stabilize
    send_summary
}

# ========================== Main: Phase 2 (Resume after control-plane reboot) ===========

run_phase2() {
    log "=========================================="
    log "Rolling update Phase 2 (resume after control-plane reboot)"
    log "=========================================="

    load_state || {
        log_error "Cannot resume — no valid state"
        exit 1
    }

    # Wait for K3s API
    log "Waiting for K3s API server..."
    local elapsed=0
    while (( elapsed < 120 )); do
        if kubectl get nodes &>/dev/null; then
            break
        fi
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done

    if ! kubectl get nodes &>/dev/null; then
        log_error "K3s API not ready after 120s"
        send_telegram "❌ <b>Rolling Update Failed</b>

Control-plane rebooted but K3s API not ready after 120s.
Manual intervention needed."
        rm -f "${STATE_FILE}"
        exit 1
    fi

    # Wait for control-plane to be Ready (3min reboot window)
    log "Waiting up to ${REBOOT_WAIT}s for control-plane to become Ready..."
    local cp_ready=false
    elapsed=0
    while (( elapsed < REBOOT_WAIT )); do
        local status
        status=$(kubectl get node gmk-k3s-control-plane -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [[ "${status}" == "True" ]]; then
            cp_ready=true
            log "Control-plane is Ready (took ${elapsed}s)"
            break
        fi
        sleep "${HEALTH_CHECK_INTERVAL}"
        elapsed=$(( elapsed + HEALTH_CHECK_INTERVAL ))
    done

    if ! ${cp_ready}; then
        log_error "Control-plane not Ready after ${REBOOT_WAIT}s"
        send_telegram "❌ <b>Rolling Update Failed</b>

Control-plane rebooted but node not Ready after ${REBOOT_WAIT}s.
Manual intervention needed."
        rm -f "${STATE_FILE}"
        exit 1
    fi

    # 3min stabilization for control-plane
    log "Waiting ${NODE_STABILIZE}s for control-plane to stabilize..."
    sleep "${NODE_STABILIZE}"

    UPDATED_NODES+=("gmk-k3s-control-plane")
    send_telegram "✅ <b>gmk-k3s-control-plane</b>: Rebooted and stable"

    # Continue with remaining worker nodes
    log ""
    log "--- Continuing with worker nodes ---"

    for node_def in "${NODES[@]}"; do
        parse_node "${node_def}"

        # Skip control-plane (already done)
        if is_control_plane; then
            continue
        fi

        log ""
        log "--- Processing ${NODE_NAME} ---"

        # Check for updates
        local updates update_count
        updates=$(check_updates)
        update_count=$(echo "${updates}" | grep -c "." || true)
        if [[ -z "${updates}" || "${update_count}" -eq 0 ]]; then
            log "  ${NODE_NAME}: 0 updates, skipping"
            SKIPPED_NODES+=("${NODE_NAME}")
            continue
        fi

        log "  ${NODE_NAME}: ${update_count} updates available"
        log "  Packages: $(echo "${updates}" | head -5 | tr '\n' ', ')..."

        run_update || {
            send_telegram "❌ <b>Rolling Update Failed</b>

Node: <code>${NODE_NAME}</code>
Stage: pacman -Syu
✅ Updated: ${UPDATED_NODES[*]:-none}"
            rm -f "${STATE_FILE}"
            return 1
        }

        reboot_node

        wait_for_ready || {
            send_telegram "❌ <b>Rolling Update Failed</b>

Node: <code>${NODE_NAME}</code>
Stage: reboot (did not come back within ${REBOOT_WAIT}s)
✅ Updated: ${UPDATED_NODES[*]:-none}

⚠️ Node may need manual intervention"
            rm -f "${STATE_FILE}"
            return 1
        }

        node_stabilize

        UPDATED_NODES+=("${NODE_NAME}:${update_count}")
        TOTAL_PACKAGES=$(( TOTAL_PACKAGES + update_count ))

        send_telegram "✅ <b>${NODE_NAME}</b>: Updated ${update_count} packages, back online"
        log "  ${NODE_NAME} completed successfully"
    done

    # All nodes done — final stabilization
    final_stabilize
    send_summary

    rm -f "${STATE_FILE}"
    log "Phase 2 complete, state cleaned up"
}

# ========================== Summary ==========================

send_summary() {
    local duration=""
    if [[ -n "${UPDATE_START}" ]]; then
        local start_epoch end_epoch
        start_epoch=$(date -d "${UPDATE_START}" +%s 2>/dev/null || echo 0)
        end_epoch=$(date +%s)
        if (( start_epoch > 0 )); then
            local mins=$(( (end_epoch - start_epoch) / 60 ))
            duration=" in ${mins}m"
        fi
    fi

    local updated_str=""
    if [[ ${#UPDATED_NODES[@]} -gt 0 ]]; then
        updated_str=$(printf "  ✅ %s\n" "${UPDATED_NODES[@]}")
    else
        updated_str="  (none)"
    fi

    local skipped_str=""
    if [[ ${#SKIPPED_NODES[@]} -gt 0 ]]; then
        skipped_str=$(printf "  ⏭ %s\n" "${SKIPPED_NODES[@]}")
    fi

    local summary="✅ <b>Rolling OS Update Complete</b>${duration}

<b>Updated:</b>
${updated_str}"

    if [[ -n "${skipped_str}" ]]; then
        summary+="

<b>Skipped (0 updates):</b>
${skipped_str}"
    fi

    summary+="

📦 Total packages: ${TOTAL_PACKAGES}
🕐 $(date '+%H:%M %Z')"

    send_telegram "${summary}"

    log ""
    log "=========================================="
    log "Rolling update completed"
    log "  Updated: ${UPDATED_NODES[*]:-none}"
    log "  Skipped: ${SKIPPED_NODES[*]:-none}"
    log "  Total packages: ${TOTAL_PACKAGES}"
    log "=========================================="
}

# ========================== Entrypoint ==========================

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --resume)
                RESUME=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [--dry-run] [--resume]"
                echo ""
                echo "  --dry-run   Simulate without making changes"
                echo "  --resume    Phase 2: resume after control-plane reboot"
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                exit 1
                ;;
        esac
    done

    if [[ $EUID -ne 0 ]]; then
        log_error "Must run as root"
        exit 1
    fi

    mkdir -p "${STATE_DIR}" "$(dirname "${LOG_FILE}")"

    if ${DRY_RUN}; then
        log "=== DRY RUN MODE ==="
    fi

    if ${RESUME}; then
        acquire_lock
        run_phase2
    else
        acquire_lock
        run_phase1
    fi
}

main "$@"
