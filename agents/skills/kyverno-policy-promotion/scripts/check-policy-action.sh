#!/usr/bin/env bash
# check-policy-action.sh — read live validationActions of a Kyverno ValidatingPolicy
#
# Usage:
#   check-policy-action.sh <policy-name>
#
# Output: unique action value(s) on stdout — "Audit" / "Deny" / "Audit,Warn" / "unknown"
# Exit codes:
#   0 = policy found, action printed
#   1 = policy not found
#   2 = usage / dependency error

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <policy-name>" >&2
  exit 2
fi

POLICY="$1"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: kubectl not found" >&2
  exit 2
fi

# policies.kyverno.io/v1 ValidatingPolicy (short name vpol) — the only policy kind
# in the cluster since the CP→VP migration completed 2026-07-12.
if ! kubectl get vpol "$POLICY" >/dev/null 2>&1; then
  echo "error: ValidatingPolicy not found: $POLICY" >&2
  exit 1
fi

ACTION="$(kubectl get vpol "$POLICY" -o jsonpath='{.spec.validationActions[*]}' 2>/dev/null || true)"

# Collapse to unique sorted value(s): "Deny Deny" -> "Deny"; mixed -> "Audit,Deny".
if [[ -n "$ACTION" ]]; then
  read -ra _acts <<<"$ACTION"
  ACTION="$(printf '%s\n' "${_acts[@]}" | sort -u | paste -sd, -)"
fi

if [[ -z "$ACTION" ]]; then
  echo "unknown"
  exit 0
fi

echo "$ACTION"
