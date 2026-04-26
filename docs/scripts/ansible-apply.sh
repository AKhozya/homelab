#!/bin/bash
# Trigger ansible sync + drift-heal on CP, with optional rebuilderd verify.
# Run ON the CP node (uses sudo systemctl).
#
# Deploy:
#   scp -P 65300 docs/scripts/ansible-apply.sh akhozya@gmk-k3s-control-plane:~/ansible-apply.sh
#   ssh -p 65300 -t akhozya@gmk-k3s-control-plane "chmod +x ~/ansible-apply.sh && ~/ansible-apply.sh [host]"
#
# Usage (on CP):
#   ./ansible-apply.sh                  # sync + apply
#   ./ansible-apply.sh worker-node-2    # sync + apply + verify W2 rebuilderd
#   ./ansible-apply.sh worker-node      # sync + apply + verify W1 rebuilderd

set -euo pipefail

echo "==> [1/3] Sync git on CP (node-maintenance-sync.service)"
sudo systemctl start node-maintenance-sync.service
sleep 3

echo "==> [2/3] Apply drift-heal (node-maintenance-config.service)"
sudo systemctl start node-maintenance-config.service
sleep 3

echo "==> [3/3] Status + recent logs"
sudo systemctl status node-maintenance-config.service --no-pager | head -15
echo "--- last 40 log lines ---"
sudo journalctl -u node-maintenance-config.service -n 40 --no-pager

case "${1:-}" in
  worker-node-2)
    echo "==> Verify rebuilderd resources on worker-node-2"
    ssh -p 65300 z3us@worker-node-2 "sudo systemctl cat 'rebuilderd-worker@*' 2>/dev/null | grep -E 'MemoryMax|MemoryHigh|MemorySwapMax|MAX_MEMORY|CPUQuota' | sort -u"
    ;;
  worker-node)
    echo "==> Verify rebuilderd resources on worker-node"
    ssh -p 65300 akhozya@worker-node "sudo systemctl cat 'rebuilderd-worker@*' 2>/dev/null | grep -E 'MemoryMax|MemoryHigh|MemorySwapMax|MAX_MEMORY|CPUQuota' | sort -u"
    ;;
esac

echo "==> done"
