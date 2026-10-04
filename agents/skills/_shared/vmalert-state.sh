#!/usr/bin/env bash
# Authoritative vmalert rule state: firing + PENDING + unhealthy, straight from vmalert's
# /api/v1/rules. Run AFTER reconciling a vmrules change (the post-change re-test gate).
#
# WHY: check-alerts.sh shows firing only. On 2026-06-06 a re-test checked metric existence and
# rule health but NOT pending/for:-window state, so a pending NodeMemoryMajorPagesFaults went
# undetected and later paged. The VM `ALERTS{}` metric LAGS (~5min staleness) after a rule stops
# firing, so it can still report firing after the rule becomes inactive. vmalert's /api/v1/rules
# shows each rule's state from its last evaluation, without waiting for ALERTS{} to go stale.
#
# Usage:  vmalert-state.sh            # firing + pending + unhealthy, exit 1 if any firing/pending
#         vmalert-state.sh --quiet    # only print problems; silent + exit 0 when all clear
# Read-only.

set -euo pipefail

PF_PORT="${PF_PORT:-18880}"
VA="http://127.0.0.1:${PF_PORT}"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
command -v jq >/dev/null || {
  echo "needs jq" >&2
  exit 2
}

kubectl port-forward -n monitoring svc/vmalert-vmalert "${PF_PORT}:8080" >/dev/null 2>&1 &
PF=$!
trap '[ -n "${PF:-}" ] && kill "$PF" 2>/dev/null || true' EXIT
sleep 3

# vmalert leaks raw control chars (unescaped newlines in multi-line `>` exprs) into the JSON,
# and jq fails with "control characters ... must be escaped". Strip \x00-\x1f first.
RULES="$(curl -s --max-time 10 "$VA/api/v1/rules" 2>/dev/null | LC_ALL=C tr -d '\000-\037')"
[ -n "$RULES" ] || {
  echo "vmalert /api/v1/rules unreachable" >&2
  exit 2
}

firing="$(echo "$RULES" | jq -r '[.data.groups[].rules[]? | select(.state=="firing")  | .name] | unique | join(", ")')"
pending="$(echo "$RULES" | jq -r '[.data.groups[].rules[]? | select(.state=="pending") | .name] | unique | join(", ")')"
unhealthy="$(echo "$RULES" | jq -r '[.data.groups[].rules[]? | select(.health!="ok") | "\(.name)(\(.health)): \(.lastError // "")"] | join(" | ")')"
total="$(echo "$RULES" | jq -r '[.data.groups[].rules[]?] | length')"

if [ "$QUIET" -eq 0 ]; then
  echo "rules=$total"
  echo "FIRING:    ${firing:-none}"
  echo "PENDING:   ${pending:-none}"
  echo "UNHEALTHY: ${unhealthy:-none}"
fi

if [ -n "$firing" ] || [ -n "$pending" ] || [ -n "$unhealthy" ]; then
  [ "$QUIET" -eq 1 ] && {
    echo "FIRING: ${firing:-none}"
    echo "PENDING: ${pending:-none}"
    echo "UNHEALTHY: ${unhealthy:-none}"
  }
  exit 1
fi
[ "$QUIET" -eq 0 ] && echo "RESULT: all rules inactive + healthy"
exit 0
