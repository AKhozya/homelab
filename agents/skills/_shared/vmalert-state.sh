#!/usr/bin/env bash
# Authoritative vmalert rule state: firing + PENDING + unhealthy, straight from vmalert's
# /api/v1/rules. Run AFTER reconciling a vmrules change (the post-change re-test gate).
#
# WHY: check-alerts.sh shows firing only. UR2 (2026-06-06) re-test verified metric existence +
# rule health but NOT pending/for:-window state, so a pending NodeMemoryMajorPagesFaults (live
# alert from a fixed job label) slipped through and later paged. And the VM `ALERTS{}` metric
# LAGS (~5min staleness) after a rule stops firing — so it shows ghost-firing post-fix. vmalert's
# /api/v1/rules is the live truth (state=inactive the instant the expr stops matching).
#
# Two gotchas this encodes:
#   1. vmalert leaks raw control chars (unescaped newlines in multi-line `>` exprs) into the JSON,
#      breaking jq with "control characters ... must be escaped". Fix: strip \x00-\x1f first.
#   2. ALERTS{alertstate="firing"} metric != vmalert rule state. Trust /api/v1/rules.
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

# Strip control chars (gotcha 1) before jq.
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
