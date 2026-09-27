#!/usr/bin/env bash
# Kyverno PolicyReport check — single source (was 3 drifted copies: gitops-verify,
# monitoring-check, monthly-review inline jq; consolidated 2026-07-16).
# Fetch failure exits 2 with a stderr message — never silently empty.
#
# Usage:
#   check-kyverno.sh             # print "<count> <policy>" per offender
#   check-kyverno.sh --count     # print "violations=N policies=M"
#   check-kyverno.sh --json      # full failing results as JSON array
#   check-kyverno.sh --summary   # pass/fail/warn totals across all reports
#   check-kyverno.sh --modes     # per-offender top-20 + vpol actions/READY table

set -euo pipefail

MODE="${1:-text}"

if ! RAW="$(kubectl get policyreport -A -o json 2>/dev/null)"; then
  echo "policyreport fetch failed" >&2
  exit 2
fi
JSON="$(printf '%s' "$RAW" | jq '[.items[].results[]? | select(.result=="fail")]')"

case "$MODE" in
text)
  echo "$JSON" | jq -r '.[].policy' | sort | uniq -c | awk '{$1=$1; print}'
  ;;
--count)
  total="$(echo "$JSON" | jq 'length')"
  policies="$(echo "$JSON" | jq '[.[].policy] | unique | length')"
  echo "violations=${total} policies=${policies}"
  ;;
--json)
  echo "$JSON"
  ;;
--summary)
  printf '%s' "$RAW" | jq -r '[.items[].summary] | {pass:([.[].pass]|add), fail:([.[].fail]|add), warn:([.[].warn]|add)}'
  ;;
--modes)
  echo "=== violations by policy (top 20) ==="
  echo "$JSON" | jq -r '.[] | "\(.policy): \(.resources[0].namespace)/\(.resources[0].name)"' |
    sort | uniq -c | sort -rn | awk 'NR<=20'
  echo
  echo "=== policy actions (CEL ValidatingPolicies — sole engine since 2026-07-12) ==="
  kubectl get vpol -o custom-columns=NAME:.metadata.name,ACTIONS:'.spec.validationActions[*]',READY:'.status.conditionStatus.ready' 2>/dev/null || echo "(unavailable)"
  ;;
*)
  echo "unknown mode: $MODE (text|--count|--json|--summary|--modes)" >&2
  exit 2
  ;;
esac
