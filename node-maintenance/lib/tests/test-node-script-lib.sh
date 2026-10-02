#!/usr/bin/env bash
# Offline checks for ansible/roles/base_config/files/node-script-lib.sh. Needs bash 4+ (macOS:
# /opt/homebrew/bin/bash). No root. Each failure case puts a stub mktemp/cat/chmod/mv first on
# PATH; the whole-script behaviour of the callers is checked by heal-harness/run-all.sh.
# Run: bash node-maintenance/lib/tests/test-node-script-lib.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../../ansible/roles/base_config/files/node-script-lib.sh"
ROLES="$HERE/../../ansible/roles"
INPUTS="$HERE/heal-harness/inputs"
# shellcheck source=../../ansible/roles/base_config/files/node-script-lib.sh
. "$LIB"

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
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
temps() { find "$1" -name '*.XXXXXX' -o -name '*.prom.*' -o -name 'state.*' | wc -l | tr -d ' '; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
STUBS="$T/stubs"
mkdir -p "$STUBS"
# stub NAME BODY: a command that runs BODY in place of the real NAME, inside with_stub only.
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$STUBS/$1" && chmod +x "$STUBS/$1"; }
with_stub() { PATH="$STUBS:$PATH" "$@"; }
reset() {
	rm -f "$STUBS"/* "$T"/cat-calls
	rm -rf "$T/d" && mkdir -p "$T/d" && printf 'old\n' >"$T/d/f.prom"
}

# A producer far larger than any pipe buffer, so a helper that stops reading makes it fail
# with SIGPIPE. The test measures the local pipe capacity first and checks the producer beats it.
BIG=$((4 * 1024 * 1024))
producer() { head -c "$BIG" /dev/zero | tr '\0' 'x'; }
pipe_cap=$(python3 -c 'import os,fcntl; r,w=os.pipe(); os.set_blocking(w,False)
n=0
try:
    while True: n+=os.write(w,b"x"*4096)
except BlockingIOError: print(n)' 2>/dev/null || echo 65536)
chk "payload exceeds the pipe capacity ($pipe_cap bytes)" 1 "$([ "$BIG" -gt "$pipe_cap" ] && echo 1 || echo 0)"

# 1. a normal write
reset
printf 'a 1\nb 2\n' | textfile_write "$T/d/f.prom"
rc=$?
chk "1 write: returns 0" 0 "$rc"
chk "1 write: bytes" "$(printf 'a 1\nb 2\n' | od -c)" "$(od -c <"$T/d/f.prom")"
chk "1 write: mode 0644" 644 "$(mode "$T/d/f.prom")"
chk "1 write: no temp file left" 0 "$(temps "$T/d")"

# 2. mktemp fails: stdin is still read to the end, and the old file stays.
reset
stub mktemp 'exit 1'
producer | with_stub textfile_write "$T/d/f.prom"
st=("${PIPESTATUS[@]}")
chk "2 mktemp fails: producer not killed" 0 "${st[0]}"
chk "2 mktemp fails: returns 1" 1 "${st[1]}"
chk "2 mktemp fails: old file unchanged" old "$(cat "$T/d/f.prom")"
chk "2 mktemp fails: no temp file left" 0 "$(temps "$T/d")"

# 3. chmod fails
reset
stub chmod 'exit 1'
printf 'new\n' | with_stub textfile_write "$T/d/f.prom"
chk "3 chmod fails: returns 1" 1 "$?"
chk "3 chmod fails: old file unchanged" old "$(cat "$T/d/f.prom")"
chk "3 chmod fails: temp file removed" 0 "$(temps "$T/d")"

# 4. mv fails
reset
stub mv 'exit 1'
printf 'new\n' | with_stub textfile_write "$T/d/f.prom"
chk "4 mv fails: returns 1" 1 "$?"
chk "4 mv fails: old file unchanged" old "$(cat "$T/d/f.prom")"
chk "4 mv fails: temp file removed" 0 "$(temps "$T/d")"

# 4b. the payload write fails after the temp file exists: the first cat writes 10 bytes and
# exits 1 without reading the rest; later cats are the real one (the drain).
reset
stub cat "n=\$(( \$(/bin/cat \"$T/cat-calls\" 2>/dev/null || echo 0) + 1 )); echo \"\$n\" >\"$T/cat-calls\"
if [ \"\$n\" -eq 1 ]; then head -c 10; exit 1; fi
exec /bin/cat \"\$@\""
producer | with_stub textfile_write "$T/d/f.prom"
st=("${PIPESTATUS[@]}")
chk "4b payload write fails: producer not killed" 0 "${st[0]}"
chk "4b payload write fails: returns 1" 1 "${st[1]}"
chk "4b payload write fails: old file unchanged" old "$(cat "$T/d/f.prom")"
chk "4b payload write fails: temp file removed" 0 "$(temps "$T/d")"

# 5. state_write bytes: identical to the callers' old printf '%s %s %s %s\n' (and 5 fields).
reset
state_write "$T/d/state" 1791057600 1 1 1791057600
chk "5 state 4 fields: bytes" "$(printf '%s %s %s %s\n' 1791057600 1 1 1791057600 | od -c)" "$(od -c <"$T/d/state")"
chk "5 state: mode 0600" 600 "$(mode "$T/d/state")"
state_write "$T/d/state" 10 2 5 99 111
chk "5 state 5 fields: bytes" "$(printf '%s %s %s %s %s\n' 10 2 5 99 111 | od -c)" "$(od -c <"$T/d/state")"
read -r a b c d e <"$T/d/state"
chk "5 state 5 fields: read back" "10 2 5 99 111" "$a $b $c $d $e"

# 5b. state_write failures: returns 0, the old state stays, no temp file.
for case in "mktemp:exit 1" "chmod:exit 1" "mv:exit 1"; do
	reset
	printf '1 2 3 4\n' >"$T/d/state"
	stub "${case%%:*}" "${case#*:}"
	with_stub state_write "$T/d/state" 9 9 9 9
	chk "5b state_write, ${case%%:*} fails: returns 0" 0 "$?"
	chk "5b state_write, ${case%%:*} fails: old state unchanged" "1 2 3 4" "$(cat "$T/d/state")"
	chk "5b state_write, ${case%%:*} fails: no temp file" 0 "$(temps "$T/d")"
done
reset
printf '1 2 3 4\n' >"$T/d/state"
stub cat "n=\$(( \$(/bin/cat \"$T/cat-calls\" 2>/dev/null || echo 0) + 1 )); echo \"\$n\" >\"$T/cat-calls\"
if [ \"\$n\" -eq 1 ]; then head -c 3; exit 1; fi
exec /bin/cat \"\$@\""
with_stub state_write "$T/d/state" 9 9 9 9
chk "5b state_write, payload fails: returns 0" 0 "$?"
chk "5b state_write, payload fails: old state unchanged" "1 2 3 4" "$(/bin/cat "$T/d/state")"
chk "5b state_write, payload fails: no temp file" 0 "$(temps "$T/d")"

# 6. ufw_chains_hash: equal to the body the three firewall scripts carried, and blind to non-ufw lines.
old_ufw_chains_hash() {
	{
		"$IPTABLES_SAVE" 2>/dev/null | grep -E '^:ufw-|^-A ufw-' || true
		"$IP6TABLES_SAVE" 2>/dev/null | grep -E '^:ufw6-|^-A ufw6-' || true
	} | sha256sum | awk '{print $1}'
}
command -v sha256sum >/dev/null || sha256sum() { shasum -a 256; }
reset
cp "$INPUTS/iptables-save.v4" "$T/v4" && cp "$INPUTS/iptables-save.v6" "$T/v6"
stub save4 "/bin/cat \"$T/v4\"" && stub save6 "/bin/cat \"$T/v6\""
IPTABLES_SAVE="$STUBS/save4" IP6TABLES_SAVE="$STUBS/save6"
h0="$(ufw_chains_hash)"
chk "6 hash: equals the old body" "$(old_ufw_chains_hash)" "$h0"
chk "6 hash: not the empty-input hash" 1 "$([ "$h0" != "$(printf '' | sha256sum | awk '{print $1}')" ] && echo 1 || echo 0)"
echo '-A KUBE-FIREWALL -j RETURN' >>"$T/v4"
chk "6 hash: a non-ufw rule leaves it unchanged" "$h0" "$(ufw_chains_hash)"
echo '-A ufw-user-input -p tcp --dport 22 -j ACCEPT' >>"$T/v4"
chk "6 hash: a ufw rule changes it" 1 "$([ "$(ufw_chains_hash)" != "$h0" ] && echo 1 || echo 0)"
h_v4="$(ufw_chains_hash)"
echo '-A ufw6-user-input -p tcp --dport 22 -j ACCEPT' >>"$T/v6"
chk "6 hash: a ufw6 rule changes it" 1 "$([ "$(ufw_chains_hash)" != "$h_v4" ] && echo 1 || echo 0)"

# 7. the load guard in a real caller: an empty library, and one without state_write.
# The stub systemctl reports k3s-agent inactive and logs each call, so a guard that failed open
# would make clusterip-heal exit before any recovery step, and the call log shows it got that far.
reset
stub systemctl "echo \"\$*\" >>\"$T/systemctl-calls\"; exit 3"
stub logger 'exit 0'
: >"$T/empty-lib.sh"
awk '/^state_write\(\)/{skip=1} skip&&/^}/{skip=0; next} !skip' "$LIB" >"$T/partial-lib.sh"
chk "7 partial lib really lacks state_write" 0 "$(grep -c '^state_write()' "$T/partial-lib.sh")"
for lib in empty-lib partial-lib; do
	rm -f "$T/systemctl-calls"
	out="$(NODE_SCRIPT_LIB="$T/$lib.sh" with_stub bash "$ROLES/clusterip_heal/files/clusterip-heal.sh" 2>&1)"
	chk "7 guard, $lib: exits 1" 1 "$?"
	chk "7 guard, $lib: names that library" 1 "$(echo "$out" | grep -c "cannot load $T/$lib.sh")"
	chk "7 guard, $lib: stops before any systemctl call" 0 "$(if [ -f "$T/systemctl-calls" ]; then wc -l <"$T/systemctl-calls" | tr -d ' '; else echo 0; fi)"
done
# Every caller's guard, with an empty library: each lists different functions in declare -F.
for s in clusterip_heal/files/clusterip-heal.sh clusterip_heal_cp/files/clusterip-heal-cp.sh \
	node_isolation_heal/files/node-isolation-heal.sh immich_gpu_node/files/immich-gpu-heal.sh \
	firewall_preflight/files/firewall-preflight.sh k3s_config/files/k3s-wait-ready.sh \
	firewall/files/ufw-heal-post-k3s.sh; do
	out="$(NODE_SCRIPT_LIB="$T/empty-lib.sh" with_stub bash "$ROLES/$s" 2>&1)"
	chk "7 guard, ${s##*/}: exits 1 on an empty library" 1 "$?"
	chk "7 guard, ${s##*/}: names the library" 1 "$(echo "$out" | grep -c "cannot load $T/empty-lib.sh")"
done

# 8. the library holds function definitions only: sourcing it under xtrace runs no command.
chk "8 lib: bash -n" 0 "$(bash -n "$LIB" >/dev/null 2>&1; echo $?)"
# The trace shows the `.` itself; any other traced line is a command the library runs.
# shellcheck source=../../ansible/roles/base_config/files/node-script-lib.sh
chk "8 lib: no top-level command" 0 "$( (PS4='+'; set -x; . "$LIB") 2>&1 | grep -v '^+*\. ' | grep -c '^+')"

echo "---- $pass passed, $fail failed ----"
[ "$fail" -eq 0 ]
