#!/bin/bash
# check-phase2-flag-age.sh — ExecCondition for config.service
#
# Replaces static ConditionPathExists=!/var/lib/node-maintenance/phase2-pending.
# Behaviour:
#   - No flag → exit 0 (proceed with drift-heal)
#   - Flag < MAX_AGE_SEC → exit 1 (skip, maintenance in progress)
#   - Flag >= MAX_AGE_SEC + Flux healthy → rm flag, notify, exit 0 (auto-clear)
#   - Flag >= MAX_AGE_SEC + Flux unhealthy → exit 1 (keep blocking)
#
# Exit codes per systemd ExecCondition semantics (systemd >= 243):
#   0       = proceed (start the service)
#   1-254   = skip (not a failure)
#   255     = hard failure
#
# Deployed by firewall ansible role → /usr/local/sbin/check-phase2-flag-age.sh

set -euo pipefail

FLAG=/var/lib/node-maintenance/phase2-pending
KUBECONFIG=/etc/rancher/k3s/k3s.yaml
MAX_AGE_SEC=7200  # 2 hours
NOTIFY=/usr/local/sbin/telegram-notify.sh

# No flag → proceed with drift-heal
if [ ! -f "$FLAG" ]; then
    exit 0
fi

# Flag exists — check age
FLAG_MTIME=$(stat -c %Y "$FLAG")
NOW=$(date +%s)
AGE=$(( NOW - FLAG_MTIME ))

if [ "$AGE" -lt "$MAX_AGE_SEC" ]; then
    echo "phase2-pending flag exists (age: ${AGE}s < ${MAX_AGE_SEC}s) — skipping drift-heal"
    exit 1  # skip, not a failure
fi

# Flag is stale (>2h). Verify Flux is healthy before clearing.
if kubectl --kubeconfig="$KUBECONFIG" get kustomization -n flux-system -o json 2>/dev/null \
    | jq -e '[.items[] | select(.status.conditions[]? | select(.type=="Ready") | .status != "True")] | length == 0' >/dev/null 2>&1; then
    echo "phase2-pending flag is ${AGE}s old (>${MAX_AGE_SEC}s) and Flux is healthy — auto-clearing"
    rm -f "$FLAG"
    if [ -x "$NOTIFY" ]; then
        "$NOTIFY" "⚠️ Auto-cleared stale phase2-pending flag (age: $((AGE / 60))min). Flux healthy. Drift-heal proceeding." || true
    fi
    exit 0  # proceed with drift-heal
else
    echo "phase2-pending flag is stale (${AGE}s) but Flux is NOT healthy — keeping flag, skipping drift-heal"
    exit 1  # skip, not a failure
fi
