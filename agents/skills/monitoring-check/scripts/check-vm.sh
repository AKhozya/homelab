#!/usr/bin/env bash
# VictoriaMetrics health check: memory, series count, target health.
# Uses port-forward — vmsingle/vmalert bind non-loopback in their containers.

set -euo pipefail

# shellcheck disable=SC2329  # invoked by `trap cleanup EXIT` below
cleanup() {
  for pid in "${PFS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT
PFS=()

# -f, not bare -s: without it an HTTP 4xx/5xx error BODY is non-empty output, so the
# probe "succeeds" and the caller's jq reads a field that isn't there. A jq path that
# misses on valid JSON prints `null` and exits 0 — the failure then looks like an answer.
probe() { # retry: port-forward takes a moment to bind
  local out
  for _ in 1 2 3 4 5; do
    if out="$(curl -fs --max-time 3 "$1" 2>/dev/null)" && [ -n "$out" ]; then
      # VictoriaMetrics answers query errors with HTTP 200 and {"status":"error"}, which -f
      # cannot catch. REQUIRE status=="success" rather than reject only an explicit error:
      # a truncated or proxied body with a plausible .data and no status field would pass.
      if ! jq -e '.status == "success"' >/dev/null 2>&1 <<<"$out"; then
        jq -r '"API error: \(.error // .errorType // "no success status")"' 2>/dev/null <<<"$out" >&2 ||
          echo "API error: response is not JSON" >&2
        return 1
      fi
      printf '%s\n' "$out"
      return 0
    fi
    sleep 0.5
  done
  return 1
}

echo "=== vmsingle memory ==="
kubectl top pod -n monitoring -l app.kubernetes.io/name=vmsingle 2>/dev/null || echo "(metrics unavailable)"

# Unreachable fails the script: a bare `|| echo "(unreachable)"` exits 0, and a caller reads an
# unreachable VictoriaMetrics endpoint as healthy.
RC=0

echo
echo "=== series count (vmsingle :8429) ==="
kubectl port-forward -n monitoring svc/vmsingle-vmsingle 18429:8429 >/dev/null 2>&1 &
PFS+=("$!")
# `> 0`, not merely present: VM answers with totalSeries 0 when it holds no data at all, and
# `jq -e` treats 0 as a legitimate value (only false/null are falsy).
if ! probe 'http://127.0.0.1:18429/api/v1/status/tsdb' | jq -e '.data.totalSeries | select(. > 0)'; then
  echo "(no series — vmsingle empty or unreachable)"
  RC=1
fi

echo
echo "=== target health by status (vmagent :8429) ==="
kubectl port-forward -n monitoring svc/vmagent-vmagent 18430:8429 >/dev/null 2>&1 &
PFS+=("$!")
# An EMPTY activeTargets array means vmagent is scraping nothing — broken, and `jq -e` passes it
# because `[]` is truthy. Down targets are reported in the breakdown but deliberately do NOT fail
# the script: one flapping target is a thing to read, not a reason to call the stack unhealthy.
if ! probe 'http://127.0.0.1:18430/api/v1/targets' |
  jq -e '.data.activeTargets | select(length > 0) | group_by(.health) | map({health: .[0].health, count: length})'; then
  echo "(no active targets — vmagent scraping nothing or unreachable)"
  RC=1
fi

exit "$RC"
