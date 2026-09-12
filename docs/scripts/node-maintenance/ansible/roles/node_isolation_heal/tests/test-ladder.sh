#!/usr/bin/env bash
# Offline unit check for node-isolation-heal.sh's escalation ladder. Mocks systemctl on
# PATH (guard + action recording) and the network probes via NIH_MOCK_* return codes;
# drives each rung via env thresholds + backdated state. No root, no k3s.
# Run: bash tests/test-ladder.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../files/node-isolation-heal.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/metric"
cat >"$TMP/bin/systemctl" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  "cat k3s-agent.service") exit 0 ;;                                  # worker guard passes
  "restart k3s-agent.service") echo RESTART >>"$MOCK_ACTIONS"; exit 0 ;;
  reboot) echo REBOOT >>"$MOCK_ACTIONS"; exit 0 ;;
  *) exit 0 ;;
esac
EOS
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"
export MOCK_ACTIONS="$TMP/actions"
export NIH_STATE_DIR="$TMP/state" NIH_METRIC_DIR="$TMP/metric" NIH_SHARED_COOLDOWN="$TMP/shared-cooldown"
# Test-only: bypass the shared flock (absent on macOS); the ladder under test is mtime-based.
export NIH_SKIP_LOCK=1
export NIH_FAIL_CONSECUTIVE=2 NIH_RESTART_AFTER_S=300 NIH_REBOOT_BASE_S=900 NIH_REBOOT_STAGGER_S=480
export NIH_MOCK_KUBELET=0 NIH_MOCK_GW=0 # logged-only signals; hold "up" (don't gate)

METRIC="$TMP/metric/node_isolation_heal.prom"
STATE="$TMP/state/state"
pass=0 fail=0
gauge() { grep "^node_isolation_heal_$1 " "$METRIC" 2>/dev/null | awk '{print $2}'; }
seed() { printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >"$STATE"; } # first_fail consec last_restart last_reboot
chk() { if [ "$2" = "$3" ]; then
	echo "PASS: $1"
	pass=$((pass + 1))
else
	echo "FAIL: $1 (want=$2 got=$3)"
	fail=$((fail + 1))
fi; }
# run TUNNEL_RC CP_RC DRY_RUN [UPTIME]   (RC: 0=up, 1=down). EXPORT so the subshell inherits.
run() {
	rm -f "$MOCK_ACTIONS"
	export NIH_MOCK_TUNNEL="$1" NIH_MOCK_CP="$2" NIH_DRY_RUN="$3"
	if [ -n "${4:-}" ]; then export NIH_UPTIME_OVERRIDE="$4"; else unset NIH_UPTIME_OVERRIDE; fi
	bash "$SCRIPT" >/dev/null 2>&1 || true
}
N() { date +%s; }

# T1 healthy (tunnel up)
rm -f "$STATE"
run 0 0 1
chk "healthy: wedged=0" 0 "$(gauge wedged)"

# T2 isolated first cycle (debounce)
rm -f "$STATE"
run 1 1 1
chk "isolated c1: wedged=1" 1 "$(gauge wedged)"
chk "isolated c1: pending=0 (debounce)" 0 "$(gauge pending_action)"

# T3 isolated, past debounce, below L1 threshold -> waiting
seed "$(($(N) - 100))" 2 0 0
run 1 1 1
chk "isolated <L1: pending=0" 0 "$(gauge pending_action)"

# T4 wedged >= L1, dry-run -> WOULD restart, records simulated last_restart, no action
seed "$(($(N) - 400))" 2 0 0
run 1 1 1
chk "L1 dry-run: pending=1" 1 "$(gauge pending_action)"
chk "L1 dry-run: no real action" "" "$(cat "$MOCK_ACTIONS" 2>/dev/null)"
chk "L1 dry-run: last_restart advanced" 1 "$(awk '{print ($3>0)?1:0}' "$STATE")"

# T5 wedged >= reboot, cp down, prior L1, uptime ok, dry-run -> WOULD reboot, no action
seed "$(($(N) - 1000))" 2 "$(($(N) - 500))" 0
run 1 1 1 2000
chk "L2 dry-run: pending=2" 2 "$(gauge pending_action)"
chk "L2 dry-run: giveup=0" 0 "$(gauge giveup)"
chk "L2 dry-run: no real action" "" "$(cat "$MOCK_ACTIONS" 2>/dev/null)"

# T6 reboot but uptime < min -> giveup (boot-loop guard)
seed "$(($(N) - 1000))" 2 "$(($(N) - 500))" 0
run 1 1 1 100
chk "L2 uptime guard: giveup=1" 1 "$(gauge giveup)"

# T7 reboot but rebooted <24h ago -> giveup (daily cap)
seed "$(($(N) - 1000))" 2 "$(($(N) - 500))" "$(($(N) - 100))"
run 1 1 1 2000
chk "L2 daily-cap guard: giveup=1" 1 "$(gauge giveup)"

# T8 past reboot threshold but NO prior L1 -> L1 runs FIRST (not an infinite defer)
seed "$(($(N) - 1000))" 2 0 0
run 1 1 1 2000
chk "L2 w/o prior L1: does L1 (pending=1)" 1 "$(gauge pending_action)"
chk "L2 w/o prior L1: no reboot action" "" "$(cat "$MOCK_ACTIONS" 2>/dev/null)"
chk "L2 w/o prior L1: last_restart advanced" 1 "$(awk '{print ($3>0)?1:0}' "$STATE")"

# T8b NEXT cycle after T8: L1 now recorded -> progresses to reboot (proves no stuck loop)
seed "$(($(N) - 1000))" 3 "$(($(N) - 100))" 0
run 1 1 1 2000
chk "next cycle: progresses to reboot (pending=2)" 2 "$(gauge pending_action)"

# T9 cp UP (network fine) past reboot threshold -> NO reboot, L1 retry instead
seed "$(($(N) - 1000))" 2 "$(($(N) - 500))" 0
run 1 0 1 2000
chk "cp up: no reboot, retry L1 (pending=1)" 1 "$(gauge pending_action)"
chk "cp up: no reboot action" "" "$(cat "$MOCK_ACTIONS" 2>/dev/null)"

# T10 ACTIVE mode L1 -> real restart issued
seed "$(($(N) - 400))" 2 0 0
run 1 1 0
chk "active L1: RESTART issued" RESTART "$(cat "$MOCK_ACTIONS" 2>/dev/null)"

# T11 ACTIVE mode L2 (cp down) -> real reboot issued
seed "$(($(N) - 1000))" 2 "$(($(N) - 500))" 0
run 1 1 0 2000
chk "active L2: REBOOT issued" REBOOT "$(cat "$MOCK_ACTIONS" 2>/dev/null)"

# T12 recovery clears episode
seed "$(($(N) - 1000))" 5 "$(($(N) - 500))" 0
run 0 0 1
chk "recovery: wedged=0" 0 "$(gauge wedged)"
chk "recovery: episode cleared (consec=0)" 0 "$(awk '{print $2}' "$STATE")"

# T13: If a peer is reachable and the CP is unreachable, suppress L2.
# Same seed as T11 (which reboots); only the peer signal differs, so it isolates the gate.
export NIH_MOCK_PEERS=0 # 0 = a peer answered
seed "$(($(N) - 1000))" 2 "$(($(N) - 500))" 0
run 1 1 0 2000
chk "peers up: reboot SUPPRESSED" RESTART "$(cat "$MOCK_ACTIONS" 2>/dev/null)"
chk "peers up: last_reboot untouched" 0 "$(awk '{print $4}' "$STATE")"

# T14 if the CP and all peers are unreachable, L2 must remain eligible.
export NIH_MOCK_PEERS=1 # 1 = no peer answered
seed "$(($(N) - 1000))" 2 "$(($(N) - 500))" 0
run 1 1 0 2000
chk "peers down: REBOOT still issued" REBOOT "$(cat "$MOCK_ACTIONS" 2>/dev/null)"
unset NIH_MOCK_PEERS

echo "---- $pass passed, $fail failed ----"
[ "$fail" -eq 0 ]
