#!/usr/bin/env bash
# Query VMSingle for container CPU throttle rate (5m window).
# TSDB is VictoriaMetrics (port 8429 inside vmsingle pod) — no kube-prometheus pod.
#
# Usage:
#   cpu-throttling.sh                       # all containers, sorted by rate desc
#   cpu-throttling.sh -n <ns>               # filter by namespace
#   cpu-throttling.sh -n <ns> -p <pod>      # one pod
#   cpu-throttling.sh --json                # raw VMSingle response

set -euo pipefail

NS=""
POD=""
MODE="text"

while [ $# -gt 0 ]; do
  case "$1" in
  -n)
    NS="$2"
    shift 2
    ;;
  -p)
    POD="$2"
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

selector=""
if [ -n "$NS" ]; then
  selector="namespace=\"$NS\""
fi
if [ -n "$POD" ]; then
  [ -n "$selector" ] && selector+=","
  selector+="pod=\"$POD\""
fi

if [ -n "$selector" ]; then
  Q="rate(container_cpu_cfs_throttled_seconds_total{${selector}}[5m])"
else
  Q="rate(container_cpu_cfs_throttled_seconds_total[5m])"
fi

# Through the API server's service proxy: the claude-telegram bot's grant in monitoring is `get`
# on services/proxy for vmsingle-vmsingle:8429.
RAW="$(kubectl get --raw "/api/v1/namespaces/monitoring/services/vmsingle-vmsingle:8429/proxy/api/v1/query?query=$(printf '%s' "$Q" | jq -sRr @uri)")"

if [ "$MODE" = "json" ]; then
  echo "$RAW"
  exit 0
fi

echo "$RAW" | jq -r '
  .data.result
  # cAdvisor emits a pod-aggregate series (no .container label = sum across
  # the pod) plus per-container series keyed by runtime ID. Use the aggregate
  # — runtime IDs are noisy and friendly container names are not relabeled
  # in this cluster.
  | map(select(.metric.container == null and (.value[1] | tonumber) > 0))
  | sort_by(-(.value[1] | tonumber))
  | .[]
  | "\(.value[1] | tonumber | tostring | .[0:8])  \(.metric.namespace // "?")/\(.metric.pod // "?")"
'
