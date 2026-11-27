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
kp iptables resync-canary-first
kp iptables resync-delay 3
kp ip6tables jumps
OUT_FILES=(/run/ufw-heal-kube-proxy-resync)
# The wall clock follows the fake uptime, so the two deletes write different stamps.
behave date <<'EOB'
read -r up _ </proc/uptime
if [ "${1:-}" = "+%s" ]; then echo "$((FAKE_NOW + ${up%.*} - 1000))"; else echo "Sat Oct  3 20:00:00 UTC 2026"; fi
EOB
