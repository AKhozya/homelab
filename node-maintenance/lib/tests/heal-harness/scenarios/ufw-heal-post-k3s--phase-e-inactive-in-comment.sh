# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/firewall/files/ufw-heal-post-k3s.sh
mkdir -p /etc/ufw && echo 'ENABLED=yes' >/etc/ufw/ufw.conf
ARGS=(--watchdog)
fake_uptime 1000
behave ufw <<'EOF'
r=$(cat /harness/seq-ufw-reload 2>/dev/null || echo 0)
case "$*" in
reload)
	r=$((r + 1)); echo "$r" >/harness/seq-ufw-reload
	[ "$r" -le 4 ] && { echo 'ERROR: problem running iptables'; rc=1; }
	;;
'--force enable') echo 'ERROR: problem running ip6tables'; rc=1 ;;
status*)
	if [ "$r" -eq 4 ]; then
		printf '%s\n' 'Status: active' '' 'To                         Action      From' '22/tcp                     ALLOW       Anywhere                   # Status: inactive'
	elif [ "$r" -ge 5 ]; then echo 'Status: active'
	else echo 'Status: inactive'; fi
	;;
esac
EOF
