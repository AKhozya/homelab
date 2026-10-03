# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/clusterip_heal/files/clusterip-heal.sh
OUT_FILES=(/var/lib/node-maintenance/clusterip-heal.state /var/lib/k3s-agent-restart/cooldown)
stub_at /etc/node-maintenance/bin/clusterip-probe.sh
behave_seq clusterip-probe.sh "1"
# The restart moves the clock 200 s, so the saved `last` tells the save after the restart from the one before it.
behave systemctl <<'EOF'
[ "$1" = restart ] && echo "$((FAKE_NOW + 200))" >/harness/now && rc=1
EOF
