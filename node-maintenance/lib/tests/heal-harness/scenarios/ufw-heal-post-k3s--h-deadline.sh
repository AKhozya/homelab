# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/firewall/files/ufw-heal-post-k3s.sh
ARGS=(--cni-heal)
mkdir -p /etc/ufw && echo 'ENABLED=yes' >/etc/ufw/ufw.conf
fake_uptime 1000
k3s_running
kube_proxy_model
stub_at /usr/local/sbin/telegram-notify.sh
kp iptables canary
kp iptables kube-services
kp ip6tables canary
kp ip6tables kube-services
kp ip6tables jumps
kp iptables no-resync
echo "$((FAKE_NOW - 1000))" >/run/ufw-heal-kube-proxy-resync
touch /harness/record-stamp
OUT_FILES=(/run/ufw-heal-kube-proxy-resync /harness/stamp-trace)
