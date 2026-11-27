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
# Another phase H run holds the stamp lock for the whole run.
/usr/bin/flock /run/ufw-heal-kube-proxy-resync.lock sh -c 'touch /harness/lock-held; exec tail -f /dev/null' >/dev/null 2>&1 &
end=$((SECONDS + 10))
until [ -f /harness/lock-held ]; do [ "$SECONDS" -lt "$end" ] || break; done
[ -f /harness/lock-held ] || { echo "setup: the lock holder never took the lock" >&2; exit 2; }
OUT_FILES=(/run/ufw-heal-kube-proxy-resync)
