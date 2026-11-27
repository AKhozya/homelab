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
# Another phase H run holds the stamp lock until the writer waits on it, then releases it: the
# writer must wait, take the lock and publish.
cat >/harness/hold.sh <<'EOH'
touch /harness/lock-held
end=$((SECONDS + 30))
until pgrep -f 'flock -w 2 9' >/dev/null; do [ "$SECONDS" -lt "$end" ] || break; done
# The fixture records this marker, so a run without contention (the holder timed out) differs.
pgrep -f 'flock -w 2 9' >/dev/null && touch /harness/writer-seen
EOH
/usr/bin/flock /run/ufw-heal-kube-proxy-resync.lock bash /harness/hold.sh >/dev/null 2>&1 &
end=$((SECONDS + 10))
until [ -f /harness/lock-held ]; do [ "$SECONDS" -lt "$end" ] || break; done
[ -f /harness/lock-held ] || { echo "setup: the lock holder never took the lock" >&2; exit 2; }
OUT_FILES=(/run/ufw-heal-kube-proxy-resync /harness/writer-seen)
