# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/clusterip_heal_cp/files/clusterip-heal-cp.sh
OUT_FILES=(/var/lib/node-maintenance/clusterip-heal-cp.state)
stub_at /usr/local/sbin/clusterip-probe-cp.sh
behave_seq clusterip-probe-cp.sh "1"
echo "$((FAKE_NOW - 100)) 3 7 $((FAKE_NOW - 400))" >/var/lib/node-maintenance/clusterip-heal-cp.state
