# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/clusterip_heal_cp/files/clusterip-heal-cp.sh
OUT_FILES=(/var/lib/node-maintenance/clusterip-heal-cp.state)
stub_at /usr/local/sbin/clusterip-probe-cp.sh
behave_seq clusterip-probe-cp.sh "1 0"
# The restart sets the clock to FAKE_NOW + 200, so the saved `last` tells the save after the restart from the one before it.
behave systemctl <<'EOF'
[ "$1" = restart ] && echo "$((FAKE_NOW + 200))" >/harness/now
EOF
# Stale values, so a run that misses a metric update shows it in the fixture.
printf '%s\n' 'node_clusterip_heal_wedged 1' 'node_clusterip_heal_restarts_total 4' 'node_clusterip_heal_giveup 1' >/var/lib/node_exporter/textfile/clusterip_heal_cp.prom
echo "$((FAKE_NOW - 100)) 1 5 $((FAKE_NOW - 1000))" >/var/lib/node-maintenance/clusterip-heal-cp.state
echo "$((FAKE_NOW - 20))" >/run/ufw-heal-kube-proxy-resync
# Phase H deletes the canary again 15 s into the first wait.
behave sleep <<'EOF'
now=$(cat /harness/now 2>/dev/null || echo "$FAKE_NOW")
if [ ! -f /harness/redeleted ]; then
	touch /harness/redeleted
	echo "$((now + 15))" >/run/ufw-heal-kube-proxy-resync.new && mv -fT /run/ufw-heal-kube-proxy-resync.new /run/ufw-heal-kube-proxy-resync
fi
echo "$((now + $1))" >/harness/now
EOF
