# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/k3s_config/files/k3s-wait-ready.sh
OUT_FILES=(/run/k3s-ready)
behave date <<'EOF'
n=$(( $(cat /harness/clock 2>/dev/null || echo 0) + 1 )); echo "$n" >/harness/clock
if [ "${1:-}" = "+%s" ]; then echo $((FAKE_NOW + n * 5)); else echo "Fri Oct  2 20:00:00 UTC 2026"; fi
EOF
behave iptables-save <<'EOF'
n=$(( $(cat /harness/churn 2>/dev/null || echo 0) + 1 )); echo "$n" >/harness/churn
cat /harness-src/inputs/iptables-save.v4
echo "-A ufw-user-input -m comment --comment churn-$n -j RETURN"
EOF
behave ip6tables-save <<'EOF'
cat /harness-src/inputs/iptables-save.v6
EOF
