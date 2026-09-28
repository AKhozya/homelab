#!/bin/bash
# Trigger ansible sync + drift-heal on CP.
# Run ON the CP node (uses sudo systemctl).
#
# Deploy:
#   scp -P 65300 scripts/ansible-apply.sh akhozya@gmk-k3s-control-plane:~/ansible-apply.sh
#   ssh -p 65300 -t akhozya@gmk-k3s-control-plane "chmod +x ~/ansible-apply.sh && ~/ansible-apply.sh"
#
# Usage (on CP):
#   ./ansible-apply.sh                  # sync + apply, all nodes

set -euo pipefail

# sync-from-git.sh starts the config unit itself if the pull brought a new commit, so
# step 2 runs only if that did not happen. The unit's start timestamp tells which.
config_started() {
    systemctl show -p ExecMainStartTimestampMonotonic --value node-maintenance-config.service
}

before=$(config_started)
echo "==> [1/3] Sync git on CP (node-maintenance-sync.service)"
sudo systemctl start node-maintenance-sync.service

# A plain assignment, so set -e stops the script if the query fails; inside the test
# a failure would read as "changed" and skip the heal.
after=$(config_started)
if [ "$after" = "$before" ]; then
    echo "==> [2/3] Apply drift-heal (node-maintenance-config.service)"
    sudo systemctl start node-maintenance-config.service
else
    echo "==> [2/3] Sync already ran drift-heal; skipping a second run"
fi

echo "==> [3/3] Status + recent logs"
# A finished oneshot is inactive, so status exits 3; that must not end the script
# before the logs print.
sudo systemctl status node-maintenance-config.service --no-pager | head -15 || true
echo "--- last 40 log lines ---"
sudo journalctl -u node-maintenance-config.service -n 40 --no-pager

echo "==> done"
