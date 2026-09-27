#!/usr/bin/env bash
# Find namespaces with pods but no NetworkPolicy (Kyverno gap).
#
# Output (one per line): WARNING: <ns> has <pods> pods but no NetworkPolicy
# Exit 0 if no gaps; 1 if any; 2 if the namespace list could not be fetched.

set -euo pipefail

ns_list="$(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')" || ns_list=""
[ -n "$ns_list" ] || {
  echo "namespace list fetch failed" >&2
  exit 2
}

found=0
while IFS= read -r ns; do
  [ -z "$ns" ] && continue
  pods=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  policies=$(kubectl get networkpolicy -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$pods" -gt 0 ] && [ "$policies" -eq 0 ]; then
    echo "WARNING: $ns has $pods pods but no NetworkPolicy"
    found=1
  fi
done <<<"$ns_list"

exit $found
