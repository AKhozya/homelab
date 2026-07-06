#!/bin/bash
# Trigger ansible sync + drift-heal on CP.
# Run ON the CP node (uses sudo systemctl).
#
# Deploy:
#   scp -P 65300 docs/scripts/ansible-apply.sh akhozya@gmk-k3s-control-plane:~/ansible-apply.sh
#   ssh -p 65300 -t akhozya@gmk-k3s-control-plane "chmod +x ~/ansible-apply.sh && ~/ansible-apply.sh [host]"
#
# Usage (on CP):
#   ./ansible-apply.sh                  # sync + apply

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

echo "==> done"
