#!/usr/bin/env bash
# Discover current Redis master via Sentinel quorum (default) or pod label (--label).
# Master moves on failover — never hardcode pod-0.
#
# Usage:
#   redis-master.sh                  # prints master host (IP) from Sentinel
#   redis-master.sh --label          # prints master pod name from operator label
#   redis-master.sh info             # INFO replication from current master
#   redis-master.sh exec "CMD..."    # run redis-cli command on master
#
# --label is faster (no kubectl exec) but trusts the OT operator to keep the
# `redis-role=master` label current. Sentinel is authoritative; use --label
# for quick checks where slight staleness is acceptable.

set -euo pipefail
NS="${REDIS_NS:-databases}"
SENTINEL_STS="${REDIS_SENTINEL_STS:-redis-sentinel-sentinel}"
DATA_STS="${REDIS_DATA_STS:-redis-replication}"
MASTER_NAME="${REDIS_MASTER_NAME:-myMaster}"
LABEL_SELECTOR="${REDIS_LABEL_SELECTOR:-app=redis-replication,redis-role=master}"

if [ "${1:-}" = "--label" ]; then
  shift
  MASTER_POD="$(kubectl get pod -n "$NS" -l "$LABEL_SELECTOR" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -z "$MASTER_POD" ]; then
    echo "no pod matched label '$LABEL_SELECTOR' in ns '$NS'" >&2
    exit 3
  fi
  echo "$MASTER_POD"
  exit 0
fi

# NB: `| head -1` would SIGPIPE upstream under `pipefail` and silently empty MASTER.
# Use awk NR==1 which reads all lines but only prints the first.
MASTER="$(kubectl exec -n "$NS" "sts/${SENTINEL_STS}" -- \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name "$MASTER_NAME" 2>/dev/null | awk 'NR==1')"
if [ -z "$MASTER" ]; then
  echo "sentinel did not return a master (name=$MASTER_NAME)" >&2
  exit 3
fi

# Password lives in `redis-passwords` secret (multi-tenant — admin-password = ops key).
# Fall back to no auth if secret/key missing; data-plane may not require it.
PW="$(kubectl get secret -n "$NS" redis-passwords -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || true)"

AUTH=()
[ -n "$PW" ] && AUTH=(-a "$PW")

ACTION="${1:-print}"
case "$ACTION" in
print)
  echo "$MASTER"
  ;;
info)
  exec kubectl exec -n "$NS" "sts/${DATA_STS}" -- \
    redis-cli -h "$MASTER" "${AUTH[@]}" INFO replication
  ;;
exec)
  shift
  if [ "$#" -eq 0 ]; then
    echo "usage: $0 exec <redis-cli args...>" >&2
    exit 2
  fi
  exec kubectl exec -n "$NS" "sts/${DATA_STS}" -- \
    redis-cli -h "$MASTER" "${AUTH[@]}" "$@"
  ;;
*)
  echo "unknown action: $ACTION (print|info|exec)" >&2
  exit 2
  ;;
esac
