#!/usr/bin/env bash
# Live audit of pod priorityClassName / priority across cluster.
# Shows which pods run at the critical/standard/batch tiers and which have no tier.
#
# Flags:
#   --count        per-tier pod counts (homelab-critical/-standard/-batch/none)
#   --missing      Running pods with NO priorityClassName, grouped by ns
#   --tier <name>  list pods at given priorityClass (ns/name node)
#   --json         raw json: [{ns,name,node,priorityClassName,priority,phase}]
#   (default)      summary table: tier | count | sample pods

set -euo pipefail

mode="${1:-summary}"
arg="${2:-}"

# Fetch once. -o json is cheaper than 4 separate kubectl calls.
pods_json=$(kubectl get pod -A -o json)

case "$mode" in
--count)
  echo "$pods_json" | jq -r '
    [.items[] | {pc: (.spec.priorityClassName // "none"), phase: .status.phase}]
    | group_by(.pc) | map({tier: .[0].pc, count: length})
    | sort_by(.tier) | .[] | "\(.tier)=\(.count)"
  ' | tr '\n' ' '
  echo
  ;;
--missing)
  # Join the pod names inside map(): a join inside the string interpolation needs nested quotes.
  echo "$pods_json" | jq -r '
    [.items[] | select(.status.phase=="Running" and (.spec.priorityClassName // "")=="")]
    | group_by(.metadata.namespace)
    | map({
        ns: .[0].metadata.namespace,
        count: length,
        pods: ([.[].metadata.name] | join(", "))
      })
    | sort_by(.ns) | .[] | "\(.ns) (\(.count)): \(.pods)"
  '
  ;;
--tier)
  [ -z "$arg" ] && {
    echo "usage: $0 --tier <name>" >&2
    exit 2
  }
  echo "$pods_json" | jq -r --arg t "$arg" '
    .items[] | select(.spec.priorityClassName==$t)
    | "\(.metadata.namespace)/\(.metadata.name) on \(.spec.nodeName) phase=\(.status.phase)"
  ' | sort
  ;;
--json)
  echo "$pods_json" | jq '[.items[] | {
    ns: .metadata.namespace, name: .metadata.name, node: .spec.nodeName,
    priorityClassName: .spec.priorityClassName, priority: .spec.priority,
    phase: .status.phase
  }]'
  ;;
*)
  printf "%-22s %-7s %s\n" "TIER" "COUNT" "SAMPLE"
  printf "%-22s %-7s %s\n" "----" "-----" "------"
  echo "$pods_json" | jq -r '
    [.items[] | {pc: (.spec.priorityClassName // "<none>"), ns: .metadata.namespace, name: .metadata.name}]
    | group_by(.pc) | sort_by(.[0].pc) | .[]
    | {tier: .[0].pc, count: length, sample: [.[:3] | .[] | "\(.ns)/\(.name)"]|join(", ")}
    | "\(.tier)\t\(.count)\t\(.sample)"
  ' | awk -F'\t' '{printf "%-22s %-7s %s\n", $1, $2, $3}'
  ;;
esac
