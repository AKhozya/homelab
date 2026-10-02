# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/clusterip_heal/files/clusterip-heal.sh
OUT_FILES=(/var/lib/node-maintenance/clusterip-heal.state /var/lib/k3s-agent-restart/cooldown)
stub_at /etc/node-maintenance/bin/clusterip-probe.sh
behave_seq clusterip-probe.sh "1"
echo "$((FAKE_NOW - 100)) 3 7 $((FAKE_NOW - 400))" >/var/lib/node-maintenance/clusterip-heal.state
