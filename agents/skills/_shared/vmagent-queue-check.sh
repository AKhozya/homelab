#!/usr/bin/env bash
# Check VMAgent remoteWrite queue health.
# Growing queue + DNS errors = stuck Go resolver. Cheap fix: restart vmagent.
#
# Output: pending bytes + dropped + recent errors.
# Exit 0 always (read-only diagnostic).

set -euo pipefail

PF_PORT="${PF_PORT:-18430}"
kubectl port-forward -n monitoring svc/vmagent-vmagent "${PF_PORT}:8429" >/dev/null 2>&1 &
PF=$!
trap '[ -n "${PF:-}" ] && kill "$PF" 2>/dev/null || true' EXIT
sleep 1

echo "=== persistent queue ==="
curl -s "http://127.0.0.1:${PF_PORT}/metrics" 2>/dev/null |
  grep -E 'vm_persistentqueue_bytes_(pending|dropped_total)' |
  awk '{printf "%s = %s\n", $1, $2}' || echo "(metrics endpoint unreachable)"

echo
echo "=== recent remoteWrite errors (last 5) ==="
VMA="$(kubectl get pods -n monitoring -l app.kubernetes.io/name=vmagent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -n "$VMA" ]; then
  kubectl logs -n monitoring "$VMA" -c vmagent --tail=200 2>/dev/null |
    grep -iE 'couldn.t send|dial tcp|lookup .* refused|context deadline' |
    tail -5 || echo "(no recent remoteWrite errors)"
else
  echo "(vmagent pod not found)"
fi

cat <<'EOF'

=== fix hint ===
If pending > 10MB AND errors mention DNS lookup refused → Go resolver stuck.
Restart vmagent (cheap, safe). NOT `rollout restart` — the bot has no workload patch since
2026-08-06 — and not a bare `delete pod -l`, which drops every replica at once and whose
`rollout status` does not gate on the replacement. Use the shared helper:
  ~/.agents/skills/_shared/restart-workload.sh monitoring app.kubernetes.io/name=vmagent
EOF
