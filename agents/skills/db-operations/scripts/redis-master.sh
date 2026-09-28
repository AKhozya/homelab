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

# redis-cli runs in the sentinel container, which already holds the ops password as
# MASTER_PASSWORD (from redis-passwords/admin-password). REDISCLI_AUTH passes it without an argv
# entry, and the password never leaves the pod. An empty MASTER_PASSWORD means no auth.
# shellcheck disable=SC2016
IN_POD='[ -z "${MASTER_PASSWORD:-}" ] || export REDISCLI_AUTH="$MASTER_PASSWORD"; exec redis-cli "$@"'
cli() {
  exec kubectl exec -n "$NS" "sts/${SENTINEL_STS}" -c "$SENTINEL_STS" -- sh -c "$IN_POD" in-pod "$@"
}

ACTION="${1:-print}"
case "$ACTION" in
print)
  echo "$MASTER"
  ;;
info)
  cli -h "$MASTER" INFO replication
  ;;
exec)
  shift
  if [ "$#" -eq 0 ]; then
    echo "usage: $0 exec <redis-cli args...>" >&2
    exit 2
  fi
  cli -h "$MASTER" "$@"
  ;;
*)
  echo "unknown action: $ACTION (print|info|exec)" >&2
  exit 2
  ;;
esac
