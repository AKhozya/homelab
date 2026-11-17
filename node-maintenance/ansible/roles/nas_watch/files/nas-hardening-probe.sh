#!/usr/bin/env bash
# Checks from the CP that the NAS (not in Ansible) keeps its 2026-11-17 hardening: SSH offers
# publickey only, the ZettOS firewall drops the ports it closed, and IPv6 stays off. A firmware
# update can undo each of them.
# Needs no NAS login: the SSH method list and the port probes come before any authentication.
# Limits: the CP is on the NAS's SSH allow list, so it cannot see whether other sources are dropped.
# NAS_HARDENING_PROBE_LIB=1 loads the functions without running main (tests/test-probe.sh).
set -euo pipefail

NAS=${NAS:-192.168.1.136}
NAS_SSH_PORT=${NAS_SSH_PORT:-56634}
NAS_SSH_USER=${NAS_SSH_USER:-akhozya}
OUT=${OUT:-/var/lib/node_exporter/textfile/nas_hardening.prom}
CLOSED_PORTS=(4150 4151 5432 111)

# Reads the exit status and output of an ssh "none" login. Prints 1 if the server lists publickey
# and nothing else. Prints 0 if the server lists another method or accepts the login without a key.
# Prints nothing if the login fails and the server lists no methods.
keys_only() {
	local rc=$1 out=$2 methods
	if [[ $rc == 0 ]]; then
		echo 0
		return 0
	fi
	methods=$(sed -nE 's/.*Permission denied \(([^)]*)\).*/\1/p' <<<"$out" | head -n 1)
	[[ -n $methods ]] || return 0
	if [[ $methods == publickey ]]; then
		echo 1
	else
		echo 0
	fi
}

# Prints 1 if a TCP connection to the port succeeds, 0 if it is refused or times out. Returns 1 if
# the check itself could not run, so main writes nothing and the stale-file alert fires.
port_open() {
	local rc=0
	timeout 3 bash -c "</dev/tcp/$NAS/$1" 2>/dev/null || rc=$?
	case $rc in
	0) echo 1 ;;
	1 | 124) echo 0 ;;
	*) return 1 ;;
	esac
}

# Reads iputils ping output on stdin and prints each address that sent a reply, once.
reply_sources() {
	sed -nE 's/^[0-9]+ bytes from ([0-9a-f:]+)(%[^:]+)?: .*/\1/p' | sort -u
}

# Reads `ip -6 neigh` output on stdin and prints the MAC of address $1.
mac_of() {
	awk -v a="$1" '$1 == a { for (i = 2; i < NF; i++) if ($i == "lladdr") print $(i + 1) }'
}

# Prints 1 if the NAS answers a ping over IPv6, and 0 if it does not. Returns 1 if a local command
# fails, so main writes nothing and the stale-file alert fires. $1 is 1 if SSH gave a result.
# If SSH gave a result, a missing IPv4 MAC is a failure. If SSH gave none, a missing MAC prints nothing.
# IPv6 stays off on the NAS because its firewall filters IPv4 only.
# The MAC comes from the CP's IPv4 neighbour entry, so neither the MAC nor an IPv6 address is in this repo.
# Limits: this watches the LAN2 MAC only, and needs the NAS to answer pings. On 2026-11-17 the NAS
# had net.ipv6.icmp.echo_ignore_all=0 and echo_ignore_multicast=0.
nas_ipv6_on() {
	local reachable=$1 dev neigh mac out srcs own a rc
	dev=$(ip -o route get "$NAS" | sed -nE 's/.* dev ([^ ]+).*/\1/p')
	[[ -n $dev ]] || return 1
	neigh=$(ip neigh show "$NAS" dev "$dev") || return 1
	mac=$(awk '{ for (i = 1; i < NF; i++) if ($i == "lladdr") print $(i + 1) }' <<<"$neigh")
	if [[ -z $mac ]]; then
		if [[ $reachable == 1 ]]; then
			return 1
		fi
		return 0
	fi
	# The parser expects English reply lines with numeric addresses. LC_ALL=C selects English.
	# -n turns off name lookups.
	# iputils ping exits 1 if no answer comes back and 2 on an error.
	rc=0
	out=$(LC_ALL=C ping -6 -n -c 2 -W 1 -I "$dev" ff02::1 2>/dev/null) || rc=$?
	((rc <= 1)) || return 1
	srcs=$(reply_sources <<<"$out")
	if [[ $rc == 0 && -z $srcs ]]; then
		return 1
	fi
	# A direct ping can fill in a missing neighbour entry. The CP checks only addresses that answered
	# the multicast ping.
	for a in $srcs; do
		rc=0
		ping -6 -c 1 -W 1 -I "$dev" "$a" >/dev/null 2>&1 || rc=$?
		((rc <= 1)) || return 1
	done
	neigh=$(ip -6 neigh show dev "$dev") || return 1
	for a in $srcs; do
		if [[ $(mac_of "$a" <<<"$neigh") == "$mac" ]]; then
			echo 1
			return 0
		fi
	done
	# No recorded MAC matches the NAS's MAC. A responder with no MAC could still be the NAS.
	own=$(ip -6 -o addr show dev "$dev") || return 1
	for a in $srcs; do
		# The CP's own addresses answer too, and have no neighbour entry.
		if [[ -z $(mac_of "$a" <<<"$neigh") ]] && ! grep -qF " $a/" <<<"$own"; then
			return 1
		fi
	done
	echo 0
}

main() {
	local out rc=0 ko p v v6 reach lines=()
	TMP=""
	trap '[[ -z $TMP ]] || rm -f "$TMP"' EXIT
	# The probe sends no credential, so an unknown host key risks nothing: it only reads the method list.
	out=$(timeout 20 ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=5 \
		-o PreferredAuthentications=none -o PubkeyAuthentication=no -o IdentityAgent=none \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
		-p "$NAS_SSH_PORT" "$NAS_SSH_USER@$NAS" true 2>&1) || rc=$?
	# If timeout returns 125-127, the probe has no SSH result. Keeping the previous file lets the
	# stale-file alert fire.
	if ((rc >= 125 && rc <= 127)); then
		return 1
	fi
	ko=$(keys_only "$rc" "$out")
	for p in "${CLOSED_PORTS[@]}"; do
		v=$(port_open "$p")
		lines+=("nas_port_open{port=\"$p\"} $v")
	done
	# Run the IPv4 probes first, so the CP has learned the NAS's MAC.
	reach=0
	[[ -z $ko ]] || reach=1
	v6=$(nas_ipv6_on "$reach")

	# The textfile collector reads only *.prom, so it never sees the half-written temp file.
	TMP=$(mktemp "$OUT.XXXXXX")
	{
		echo '# HELP nas_ssh_reachable 1 if the NAS SSH server lists its login methods or accepts the probe.'
		echo '# TYPE nas_ssh_reachable gauge'
		if [[ -n $ko ]]; then
			echo 'nas_ssh_reachable 1'
			echo '# HELP nas_ssh_keys_only 1 if NAS SSH offers publickey and nothing else.'
			echo '# TYPE nas_ssh_keys_only gauge'
			echo "nas_ssh_keys_only $ko"
		else
			echo 'nas_ssh_reachable 0'
		fi
		echo '# HELP nas_port_open 1 if a TCP connection succeeded to a port the ZettOS firewall should drop.'
		echo '# TYPE nas_port_open gauge'
		printf '%s\n' "${lines[@]}"
		if [[ -n $v6 ]]; then
			echo '# HELP nas_ipv6_on 1 if the NAS answers a ping over IPv6.'
			echo '# TYPE nas_ipv6_on gauge'
			echo "nas_ipv6_on $v6"
		fi
	} >"$TMP"
	chmod 0644 "$TMP"
	mv "$TMP" "$OUT"
	TMP=""
}

if [[ ${NAS_HARDENING_PROBE_LIB:-0} != 1 ]]; then
	main "$@"
fi
