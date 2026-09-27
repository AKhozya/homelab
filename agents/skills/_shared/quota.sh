#!/usr/bin/env bash
# Show ResourceQuota for namespace + current top usage.
#
# Usage:
#   quota.sh <namespace>
#   quota.sh <namespace> --json   # parse via jq

set -euo pipefail
NS="${1:-}"
FMT="${2:-text}"

if [ -z "$NS" ]; then
  echo "usage: $0 <namespace> [--json]" >&2
  exit 2
fi

case "$FMT" in
--json)
  kubectl get resourcequota -n "$NS" -o json 2>/dev/null |
    jq '[.items[] | {name: .metadata.name, hard: .status.hard, used: .status.used}]'
  ;;
*)
  echo "=== ResourceQuota ==="
  kubectl describe resourcequota -n "$NS" 2>/dev/null || echo "(no resourcequota in $NS)"
  echo
  echo "=== Top pods ==="
  kubectl top pods -n "$NS" 2>/dev/null || echo "(metrics unavailable)"
  ;;
esac
