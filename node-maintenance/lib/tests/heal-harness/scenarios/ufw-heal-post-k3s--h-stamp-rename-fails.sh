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
echo "$((FAKE_NOW - 1000))" >/run/ufw-heal-kube-proxy-resync
# /usr/local/bin comes before /usr/bin on PATH, so only the rename fails; mktemp and the write work.
stub_at /usr/local/bin/mv
echo 'rc=1' | behave mv
OUT_FILES=(/run/ufw-heal-kube-proxy-resync)
