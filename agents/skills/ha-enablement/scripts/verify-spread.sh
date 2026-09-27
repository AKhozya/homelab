#!/usr/bin/env bash
# Verify HA pod spread across nodes for a workload.
# Pass/fail = pods running on distinct nodes when replicas >= 2.
#
# Usage:
#   verify-spread.sh -n <ns> -l <label-selector>
#   verify-spread.sh -n monitoring -l app.kubernetes.io/name=alertmanager
#   verify-spread.sh -n databases -l cnpg.io/cluster=main-postgres --json

set -euo pipefail

NS=""
SEL=""
MODE="text"

while [ $# -gt 0 ]; do
  case "$1" in
  -n)
    NS="$2"
    shift 2
    ;;
  -l)
    SEL="$2"
    shift 2
    ;;
  --json)
    MODE="json"
    shift
    ;;
  -h | --help)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "unknown flag: $1" >&2
    exit 2
    ;;
  esac
done

if [ -z "$NS" ] || [ -z "$SEL" ]; then
  echo "usage: $0 -n <ns> -l <label-selector> [--json]" >&2
  exit 2
fi

PODS_JSON="$(kubectl get pods -n "$NS" -l "$SEL" -o json)"

count="$(echo "$PODS_JSON" | jq '.items | length')"
if [ "$count" -eq 0 ]; then
  echo "no pods match selector '$SEL' in ns '$NS'" >&2
  exit 3
fi

NODES_JSON="$(echo "$PODS_JSON" | jq '[.items[] | {pod: .metadata.name, node: .spec.nodeName, phase: .status.phase}]')"
# Spread verdict counts ONLY Running pods with a node: a Pending pod (node=null) or a
# Succeeded/Terminating leftover would inflate unique_nodes and PASS a non-HA state.
running_count="$(echo "$NODES_JSON" | jq '[.[] | select(.phase=="Running" and .node != null)] | length')"
unique_nodes="$(echo "$NODES_JSON" | jq '[.[] | select(.phase=="Running" and .node != null) | .node] | unique | length')"

if [ "$MODE" = "json" ]; then
  echo "$NODES_JSON" | jq --arg s "$SEL" --arg n "$NS" \
    '([.[] | select(.phase=="Running" and .node != null)]) as $run
     | {namespace: $n, selector: $s, replicas: length, running: ($run | length),
        unique_nodes: ([$run[].node] | unique | length),
        spread: (($run | length) >= 2 and ([$run[].node] | unique | length) >= 2), pods: .}'
  exit 0
fi

printf '%-40s %-25s %s\n' POD NODE PHASE
echo "$NODES_JSON" | jq -r '.[] | "\(.pod)\t\(.node // "<unscheduled>")\t\(.phase)"' |
  awk -F'\t' '{printf "%-40s %-25s %s\n", $1, $2, $3}'

echo
if [ "$running_count" -ge 2 ] && [ "$unique_nodes" -ge 2 ]; then
  echo "PASS: ${running_count} running replicas across ${unique_nodes} nodes (${count} matched)"
elif [ "$running_count" -ge 2 ]; then
  echo "FAIL: ${running_count} running replicas on ${unique_nodes} node — anti-affinity missing or quota stuck"
  exit 1
elif [ "$count" -ge 2 ]; then
  echo "FAIL: ${count} replicas matched but only ${running_count} Running+scheduled — not HA right now"
  exit 1
else
  echo "INFO: single replica (not HA)"
fi
