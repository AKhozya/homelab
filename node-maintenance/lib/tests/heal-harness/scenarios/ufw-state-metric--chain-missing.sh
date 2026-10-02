# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/firewall/files/ufw-state-metric.sh
mkdir -p /etc/ufw && echo 'ENABLED=yes' >/etc/ufw/ufw.conf
behave iptables <<'EOF'
[ "$2" = ufw-user-input ] && rc=1
EOF
