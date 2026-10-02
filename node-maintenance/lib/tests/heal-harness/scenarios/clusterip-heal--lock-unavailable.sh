# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/clusterip_heal/files/clusterip-heal.sh
OUT_FILES=(/var/lib/node-maintenance/clusterip-heal.state /var/lib/k3s-agent-restart/cooldown)
stub_at /etc/node-maintenance/bin/clusterip-probe.sh
behave_seq clusterip-probe.sh "1"
# The shared cooldown directory cannot be written, so the lock file cannot be opened.
mkdir -p /var/lib/k3s-agent-restart
mount --bind /var/lib/k3s-agent-restart /var/lib/k3s-agent-restart
mount -o remount,bind,ro /var/lib/k3s-agent-restart
