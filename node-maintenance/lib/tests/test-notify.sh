#!/usr/bin/env bash
# Offline check for node-config-notify.sh: drives all three branches against a synthetic
# ansible log in a temp dir, with the Telegram notifier mocked. No root, no journald, no network.
# Run: bash tests/test-notify.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../node-config-notify.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
chk() { if [ "$2" = "$3" ]; then
	echo "PASS: $1"
	pass=$((pass + 1))
else
	echo "FAIL: $1 (want=$2 got=$3)"
	fail=$((fail + 1))
fi; }
has() { if grep -qF -- "$2" "$3"; then
	echo "PASS: $1"
	pass=$((pass + 1))
else
	echo "FAIL: $1 (missing '$2' in $3)"
	fail=$((fail + 1))
fi; }

cat >"$TMP/notify" <<'EOS'
#!/usr/bin/env bash
printf -- '---CALL---\n%s\n' "$1" >>"$MOCK_TG"
EOS
chmod +x "$TMP/notify"

export MOCK_TG="$TMP/tg"
export NODE_CONFIG_LOG="$TMP/config-latest.log"
export NODE_CONFIG_DUMP="$TMP/last-fatal.dump"
export NODE_CONFIG_ARCHIVE_DIR="$TMP/fatal-archive"
export NODE_CONFIG_NOTIFY_BIN="$TMP/notify"
mkdir -p "$NODE_CONFIG_ARCHIVE_DIR"

write_log() { # $1 changed  $2 failed  [$3 include-fatal]
	{
		echo "=== start: 2026-08-07T09:15:00+00:00 ==="
		echo "TASK [firewall : Apply UFW rules (base + group + host)] ****"
		[ "${3:-yes}" = yes ] && echo 'fatal: [worker-node]: FAILED! => {"attempts": 3, "cmd": "/usr/sbin/ufw status verbose", "msg": "ufw returned 1"}'
		echo "TASK [hardening : Deploy sshd hardening drop-in] ****"
		echo "PLAY RECAP ****"
		echo "worker-node   : ok=12 changed=$1 unreachable=0 failed=$2"
	} >"$NODE_CONFIG_LOG"
}

# --- failure branch: dump gets the journal window AND the parsed fatal ---
: >"$MOCK_TG"
write_log 0 1 yes
bash "$SCRIPT" exit-code >/dev/null 2>&1
chk "failure: notifier fired once" 1 "$(grep -c -- '^---CALL---$' "$MOCK_TG" | tr -d ' ')"
has "failure: journal window in dump" "window: 2026-08-07T09:15:00" "$NODE_CONFIG_DUMP"
has "failure: parsed-fatal section in dump" "--- Parsed fatal" "$NODE_CONFIG_DUMP"
has "failure: parsed host" "host: worker-node" "$NODE_CONFIG_DUMP"
has "failure: parsed msg" "msg: ufw returned 1" "$NODE_CONFIG_DUMP"
has "failure: parsed attempts" "attempts: 3" "$NODE_CONFIG_DUMP"
has "failure: correct TASK paired (not the later one)" "Apply UFW rules" "$NODE_CONFIG_DUMP"
chk "failure: archived" 1 "$(find "$NODE_CONFIG_ARCHIVE_DIR" -name 'fatal-*.dump' | wc -l | tr -d ' ')"

# --- changed-only branch: reports the count, writes no dump ---
: >"$MOCK_TG"
rm -f "$NODE_CONFIG_DUMP"
write_log 2 0 no
bash "$SCRIPT" success >/dev/null 2>&1
chk "changed: notifier fired once" 1 "$(grep -c -- '^---CALL---$' "$MOCK_TG" | tr -d ' ')"
has "changed: count reported" "applied 2 change(s)" "$MOCK_TG"
chk "changed: no dump written" 0 "$([ -e "$NODE_CONFIG_DUMP" ] && echo 1 || echo 0)"

# --- idempotent run: silent ---
: >"$MOCK_TG"
write_log 0 0 no
bash "$SCRIPT" success >/dev/null 2>&1
chk "idempotent: silent" 0 "$(wc -c <"$MOCK_TG" | tr -d ' ')"

# --- exec-condition: a skipped heal is not a failure, even with a stale fatal in the log ---
: >"$MOCK_TG"
write_log 0 1 yes
bash "$SCRIPT" exec-condition >/dev/null 2>&1
chk "exec-condition: silent" 0 "$(wc -c <"$MOCK_TG" | tr -d ' ')"

# --- 4-host recap: every host counts, including the first ---
# The counts used to come from `grep … | tail -3`, which dropped the first host once immich-vm
# made this a 4-node cluster. Live proof 2026-08-07: a 12-change run alerted as "9 change(s)".
write_recap_4() { # $1 changed-per-host  $2 failed-per-host
	{
		echo "=== start: 2026-08-07T17:30:00+00:00 ==="
		echo "PLAY RECAP ****"
		for h in gmk-k3s-control-plane immich-vm worker-node worker-node-2; do
			echo "$h   : ok=116 changed=$1 unreachable=0 failed=$2"
		done
	} >"$NODE_CONFIG_LOG"
}

: >"$MOCK_TG"
write_recap_4 3 0
bash "$SCRIPT" success >/dev/null 2>&1
has "4 hosts: all 12 changes counted" "applied 12 change(s)" "$MOCK_TG"
has "4 hosts: first host present in detail" "gmk-k3s-control-plane: 3" "$MOCK_TG"
has "4 hosts: last host present in detail" "worker-node-2: 3" "$MOCK_TG"
# `paste -d` cycles its argument as a delimiter LIST, so ', ' alternated comma and space.
chk "4 hosts: one separator style" 0 "$(grep -c '3 worker-node' "$MOCK_TG")"

# systemd appends this unit's own stderr to the same log, so text after the recap must not be
# summed in — the counts read the host rows, not everything below the PLAY RECAP header.
: >"$MOCK_TG"
write_recap_4 3 0
{
	echo "some trailing task output mentioning changed=99 failed=99"
	echo "ERROR: unrelated stderr line, changed=7"
	# Shaped like a recap row but missing `unreachable=`, so the canonical-sequence match rejects it.
	echo "diagnostic                 : ok=1 changed=99 failed=99"
} >>"$NODE_CONFIG_LOG"
bash "$SCRIPT" success >/dev/null 2>&1
has "post-recap noise ignored" "applied 12 change(s)" "$MOCK_TG"

# A failure on the FIRST host must reach the count, not fall off the front.
: >"$MOCK_TG"
write_recap_4 0 1
bash "$SCRIPT" success >/dev/null 2>&1
has "4 hosts: failures counted from the first host" "failed=4" "$MOCK_TG"

# --- missing log: still alerts ---
: >"$MOCK_TG"
rm -f "$NODE_CONFIG_LOG"
bash "$SCRIPT" exit-code >/dev/null 2>&1
has "missing log: alerts" "log missing" "$MOCK_TG"

echo "---- $pass passed, $fail failed ----"
[ "$fail" -eq 0 ]
