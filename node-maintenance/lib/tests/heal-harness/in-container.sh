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

# A fixed clock, so state files and wedged-seconds values are the same on every run.
export FAKE_NOW=1791057600
cat >/harness/behavior/date <<'EOF'
if [ "${1:-}" = "+%s" ]; then echo "$FAKE_NOW"; else echo "Fri Oct  2 20:00:00 UTC 2026"; fi
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

mkdir -p /var/lib/node_exporter/textfile /var/lib/node-maintenance
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
timeout 120 bash "/repo/$SCRIPT" "${ARGS[@]}" >/out/stdout 2>/out/stderr || rc=$?
echo "$rc" >/out/rc
cp /harness/calls.log /out/calls.log
# The scripts log their own PID, which depends on how many processes ran before them.
sed -i 's/pid=[0-9]*/pid=N/g' /out/calls.log /out/stdout /out/stderr
find /var/lib/node_exporter/textfile -maxdepth 1 -type f -exec cp -p {} /out/textfile/ \;
for f in "${OUT_FILES[@]}"; do
	if [ -f "$f" ]; then cp "$f" "/out/state/$(echo "$f" | tr '/' '_')"; fi
done
# Leftover temp files show up here: every directory the scripts write into, by name and mode.
for d in /var/lib/node_exporter/textfile /var/lib/node-maintenance /var/lib/node-isolation-heal; do
	if [ -d "$d" ]; then find "$d" -maxdepth 1 -type f -printf '%m %p\n'; fi
done | sort >/out/listing
