# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/firewall_preflight/files/firewall-preflight.sh
OUT_FILES=(/var/lib/node_exporter/textfile/firewall_preflight_probe.counter)
behave date <<'EOF'
n=$(( $(cat /harness/clock 2>/dev/null || echo 0) + 1 )); echo "$n" >/harness/clock
if [ "${1:-}" = "+%s" ]; then echo $((FAKE_NOW + n * 5)); else echo "Fri Oct  2 20:00:00 UTC 2026"; fi
EOF
mkdir -p /etc/ufw && echo 'ENABLED=yes' >/etc/ufw/ufw.conf
printf '%s\n' '*filter' ':ufw-before-input - [0:0]' ':ufw-user-input - [0:0]' 'COMMIT' >/etc/ufw/user.rules
printf '%s\n' '*filter' ':ufw6-user-input - [0:0]' 'COMMIT' >/etc/ufw/user6.rules
behave iptables-save <<'EOF'
n=$(( $(cat /harness/churn 2>/dev/null || echo 0) + 1 )); echo "$n" >/harness/churn
cat /harness-src/inputs/iptables-save.v4
echo "-A ufw-user-input -m comment --comment churn-$n -j RETURN"
EOF
behave ip6tables-save <<'EOF'
cat /harness-src/inputs/iptables-save.v6
EOF
behave ufw <<'EOF'
case "$*" in status*) echo 'Status: active' ;; '--force enable') echo 'Firewall is active and enabled on system startup' ;; esac
EOF
