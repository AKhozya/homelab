#!/usr/bin/env bash
# Full CNPG rolling restart: restart replica → promote → restart again.
# Use when a Cluster.spec change isn't auto-rolled (e.g. priorityClassName on v1.29.x).

set -euo pipefail

NS="${1:?namespace, e.g. databases}"
CLUSTER="${2:?cluster name, e.g. main-postgres}"
TIMEOUT_RESTART="${TIMEOUT_RESTART:-300}"
TIMEOUT_HEALTHY="${TIMEOUT_HEALTHY:-180}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

age_seconds_of_pod() {
  local pod="$1"
  local ts
  ts=$(kubectl get pod -n "$NS" "$pod" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || echo "")
  [ -z "$ts" ] && {
    echo "0"
    return
  }
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" "+%s" 2>/dev/null ||
    date -u -d "$ts" "+%s" 2>/dev/null ||
    echo "0"
}

wait_cluster_healthy() {
  local timeout="$1"
  local start
  start=$(date +%s)
  while :; do
    local ready instances
    ready=$(kubectl get cluster -n "$NS" "$CLUSTER" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")
    instances=$(kubectl get cluster -n "$NS" "$CLUSTER" -o jsonpath='{.status.instances}' 2>/dev/null || echo "0")
    # -n: if both status fields are absent, both queries print "" and the strings compare equal.
    if [ -n "$ready" ] && [ "$ready" = "$instances" ] && [ "$ready" != "0" ]; then
      echo "OK: cluster healthy $ready/$instances"
      return
    fi
    if [ "$(($(date +%s) - start))" -ge "$timeout" ]; then
      die "cluster not healthy after ${timeout}s (ready=$ready instances=$instances)"
    fi
    sleep 5
  done
}

# 1. Snapshot
START_EPOCH=$(date -u +%s)
PRIMARY_BEFORE=$(kubectl get cluster -n "$NS" "$CLUSTER" -o jsonpath='{.status.currentPrimary}')
[ -z "$PRIMARY_BEFORE" ] && die "no current primary on $NS/$CLUSTER"
# {.items[*]} + first word: with zero replicas, {.items[0]} makes kubectl itself error out
# under set -e and the die below would never fire.
REPLICA_BEFORE=$(kubectl get pod -n "$NS" \
  -l "cnpg.io/cluster=$CLUSTER,cnpg.io/instanceRole=replica" \
  -o jsonpath='{.items[*].metadata.name}' | awk '{print $1}')
[ -z "$REPLICA_BEFORE" ] && die "no replica found on $NS/$CLUSTER"
echo "start: primary=$PRIMARY_BEFORE replica=$REPLICA_BEFORE"

# 2. Restart (rolls replica only — cluster stays healthy)
echo "step 1/4: kubectl cnpg restart (rolls replica)..."
kubectl cnpg restart -n "$NS" "$CLUSTER" >/dev/null

# 3. Wait for replica to roll. CNPG may rename replica pod (sequential numbering changes).
#    Identify "new replica" = pod with instanceRole=replica AND creationTimestamp > start.
echo "step 2/4: waiting for replica to roll (timeout=${TIMEOUT_RESTART}s)..."
start=$(date +%s)
NEW_REPLICA=""
while :; do
  for p in $(kubectl get pod -n "$NS" -l "cnpg.io/cluster=$CLUSTER,cnpg.io/instanceRole=replica" -o jsonpath='{.items[*].metadata.name}'); do
    age=$(age_seconds_of_pod "$p")
    if [ "$age" -gt "$START_EPOCH" ]; then
      NEW_REPLICA="$p"
      break 2
    fi
  done
  if [ "$(($(date +%s) - start))" -ge "$TIMEOUT_RESTART" ]; then
    die "no replica rolled after ${TIMEOUT_RESTART}s"
  fi
  sleep 5
done
echo "OK: replica rolled to $NEW_REPLICA"
wait_cluster_healthy "$TIMEOUT_HEALTHY"

# 4. Promote new replica → switchover. Old primary becomes replica.
echo "step 3/4: kubectl cnpg promote $NEW_REPLICA (switchover)..."
kubectl cnpg promote -n "$NS" "$CLUSTER" "$NEW_REPLICA" >/dev/null
start=$(date +%s)
while [ "$(kubectl get cluster -n "$NS" "$CLUSTER" -o jsonpath='{.status.currentPrimary}')" != "$NEW_REPLICA" ]; do
  if [ "$(($(date +%s) - start))" -ge "$TIMEOUT_HEALTHY" ]; then
    die "promote: cluster never marked $NEW_REPLICA as primary after ${TIMEOUT_HEALTHY}s"
  fi
  sleep 3
done
echo "OK: new primary $NEW_REPLICA"

# 5. Restart again — rolls the just-demoted old primary (now replica).
echo "step 4/4: kubectl cnpg restart again (rolls old primary)..."
kubectl cnpg restart -n "$NS" "$CLUSTER" >/dev/null

# 6. Wait until BOTH instances are newer than START_EPOCH.
echo "waiting for both instances to be newer than start..."
start=$(date +%s)
while :; do
  # Capture the list first and require >=2 pods: a transient kubectl failure yields an
  # empty list, which would leave all_new=true and false-complete with the old primary
  # never rolled (the async restart may also simply not have started yet).
  pods="$(kubectl get pod -n "$NS" -l "cnpg.io/cluster=$CLUSTER,cnpg.io/podRole=instance" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  if [ "$(echo "$pods" | wc -w | tr -d ' ')" -ge 2 ]; then
    all_new=true
    for p in $pods; do
      age=$(age_seconds_of_pod "$p")
      if [ "$age" -le "$START_EPOCH" ]; then
        all_new=false
        break
      fi
    done
    $all_new && break
  fi
  if [ "$(($(date +%s) - start))" -ge "$TIMEOUT_RESTART" ]; then
    die "second restart: not all instances rolled after ${TIMEOUT_RESTART}s"
  fi
  sleep 5
done
wait_cluster_healthy "$TIMEOUT_HEALTHY"

# 7. Final assert: a failover during the second restart could have moved the primary —
# confirm the promoted pod still holds it before declaring success.
FINAL_PRIMARY=$(kubectl get cluster -n "$NS" "$CLUSTER" -o jsonpath='{.status.currentPrimary}' 2>/dev/null || echo "")
[ "$FINAL_PRIMARY" = "$NEW_REPLICA" ] ||
  die "final primary is '$FINAL_PRIMARY', expected promoted pod '$NEW_REPLICA' (failover mid-roll?) — inspect before trusting this roll"

echo
echo "DONE — final state:"
kubectl get pod -n "$NS" -l "cnpg.io/cluster=$CLUSTER,cnpg.io/podRole=instance" \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,ROLE:.metadata.labels.cnpg\.io/instanceRole,NODE:.spec.nodeName,AGE:.metadata.creationTimestamp'
