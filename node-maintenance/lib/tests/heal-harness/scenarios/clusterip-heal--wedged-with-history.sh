# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/clusterip_heal/files/clusterip-heal.sh
OUT_FILES=(/var/lib/node-maintenance/clusterip-heal.state /var/lib/k3s-agent-restart/cooldown)
stub_at /etc/node-maintenance/bin/clusterip-probe.sh
behave_seq clusterip-probe.sh "1"
# Earlier restarts in this window, past the cooldown: count and total differ, so the state file
# shows which field each value went to.
echo "$((FAKE_NOW - 900)) 1 5 $((FAKE_NOW - 600))" >/var/lib/node-maintenance/clusterip-heal.state
