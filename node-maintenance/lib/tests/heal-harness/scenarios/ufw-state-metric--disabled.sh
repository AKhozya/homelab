# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/firewall/files/ufw-state-metric.sh
mkdir -p /etc/ufw && echo 'ENABLED=yes' >/etc/ufw/ufw.conf
echo 'ENABLED=no' >/etc/ufw/ufw.conf
behave systemctl <<'EOF'
rc=3
EOF
