#!/usr/bin/env bash
#
# Run node-maintenance (sync + drift-heal) and restart k3s on the control plane and the
# two general-purpose workers. immich-vm is a k3s node too, but it is excluded here.
#
# Order: CP, then W1, then W2. Stops on the first failure (set -e).
# Each ssh -t opens a TTY so the sudo password prompt works interactively.
#
# Usage: ./scripts/cluster-maintenance-run.sh

set -euo pipefail

run_on_node() {
    local label="$1"
    local host="$2"
    local user="$3"
    local k3s_unit="$4"

    echo
    echo "=== ${label} (${user}@${host}) ==="
    ssh -t -p 65300 "${user}@${host}" "
        set -euo pipefail
        sudo systemctl start node-maintenance-sync.service
        sudo systemctl start node-maintenance-config.service
        sudo systemctl restart ${k3s_unit}
    "
    echo "=== ${label} done ==="
}

run_on_node "CP"  "gmk-k3s-control-plane" "akhozya" "k3s"
run_on_node "W1"  "worker-node"            "akhozya" "k3s-agent"
run_on_node "W2"  "worker-node-2"          "z3us"    "k3s-agent"

echo
echo "All nodes complete."
