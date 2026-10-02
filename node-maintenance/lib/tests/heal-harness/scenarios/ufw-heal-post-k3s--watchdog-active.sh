# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/firewall/files/ufw-heal-post-k3s.sh
behave date <<'EOF'
n=$(( $(cat /harness/clock 2>/dev/null || echo 0) + 1 )); echo "$n" >/harness/clock
if [ "${1:-}" = "+%s" ]; then echo $((FAKE_NOW + n * 5)); else echo "Fri Oct  2 20:00:00 UTC 2026"; fi
EOF
mkdir -p /etc/ufw && echo 'ENABLED=yes' >/etc/ufw/ufw.conf
ARGS=(--watchdog)
behave iptables-save <<'EOF'
cat /harness-src/inputs/iptables-save.v4
EOF
behave ip6tables-save <<'EOF'
cat /harness-src/inputs/iptables-save.v6
EOF
behave ufw <<'EOF'
case "$*" in status*) echo 'Status: active' ;; '--force enable') echo 'Firewall is active and enabled on system startup' ;; esac
EOF
