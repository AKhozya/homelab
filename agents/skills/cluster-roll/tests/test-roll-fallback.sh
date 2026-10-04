#!/usr/bin/env bash
# Stub test for cluster-roll.sh roll_one's Flux-stale fallback. No cluster: kubectl and
# restart-workload.sh are stubs. Usage: test-roll-fallback.sh [path-to-cluster-roll.sh]
set -euo pipefail
SRC="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/cluster-roll.sh}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/skills/cluster-roll/scripts" "$T/skills/_shared"
# Drop the trailing `main "$@"` so sourcing defines functions without running.
grep -v '^main "\$@"$' "$SRC" >"$T/skills/cluster-roll/scripts/cluster-roll.sh"

cat >"$T/skills/_shared/restart-workload.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$STATE/rw-calls"
[ "${RW_FAIL:-0}" = 1 ] && exit 1
[ "${RW_NOOP:-0}" = 1 ] || touch "$STATE/cycled"
exit 0
EOF
chmod +x "$T/skills/_shared/restart-workload.sh"

run_case() { # name, after-rollout state (old|new), env...
  local name="$1" after="$2"
  shift 2
  local st="$T/state-$name"
  mkdir -p "$st"
  (
    # shellcheck disable=SC2163  # "$@" holds VAR=value pairs to export
    export STATE="$st" "$@"
    # shellcheck disable=SC1091
    source "$T/skills/cluster-roll/scripts/cluster-roll.sh"
    # shellcheck disable=SC2329  # roll_one calls this stub
    kubectl() {
      case "$*" in
      *"get deploy web -o json"*) echo '{"spec":{"selector":{"matchLabels":{"app":"web"}}}}' ;;
      *"get pods --selector=app=web -o jsonpath"*) printf 'old-1\nold-2\n' ;;
      *"rollout restart"* | *"rollout status"*) return 0 ;;
      *"get pods --selector=app=web -o json"*)
        if [ -f "$STATE/cycled" ] || [ "$after" = new ]; then
          echo '{"items":[{"metadata":{"uid":"new-1"}},{"metadata":{"uid":"new-2"}}]}'
        else
          echo '{"items":[{"metadata":{"uid":"old-1"}},{"metadata":{"uid":"new-2"}}]}'
        fi
        ;;
      *)
        echo "$*" >>"$STATE/unexpected"
        return 1
        ;;
      esac
    }
    roll_one "apps:deploy/web"
  ) >"$st/out" 2>&1
}

fail=0
check() { # desc, command...
  local desc="$1"
  shift
  if "$@"; then echo "PASS $desc"; else
    echo "FAIL $desc"
    fail=1
  fi
}

rc=0
run_case survivors old || rc=$?
check "survivors: roll_one succeeds" test "$rc" = 0
check "survivors: restart-workload called with ns, selector, 180" grep -qx 'apps app=web 180' "$T/state-survivors/rw-calls"

rc=0
run_case clean new || rc=$?
check "no survivors: roll_one succeeds" test "$rc" = 0
check "no survivors: restart-workload not called" test ! -f "$T/state-clean/rw-calls"

rc=0
run_case rwfail old RW_FAIL=1 || rc=$?
check "restart-workload fails: roll_one fails" test "$rc" -ne 0
check "restart-workload fails: names the workload" grep -q 'could not cycle apps/deploy/web' "$T/state-rwfail/out"

rc=0
run_case stillstale old RW_NOOP=1 || rc=$?
check "pods still stale after fallback: roll_one fails" test "$rc" -ne 0
check "pods still stale: post-check message" grep -q 'STILL alive' "$T/state-stillstale/out"

for st in "$T"/state-*; do
  check "$(basename "$st"): no unexpected kubectl call (e.g. a direct pod delete)" test ! -s "$st/unexpected"
done

exit "$fail"
