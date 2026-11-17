#!/usr/bin/env bash
# Offline check for nas-hardening-probe.sh. Sources it as a library (NAS_HARDENING_PROBE_LIB=1).
# The ssh lines are real output: the NAS on 2026-11-17, and a throwaway local sshd for the cases
# the NAS no longer produces. main() runs against 127.0.0.1 only.
# Run: bash tests/test-probe.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NAS_HARDENING_PROBE_LIB=1
export NAS_HARDENING_PROBE_LIB
# shellcheck source=../files/nas-hardening-probe.sh
. "$HERE/../files/nas-hardening-probe.sh"
set +e

pass=0 fail=0
chk() {
	if [ "$2" = "$3" ]; then
		echo "PASS: $1"
		pass=$((pass + 1))
	else
		echo "FAIL: $1 (want=$2 got=$3)"
		fail=$((fail + 1))
	fi
}

chk "NAS, keys only" 1 "$(keys_only 255 'akhozya@192.168.1.136: Permission denied (publickey).')"
chk "password and keyboard-interactive" 0 "$(keys_only 255 'akhozya@127.0.0.1: Permission denied (publickey,password,keyboard-interactive).')"
chk "password only" 0 "$(keys_only 255 'akhozya@127.0.0.1: Permission denied (publickey,password).')"
chk "keyboard-interactive only" 0 "$(keys_only 255 'akhozya@127.0.0.1: Permission denied (publickey,keyboard-interactive).')"
chk "another method beside publickey" 0 "$(keys_only 255 'akhozya@127.0.0.1: Permission denied (publickey,hostbased).')"
chk "login with no key succeeded" 0 "$(keys_only 0 '')"
chk "NAS unreachable: no value" "" "$(keys_only 255 'ssh: connect to host 192.168.1.136 port 56634: Operation timed out')"
chk "refused: no value" "" "$(keys_only 255 'ssh: connect to host 127.0.0.1 port 22222: Connection refused')"

# Lines in the formats the CP printed on 2026-11-17, with documentation addresses and made-up MACs.
pingout='PING ff02::1 (ff02::1) from fe80::c enp3s0: 56 data bytes
64 bytes from fe80::1%enp3s0: icmp_seq=1 ttl=64 time=0.107 ms
64 bytes from 2001:db8::7: icmp_seq=1 ttl=64 time=0.2 ms
64 bytes from fe80::1%enp3s0: icmp_seq=2 ttl=64 time=0.1 ms
--- ff02::1 ping statistics ---'
chk "reply sources, once each" "2001:db8::7 fe80::1" "$(reply_sources <<<"$pingout" | tr '\n' ' ' | sed 's/ $//')"
neigh='fe80::1 lladdr 02:00:00:00:00:01 STALE
fe80::2 lladdr 02:00:00:00:00:0a router REACHABLE
fe80::3 FAILED'
chk "MAC of an address" "02:00:00:00:00:01" "$(mac_of fe80::1 <<<"$neigh")"
chk "MAC of a router entry" "02:00:00:00:00:0a" "$(mac_of fe80::2 <<<"$neigh")"
chk "no MAC for a failed entry" "" "$(mac_of fe80::3 <<<"$neigh")"

# nas_ipv6_on with ip and ping stubbed. The stub output copies the CP's real formats on 2026-11-17,
# with documentation addresses and made-up MACs.
v6case() {
	(
		ip() {
			case "$*" in
			"-o route get 192.168.1.136")
				[ "${NOROUTE:-0}" = 1 ] || echo '192.168.1.136 dev eth0 src 192.0.2.1 uid 0 \    cache '
				;;
			"neigh show 192.168.1.136 dev eth0") echo "$ARP" ;;
			"-6 neigh show dev eth0")
				[ "$NEIGH6_RC" = 0 ] || return "$NEIGH6_RC"
				echo "$NEIGH6"
				;;
			"-6 -o addr show dev eth0")
				[ "${ADDR_RC:-0}" = 0 ] || return "$ADDR_RC"
				echo '2: eth0    inet6 fe80::c/64 scope link \       valid_lft forever preferred_lft forever'
				;;
			*) return 1 ;;
			esac
		}
		ping() {
			local a=${*: -1} r
			if [ "$a" = ff02::1 ]; then
				# The parser needs English, numeric output.
				case " $* " in *" -n "*) ;; *) return 2 ;; esac
				[ "${LC_ALL:-}" = C ] || return 2
				if [ -n "${GARBLED:-}" ]; then echo "$GARBLED"; fi
				for r in $RESPONDERS; do echo "64 bytes from $r%eth0: icmp_seq=1 ttl=64 time=0.107 ms"; done
				return "$MCAST_RC"
			fi
			return "$UNI_RC"
		}
		NAS=192.168.1.136
		out=$(nas_ipv6_on "$1")
		echo "rc=$? out=$out"
	)
}
NAS_ARP='192.168.1.136 lladdr 02:00:00:00:00:01 DELAY '
# fe80::1 is an old entry with the NAS's MAC; fe80::5 is the NAS answering now.
N6='fe80::1 lladdr 02:00:00:00:00:01 STALE
fe80::5 lladdr 02:00:00:00:00:01 REACHABLE
fe80::9 lladdr 02:00:00:00:00:09 router REACHABLE'
v6() { ARP=${ARP-$NAS_ARP} NEIGH6=$N6 NEIGH6_RC=${NEIGH6_RC:-0} MCAST_RC=${MCAST_RC:-0} UNI_RC=${UNI_RC:-0} v6case "$@"; }
# LC_ALL=POSIX here proves that the probe sets LC_ALL=C itself.
chk "v6: the NAS answers" "rc=0 out=1" "$(LC_ALL=POSIX RESPONDERS='fe80::9 fe80::5' v6 1)"
chk "v6: only an old entry has the NAS's MAC" "rc=0 out=0" "$(RESPONDERS='fe80::9' v6 1)"
chk "v6: nobody answers" "rc=0 out=0" "$(RESPONDERS='' MCAST_RC=1 v6 1)"
chk "v6: multicast ping error fails" "rc=1 out=" "$(RESPONDERS='fe80::5' MCAST_RC=2 v6 1)"
chk "v6: direct ping error fails" "rc=1 out=" "$(RESPONDERS='fe80::5' UNI_RC=2 v6 1)"
chk "v6: neighbour lookup error fails" "rc=1 out=" "$(RESPONDERS='fe80::5' NEIGH6_RC=1 v6 1)"
chk "v6: SSH answered but no MAC fails" "rc=1 out=" "$(RESPONDERS='fe80::5' ARP='192.168.1.136 INCOMPLETE ' v6 1)"
chk "v6: no route to the NAS fails" "rc=1 out=" "$(RESPONDERS='fe80::5' NOROUTE=1 v6 1)"
chk "v6: the CP's own address needs no MAC" "rc=0 out=0" "$(RESPONDERS='fe80::c fe80::9' v6 1)"
chk "v6: a responder with no MAC fails" "rc=1 out=" "$(RESPONDERS='fe80::9 fe80::7' v6 1)"
chk "v6: replies in an unknown format fail" "rc=1 out=" "$(RESPONDERS='' GARBLED='64 octets de fe80::5' v6 1)"
chk "v6: a NAS match needs no own-address lookup" "rc=0 out=1" "$(RESPONDERS='fe80::5' ADDR_RC=1 v6 1)"
chk "v6: own-address lookup error fails" "rc=1 out=" "$(RESPONDERS='fe80::9' ADDR_RC=1 v6 1)"
chk "v6: no SSH result and no MAC prints nothing" "rc=0 out=" "$(RESPONDERS='fe80::5' ARP='' v6 0)"

# For main against 127.0.0.1, ip answers as Linux does: a route via lo and no neighbour entry.
# The stub also covers macOS, which has no ip command.
ip() {
	if [ "$*" = "-o route get 127.0.0.1" ]; then
		echo 'local 127.0.0.1 dev lo table local src 127.0.0.1 uid 0 \    cache <local> '
	fi
}

dir=$(mktemp -d)
trap 'kill "${lpid:-}" 2>/dev/null; rm -rf "$dir"' EXIT
# shellcheck disable=SC2034 # main() from the sourced script reads these.
OUT="$dir/nas_hardening.prom" NAS=127.0.0.1 NAS_SSH_PORT=1

# A listener on a free port stands in for a port the firewall failed to close.
python3 -c 'import socket,sys,time
s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(8)
open(sys.argv[1],"w").write(str(s.getsockname()[1])); time.sleep(60)' "$dir/port" &
lpid=$!
for _ in $(seq 1 50); do
	[ -s "$dir/port" ] && break
	sleep 0.2
done
if [ ! -s "$dir/port" ]; then
	echo "FAIL: the test listener did not start"
	exit 1
fi
open_port=$(cat "$dir/port")
rm -f "$dir/port"

# Nothing listens on SSH port 1, so SSH counts as unreachable and nas_ssh_keys_only is absent.
# shellcheck disable=SC2034
CLOSED_PORTS=(1 "$open_port")
(
	set -e
	main
)
chk "main exits 0" 0 "$?"
chk "unreachable" 1 "$(grep -c '^nas_ssh_reachable 0$' "$OUT")"
chk "no keys_only sample" 0 "$(grep -c '^nas_ssh_keys_only' "$OUT")"
chk "no ipv6 sample without a neighbour entry" 0 "$(grep -c '^nas_ipv6_on' "$OUT")"
chk "closed port" 1 "$(grep -c '^nas_port_open{port="1"} 0$' "$OUT")"
chk "open port" 1 "$(grep -c "^nas_port_open{port=\"$open_port\"} 1\$" "$OUT")"
chk "no temp file left" 1 "$(find "$dir" -type f | wc -l | tr -d ' ')"

# The seed differs from every file main writes, so cmp detects an in-place rewrite.
echo 'seed' >"$OUT"
cp "$OUT" "$dir/before"
fails() {
	(
		set -e
		eval "$2"
		main
	)
	chk "$1: main fails" 1 "$(($? != 0))"
	chk "$1: previous file kept" 0 "$(cmp -s "$OUT" "$dir/before" && echo 0 || echo 1)"
	chk "$1: no temp file" 2 "$(find "$dir" -type f | wc -l | tr -d ' ')"
}
# shellcheck disable=SC2016 # expanded later, by eval inside fails().
fails "ssh cannot start" 'timeout() { if [ "$2" = ssh ]; then return 127; fi; command timeout "$@"; }'
# shellcheck disable=SC2016
fails "port check cannot run" 'timeout() { if [ "$2" = bash ]; then return 125; fi; command timeout "$@"; }'
fails "write fails after mktemp" 'chmod() { return 1; }'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
