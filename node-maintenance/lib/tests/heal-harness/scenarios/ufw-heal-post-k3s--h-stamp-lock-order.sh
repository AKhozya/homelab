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
# The clock read records whether the stamp lock is held at that moment: it must be.
behave date <<'EOB'
if [ "${1:-}" = "+%s" ]; then
	if /usr/bin/flock -n /run/ufw-heal-kube-proxy-resync.lock true 2>/dev/null; then echo unlocked; else echo locked; fi >>/harness/date-lock
	cat /harness/now 2>/dev/null || echo "$FAKE_NOW"
else
	echo "Sat Oct  3 20:00:00 UTC 2026"
fi
EOB
OUT_FILES=(/run/ufw-heal-kube-proxy-resync /harness/date-lock)
