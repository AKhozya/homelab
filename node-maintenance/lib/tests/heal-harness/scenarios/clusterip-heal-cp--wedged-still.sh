# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/clusterip_heal_cp/files/clusterip-heal-cp.sh
OUT_FILES=(/var/lib/node-maintenance/clusterip-heal-cp.state)
stub_at /usr/local/sbin/clusterip-probe-cp.sh
behave_seq clusterip-probe-cp.sh "1"
# The restart moves the clock 200 s, so the saved `last` tells the save after the restart from the one before it.
behave systemctl <<'EOF'
[ "$1" = restart ] && echo "$((FAKE_NOW + 200))" >/harness/now
EOF
