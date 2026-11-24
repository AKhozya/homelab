# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/firewall/files/ufw-heal-post-k3s.sh
mkdir -p /etc/ufw && echo 'ENABLED=yes' >/etc/ufw/ufw.conf
ARGS=(--watchdog)
fake_uptime 1000
# Phase B fails all three attempts. Phase E's first reload exits 0 but reports a skip, and UFW
# then reads active: that reload must not count, so phase E reloads a second time.
behave ufw <<'EOS'
r=$(cat /harness/seq-ufw-reload 2>/dev/null || echo 0)
case "$*" in
reload)
	r=$((r + 1)); echo "$r" >/harness/seq-ufw-reload
	if [ "$r" -le 3 ]; then echo 'ERROR: problem running iptables'; rc=1
	elif [ "$r" -eq 4 ]; then echo 'Firewall not enabled (skipping reload)'; fi
	;;
'--force enable') echo 'ERROR: problem running ip6tables'; rc=1 ;;
status*)
	if [ "$r" -ge 4 ]; then echo 'Status: active'; else echo 'Status: inactive'; fi
	;;
esac
EOS
