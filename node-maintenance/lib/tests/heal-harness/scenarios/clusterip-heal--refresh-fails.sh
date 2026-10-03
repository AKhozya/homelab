# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/clusterip_heal/files/clusterip-heal.sh
OUT_FILES=(/var/lib/node-maintenance/clusterip-heal.state /var/lib/k3s-agent-restart/cooldown)
stub_at /etc/node-maintenance/bin/clusterip-probe.sh
behave_seq clusterip-probe.sh "1"
mount --bind /var/lib/node-maintenance /var/lib/node-maintenance
behave systemctl <<'EOF'
[ "$1" = restart ] && mount -o remount,bind,ro /var/lib/node-maintenance
EOF
