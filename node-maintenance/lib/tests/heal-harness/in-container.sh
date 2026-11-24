#!/bin/bash
# Runs one scenario inside the harness container (archlinux, --privileged, repo mounted at /repo,
# harness sources at /harness-src, results written to /out). Stubs every host command the node
# scripts change state with, so a run touches nothing real, and records each call in order.
set -euo pipefail
scenario="$1"

mkdir -p /harness/behavior /out/textfile /out/state
: >/harness/calls.log

# Each name below becomes a logging stub, on PATH and at /usr/bin (/usr/sbin links there), so an
# absolute path such as /usr/sbin/iptables reaches the stub too. rm first: iptables and ip6tables
# are symlinks to one xtables binary, and writing through a link would replace that binary.
STUBBED=(systemctl logger date sleep hostname curl ping vainfo kubectl journalctl mountpoint
	iptables ip6tables iptables-save ip6tables-save iptables-restore ip6tables-restore iptables-legacy nft ufw
	modprobe lsmod xtables-monitor)
for c in "${STUBBED[@]}"; do
	rm -f "/usr/bin/$c"
	install -m 0755 /harness-src/stub.sh "/usr/bin/$c"
done

# The fake clock makes state files and wedged-seconds values the same on every run. A scenario
# moves it by writing seconds since the epoch to /harness/now, for example from a restart stub.
export FAKE_NOW=1791057600
cat >/harness/behavior/date <<'EOF'
now="$(cat /harness/now 2>/dev/null || echo "$FAKE_NOW")"
if [ "${1:-}" = "+%s" ]; then echo "$now"; else echo "Sat Oct  3 20:00:00 UTC 2026"; fi
EOF
echo 'echo harness-node' >/harness/behavior/hostname
echo harness-node >/etc/hostname

# stub_at PATH: a logging stub at an absolute path the script calls directly (a probe script).
stub_at() {
	mkdir -p "$(dirname "$1")"
	install -m 0755 /harness-src/stub.sh "$1"
}
# behave CMD: the scenario writes CMD's behaviour snippet on stdin.
behave() { cat >"/harness/behavior/$1"; }
# behave_seq CMD "RC1 RC2 ...": the Nth call to CMD exits with RCN; calls past the list repeat the last.
behave_seq() {
	printf 'n=$(( $(cat /harness/seq-%s 2>/dev/null || echo 0) + 1 )); echo "$n" >/harness/seq-%s\nset -- %s\nrc=${!n:-${!#}}\n' \
		"$1" "$1" "$2" >"/harness/behavior/$1"
}

# fake_uptime SECONDS: ufw-heal-post-k3s.sh times its waits and its budget on /proc/uptime. If the
# stubbed sleep left /proc/uptime on real time, the poll count would vary between runs. The stub
# advances this test clock by whole seconds and exits 2 on a fractional argument.
fake_uptime() {
	echo "$1.00 0.00" >/harness/uptime
	mount --bind /harness/uptime /proc/uptime
	behave sleep <<'EOF'
case $1 in *[!0-9]*) echo "fake_uptime: sleep $1 is not whole seconds" >&2; exit 2 ;; esac
read -r up _ </harness/uptime
echo "$(( ${up%.*} + $1 )).00 0.00" >/harness/uptime
EOF
}

# k3s_running: ufw-heal-post-k3s.sh takes the iptables binary from the PATH of K3s's main process.
# The stub reports MainPID 1, and PID 1's PATH leads to the /usr/bin stub.
k3s_running() {
	behave systemctl <<'EOF'
case "$*" in *"show -p MainPID --value k3s-agent.service"*) echo 1 ;; esac
EOF
}

# kube_proxy_model: the iptables and ip6tables stubs answer the heal script's reads of kube-proxy's
# rules from per-family state in /harness/kp/<binary>/. Flags a scenario sets there:
#   canary  kube-services  jumps     the mangle canary, the nat KUBE-SERVICES chain, the 5 jumps
#   absent-<CHAIN>                   if jumps exists, omit this chain's jumps (PREROUTING, OUTPUT,
#                                    POSTROUTING, or FORWARD: both of its jumps)
#   absent-FIREWALL                  if jumps exists, omit FORWARD -> KUBE-PROXY-FIREWALL
#   absent-EARLY                     if jumps exists, omit INPUT -> KUBE-EXTERNAL-SERVICES (an early
#                                    filter jump) and keep the FORWARD jumps
#   site-firewall-rule               FORWARD also holds a source-restricted rule to
#                                    KUBE-PROXY-FIREWALL under another comment, ahead of kube-proxy's;
#                                    a sync keeps it
#   read-fail-nth                    only the Nth jump chain read exits 4 (counting from 1)
#   canary-rc-<rc>                   the mangle canary read exits <rc>; the stub removes the flag after
#                                    one read
#   read-fail-<n>                    the next <n> reads of a jump chain exit 4 (lock busy)
#   no-resync                        a canary delete never brings the jumps back
#   resync-delay                     seconds (on the fake uptime) from a canary delete to the jumps
#   resync-at                        uptime of the next simulated full sync: the canary and all 5
#                                    jumps return (but see resync-canary-first)
#   appear-at                        uptime at which kube-proxy starts: the canary, KUBE-SERVICES and
#                                    the jumps appear, any absent-<CHAIN> flag still applying
#   lose-at                          at this uptime, remove all the jumps once
#   fail-reads-from                   from this uptime on, every read of a jump chain exits 4
#   appear-at-call                   at this call of this family's binary (counting from 1), the
#                                    family appears as with appear-at
#   nat-read-fail                    phase G's read of the whole nat table exits 4
#   nat-read-fail-call               only the Nth whole nat table read exits 4 (counting from 1)
#   firewall-wrong-state             if jumps exists, the KUBE-PROXY-FIREWALL jump matches
#                                    --ctstate ESTABLISHED instead of NEW
#   portmap                          the nat table has CNI-HOSTPORT-DNAT without its entry jumps
#   portmap-check-rcs                the exit codes of successive iptables -C calls, one per line;
#                                    after the list, -C reports whether an earlier -A added the rule
#   resync-canary-first              the first full sync brings back only the canary
#   restricted-<CHAIN>               if jumps exists, the PREROUTING or OUTPUT jump carries a source
#                                    restriction (-s 192.0.2.1/32), the comment and target unchanged
#   start-v6-on-forward-read         IPv4's FORWARD read starts IPv6's kube-proxy (canary,
#                                    KUBE-SERVICES and jumps appear)
# If neither no-resync nor resync-at exists, deleting the mangle canary schedules a sync. If the
# canary is absent, iptables -X fails. The nat canary delete always succeeds: the heal script ignores its result.
kube_proxy_model() {
	mkdir -p /harness/kp/iptables /harness/kp/ip6tables
	for c in iptables ip6tables; do
		cat >"/harness/behavior/$c" <<'EOF'
d=/harness/kp/$cmd
read -r up _ </proc/uptime
up=${up%.*}
calls=$(( $(cat "$d/calls" 2>/dev/null || echo 0) + 1 )); echo "$calls" >"$d/calls"
if [ -f "$d/appear-at-call" ] && [ "$calls" -ge "$(cat "$d/appear-at-call")" ]; then
	touch "$d/jumps" "$d/canary" "$d/kube-services"
	rm -f "$d/appear-at-call"
fi
if [ -f "$d/resync-at" ] && [ "$up" -ge "$(cat "$d/resync-at")" ]; then
	if [ -f "$d/resync-canary-first" ]; then
		touch "$d/canary"
		rm -f "$d/resync-canary-first"
	else
		touch "$d/jumps" "$d/canary"
		rm -f "$d"/absent-* "$d"/restricted-* "$d/firewall-wrong-state"
	fi
	rm -f "$d/resync-at"
fi
if [ -f "$d/appear-at" ] && [ "$up" -ge "$(cat "$d/appear-at")" ]; then
	touch "$d/jumps" "$d/canary" "$d/kube-services"
	rm -f "$d/appear-at"
fi
if [ -f "$d/lose-at" ] && [ "$up" -ge "$(cat "$d/lose-at")" ]; then
	rm -f "$d/jumps" "$d/lose-at"
fi
read_fail() {
	local f n
	n=$(( $(cat "$d/chain-reads" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$d/chain-reads"
	[ "$(cat "$d/read-fail-nth" 2>/dev/null)" = "$n" ] && return 0
	if [ -f "$d/fail-reads-from" ] && [ "$up" -ge "$(cat "$d/fail-reads-from")" ]; then return 0; fi
	f=$(ls "$d"/read-fail-* 2>/dev/null | head -1)
	[ -n "$f" ] || return 1
	n=${f##*-}
	rm -f "$f"
	[ "$n" -gt 1 ] && touch "$d/read-fail-$((n - 1))"
	return 0
}
# jumps TABLE CHAIN: kube-proxy's and kubelet's jumps in that built-in chain, as the flags shape them.
jumps() {
	local tb=$1 ch=$2
	[ -f "$d/jumps" ] && [ ! -f "$d/absent-$ch" ] || {
		[ "$ch" = FORWARD ] && [ -f "$d/site-firewall-rule" ] &&
			echo '-A FORWARD -s fd00::/8 -m conntrack --ctstate NEW -m comment --comment "site firewall" -j KUBE-PROXY-FIREWALL'
		return 0
	}
	local new='-m conntrack --ctstate NEW'
	case $tb/$ch in
	filter/INPUT)
		[ -f "$d/absent-EARLY" ] || echo "-A INPUT $new -m comment --comment \"kubernetes externally-visible service portals\" -j KUBE-EXTERNAL-SERVICES"
		echo '-A INPUT -m comment --comment "kubernetes health check service ports" -j KUBE-NODEPORTS'
		echo "-A INPUT $new -m comment --comment \"kubernetes load balancer firewall\" -j KUBE-PROXY-FIREWALL"
		echo '-A INPUT -j KUBE-FIREWALL'
		;;
	filter/FORWARD)
		echo "-A FORWARD $new -m comment --comment \"kubernetes externally-visible service portals\" -j KUBE-EXTERNAL-SERVICES"
		echo "-A FORWARD $new -m comment --comment \"kubernetes service portals\" -j KUBE-SERVICES"
		echo '-A FORWARD -m comment --comment "kubernetes forwarding rules" -j KUBE-FORWARD'
		[ -f "$d/site-firewall-rule" ] &&
			echo '-A FORWARD -s fd00::/8 -m conntrack --ctstate NEW -m comment --comment "site firewall" -j KUBE-PROXY-FIREWALL'
		if [ -f "$d/firewall-wrong-state" ]; then
			echo '-A FORWARD -m conntrack --ctstate ESTABLISHED -m comment --comment "kubernetes load balancer firewall" -j KUBE-PROXY-FIREWALL'
		elif [ ! -f "$d/absent-FIREWALL" ]; then
			echo "-A FORWARD $new -m comment --comment \"kubernetes load balancer firewall\" -j KUBE-PROXY-FIREWALL"
		fi
		;;
	filter/OUTPUT)
		echo "-A OUTPUT $new -m comment --comment \"kubernetes service portals\" -j KUBE-SERVICES"
		echo "-A OUTPUT $new -m comment --comment \"kubernetes load balancer firewall\" -j KUBE-PROXY-FIREWALL"
		echo '-A OUTPUT -j KUBE-FIREWALL'
		;;
	nat/PREROUTING | nat/OUTPUT)
		if [ -f "$d/restricted-$ch" ]; then
			echo "-A $ch -s 192.0.2.1/32 -m comment --comment \"kubernetes service portals\" -j KUBE-SERVICES"
		else
			echo "-A $ch -m comment --comment \"kubernetes service portals\" -j KUBE-SERVICES"
		fi
		;;
	nat/POSTROUTING) echo '-A POSTROUTING -m comment --comment "kubernetes postrouting rules" -j KUBE-POSTROUTING' ;;
	esac
}
case "$*" in
*"-t mangle -S KUBE-PROXY-CANARY"*)
	f=$(ls "$d"/canary-rc-* 2>/dev/null | head -1)
	if [ -n "$f" ]; then
		rc=${f##*-}
		rm -f "$f"
	elif [ -f "$d/canary" ]; then
		echo "-N KUBE-PROXY-CANARY"
	else
		rc=1
	fi
	;;
*"-t mangle -X KUBE-PROXY-CANARY"*)
	if [ -f "$d/canary" ]; then
		rm -f "$d/canary"
		[ -f "$d/no-resync" ] || [ -f "$d/resync-at" ] ||
			echo $((up + $(cat "$d/resync-delay" 2>/dev/null || echo 10))) >"$d/resync-at"
	else
		echo "iptables: No chain/target/match by that name." >&2
		rc=1
	fi
	;;
*"-t nat -X KUBE-PROXY-CANARY"*) ;;
*"-t nat -S")
	nreads=$(( $(cat "$d/nat-reads" 2>/dev/null || echo 0) + 1 )); echo "$nreads" >"$d/nat-reads"
	if [ -f "$d/nat-read-fail" ] || [ "$(cat "$d/nat-read-fail-call" 2>/dev/null)" = "$nreads" ]; then
		rc=4
	else
		for ch in PREROUTING OUTPUT POSTROUTING; do jumps nat $ch; done
		[ -f "$d/portmap" ] && echo "-N CNI-HOSTPORT-DNAT"
		cat "$d/portmap-rules" 2>/dev/null
	fi
	;;
*"-t nat -C"*)
	rc=$(head -1 "$d/portmap-check-rcs" 2>/dev/null)
	[ -f "$d/portmap-check-rcs" ] && sed -i 1d "$d/portmap-check-rcs"
	if [ -z "$rc" ]; then
		# The arguments after -C, one shell-quoted word each, so argument boundaries count.
		args=("$@"); key=""; on=0
		for a in "${args[@]}"; do [ "$on" -eq 1 ] && key+="$(printf '%q' "$a") "; [ "$a" = -C ] && on=1; done
		if grep -qxF -- "$key" "$d/portmap-keys" 2>/dev/null; then rc=0; else rc=1; fi
	fi
	;;
*"-t nat -A"*)
	args=("$@"); key=""; on=0
	for a in "${args[@]}"; do [ "$on" -eq 1 ] && key+="$(printf '%q' "$a") "; [ "$a" = -A ] && on=1; done
	echo "$key" >>"$d/portmap-keys"
	printf '%s ' "$@" | sed -E 's/.* -A /-A /; s/ $//' >>"$d/portmap-rules"
	echo >>"$d/portmap-rules"
	;;
*"-t nat -S KUBE-SERVICES"*)
	if [ -f "$d/kube-services" ]; then echo "-N KUBE-SERVICES"; else rc=1; fi
	;;
*"-t nat -S PREROUTING"* | *"-t nat -S OUTPUT"* | *"-t nat -S POSTROUTING"* | *"-t filter -S "*)
	if [ -f "$d/start-v6-on-forward-read" ] && [[ "$*" == *"-t filter -S FORWARD"* ]]; then
		touch /harness/kp/ip6tables/jumps /harness/kp/ip6tables/canary /harness/kp/ip6tables/kube-services
		rm -f "$d/start-v6-on-forward-read"
	fi
	if read_fail; then
		rc=4
	else
		ch=${!#}
		tb=filter
		[[ "$*" == *"-t nat "* ]] && tb=nat
		echo "-P $ch ACCEPT"
		jumps "$tb" "$ch"
	fi
	;;
esac
EOF
	done
}
kp() {
	if [ "$#" -ge 3 ]; then echo "$3" >"/harness/kp/$1/$2"; else touch "/harness/kp/$1/$2"; fi
}

mkdir -p /var/lib/node_exporter/textfile /var/lib/node-maintenance
# The scripts read this file's mtime with the unstubbed stat and compare it with the fake clock. If
# the scripts create it, its mtime is the real time, and every cooldown check reports a cooldown
# once the real clock comes within 300 s of FAKE_NOW. A scenario that tests the cooldown sets its own mtime.
mkdir -p /var/lib/k3s-agent-restart && touch -d "@$((FAKE_NOW - 3600))" /var/lib/k3s-agent-restart/cooldown
lib_src=/repo/node-maintenance/ansible/roles/base_config/files/node-script-lib.sh
if [ -f "$lib_src" ]; then
	install -D -m 0644 "$lib_src" /usr/local/lib/node-maintenance/node-script-lib.sh
fi

SCRIPT="" ARGS=() OUT_FILES=()
# shellcheck disable=SC1090
. "$scenario"
[ -n "$SCRIPT" ] || {
	echo "scenario $scenario sets no SCRIPT" >&2
	exit 2
}

rc=0
# The line trace feeds the call-site coverage report. It goes to fd 19: the heal scripts use fd 9.
# Bash ignores PS4 from the environment when it runs as root, so BASH_ENV sets it instead.
cat >/harness/xtrace-env <<'EOF'
PS4='+${BASH_SOURCE##*/}:${LINENO}: '
BASH_XTRACEFD=19
set -x
EOF
timeout 120 env BASH_ENV=/harness/xtrace-env bash "/repo/$SCRIPT" "${ARGS[@]}" \
	>/out/stdout 2>/out/stderr 19>/trace/xtrace || rc=$?
echo "$rc" >/out/rc
# Saved as `calls`, not calls.log: the repo's .gitignore drops *.log, which would leave the fixtures without it.
cp /harness/calls.log /out/calls
# The scripts log their own PID, which depends on how many processes ran before them.
sed -i 's/pid=[0-9]*/pid=N/g' /out/calls /out/stdout /out/stderr
# Bash error messages carry the script's line number, which any edit above that line moves.
sed -i -E 's/: line [0-9]+: /: line N: /' /out/stderr
find /var/lib/node_exporter/textfile -maxdepth 1 -type f -exec cp -p {} /out/textfile/ \;
for f in "${OUT_FILES[@]}"; do
	if [ -f "$f" ]; then cp "$f" "/out/state/$(echo "$f" | tr '/' '_')"; fi
done
# Leftover temp files show up here: every directory the scripts write into, by name and mode.
for d in /var/lib/node_exporter/textfile /var/lib/node-maintenance /var/lib/node-isolation-heal; do
	if [ -d "$d" ]; then find "$d" -maxdepth 1 -type f -printf '%m %p\n'; fi
done | sort >/out/listing
