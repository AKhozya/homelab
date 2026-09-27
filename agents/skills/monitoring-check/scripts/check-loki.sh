#!/usr/bin/env bash
# Loki health: pods + ready endpoint.
# Loki image is distroless — no shell/curl/wget. Hit via port-forward + curl.

set -euo pipefail

cleanup() {
  for pid in "${PFS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT
PFS=()

probe() { # retry: port-forward takes a moment to bind
  local out
  for _ in 1 2 3 4 5; do
    if out="$(curl -fsSL --max-time 3 "$1" 2>/dev/null)" && [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
    sleep 0.5
  done
  return 1
}

echo "=== pods ==="
kubectl get pods -n loki 2>/dev/null || true

echo
echo "=== ready (port-forward svc/loki:3100) ==="
kubectl port-forward -n loki svc/loki 13100:3100 >/dev/null 2>&1 &
PFS+=("$!")
probe 'http://127.0.0.1:13100/ready' || echo "(unreachable)"
