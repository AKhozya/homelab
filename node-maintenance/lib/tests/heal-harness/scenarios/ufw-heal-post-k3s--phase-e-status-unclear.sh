# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/firewall/files/ufw-heal-post-k3s.sh
mkdir -p /etc/ufw && echo 'ENABLED=yes' >/etc/ufw/ufw.conf
ARGS=(--watchdog)
fake_uptime 1000
behave ufw <<'EOF'
case "$*" in
reload)
	r=$(( $(cat /harness/seq-ufw-reload 2>/dev/null || echo 0) + 1 )); echo "$r" >/harness/seq-ufw-reload
	[ "$r" -le 3 ] && { echo 'ERROR: problem running iptables'; rc=1; }
	;;
'--force enable') echo 'ERROR: problem running ip6tables'; rc=1 ;;
status*)
	r=$(cat /harness/seq-ufw-reload 2>/dev/null || echo 0)
	if [ "$r" -lt 4 ]; then echo 'Status: inactive'; else echo 'Status: active'; rc=124; fi
	;;
esac
EOF
