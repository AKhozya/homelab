# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/clusterip_heal_cp/files/clusterip-heal-cp.sh
OUT_FILES=(/var/lib/node-maintenance/clusterip-heal-cp.state)
stub_at /usr/local/sbin/clusterip-probe-cp.sh
behave_seq clusterip-probe-cp.sh "1"
# timeout exits 124 when it kills systemctl; the stub returns the same code.
behave systemctl <<'EOF'
[ "$1" = restart ] && rc=124
EOF
