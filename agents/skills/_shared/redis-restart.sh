#!/usr/bin/env bash
# Restart the opstree redis-ha pods one at a time, the way docs/SECRETS_ROTATION.md section 2
# step 5 describes, without pasting its shell functions:
#   replication  the replica, then the master (re-read by role before each delete), then check
#   sentinel     redis-sentinel-sentinel-0, -1, -2, then check
# Never `kubectl rollout restart` these StatefulSets: the operator loops on the restartedAt
# annotation (bf7bf65d). Each delete carries the pod's recorded UID as a precondition, so a pod
# the StatefulSet already replaced is never deleted twice. Deleting the master makes the sentinels
# promote the restarted replica; writes fail for a few seconds.
# If it stops midway, run it again: pods whose UID changed since THIS run started count as done.
# A later run restarts the pods an earlier run already restarted; that is safe.
# A new UID does not prove a new ACL: a pod restarted before Flux applied the commit reads the old
# Secret. So the script refuses to start until infrastructure-configs (the Kustomization that owns
# both Redis Secrets) reports the expected commit as applied.
# Ready does not prove the replica finished syncing before the master goes; the dataset is small.
#
# Usage: redis-restart.sh replication|sentinel <commit SHA that must be applied>
set -euo pipefail
NS=databases
sha="${2:-}"
if [ -z "$sha" ]; then
  echo "usage: $0 replication|sentinel <commit SHA that must be applied>" >&2
  exit 2
fi
applied="$(kubectl -n flux-system get kustomization infrastructure-configs -o jsonpath='{.status.lastAppliedRevision}')"
case "${applied##*:}" in
"$sha"*) ;;
*)
  echo "infrastructure-configs applied '${applied}', not $sha; reconcile first" >&2
  exit 1
  ;;
esac
case "${1:-}" in
replication)
  sel=app=redis-replication
  want=2
  ;;
sentinel)
  sel=app=redis-sentinel-sentinel
  want=3
  ;;
*)
  echo "usage: $0 replication|sentinel <commit SHA that must be applied>" >&2
  exit 2
  ;;
esac

old_uids="$(kubectl -n "$NS" get pod -l "$sel" -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}')"
if [ -z "$old_uids" ]; then
  echo "no pods match $sel; stopping" >&2
  exit 1
fi
pod_uid() { kubectl -n "$NS" get pod "$1" -o jsonpath='{.metadata.uid}'; }
is_old() { grep -q -x -F "$1" <<<"$old_uids"; }

restart_old() {
  local p="$1" uid new n=0
  uid="$(pod_uid "$p")"
  if [ -z "$uid" ]; then
    echo "cannot read the UID of $p" >&2
    return 1
  fi
  if is_old "$uid"; then
    printf '{"kind":"DeleteOptions","apiVersion":"v1","preconditions":{"uid":"%s"}}' "$uid" |
      kubectl delete --raw "/api/v1/namespaces/$NS/pods/$p" -f - >/dev/null
    until new="$(pod_uid "$p" 2>/dev/null)" && [ -n "$new" ] && [ "$new" != "$uid" ]; do
      n=$((n + 1))
      if [ "$n" -gt 90 ]; then
        echo "$p was not recreated within 3 min" >&2
        return 1
      fi
      sleep 2
    done
    echo "$p restarted"
  else
    echo "$p already restarted"
  fi
  kubectl -n "$NS" wait --for=condition=Ready "pod/$p" --timeout=180s >/dev/null
  echo "$p Ready"
}
role_pod() { kubectl -n "$NS" get pod -l "app=redis-replication,redis-role=$1" -o jsonpath='{.items[0].metadata.name}'; }

if [ "$1" = replication ]; then
  # Re-read each role just before its restart; a failover can move it. An empty answer means the
  # role label lags a failover, so stop rather than guess.
  for role in slave master; do
    p="$(role_pod "$role")"
    if [ -z "$p" ]; then
      echo "no pod carries redis-role=$role right now; wait and run again" >&2
      exit 1
    fi
    restart_old "$p"
  done
else
  for i in 0 1 2; do restart_old "redis-sentinel-sentinel-$i"; done
fi

# Every matching pod must now have a new UID and be Ready; a failover can move a role midway.
# The listing runs as a plain assignment so a failed kubectl stops the script, and the count must
# match: a pod missing from the list would otherwise pass unchecked.
names="$(kubectl -n "$NS" get pod -l "$sel" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
if [ "$(grep -c . <<<"$names")" != "$want" ]; then
  echo "NOT done: expected $want pods for $sel, found $(grep -c . <<<"$names"); run this again" >&2
  exit 1
fi
bad=0
while IFS= read -r p; do
  uid="$(pod_uid "$p")"
  ready="$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  if [ -z "$uid" ] || is_old "$uid" || [ "$ready" != True ]; then
    echo "NOT done: $p (old uid or not Ready); run this again" >&2
    bad=1
  fi
done <<<"$names"
if [ "$bad" = 1 ]; then exit 1; fi
echo "every pod of $sel restarted and Ready"

# Ready is not settled. After a replication restart both pods can report role:master until the
# operator re-attaches the replica (~50s on 2026-10-02), and the sentinels keep the old master IP
# until they restart. Wait for the state the next step depends on. After each failed pass the
# loop stops if 180s have passed; one more pass can therefore start up to 5s later, and each probe
# in a pass can take up to 15s.
# Each probe is bounded (`timeout`, coreutils): a stalled kubectl must not outlast the deadline.
command -v timeout >/dev/null || {
  echo "needs coreutils timeout for the settle check" >&2
  exit 1
}
k() { timeout 15 kubectl --request-timeout=10s "$@"; }
info() { k exec -n "$NS" "$1" -c redis-replication -- redis-cli INFO replication </dev/null 2>/dev/null | tr -d '\r'; }
settled_replication() {
  local masters=0 links=0 p i
  for p in redis-replication-0 redis-replication-1; do
    i="$(info "$p")"
    if grep -q '^role:master' <<<"$i" && grep -q '^connected_slaves:1' <<<"$i"; then masters=$((masters + 1)); fi
    if grep -q '^role:slave' <<<"$i" && grep -q '^master_link_status:up' <<<"$i"; then links=$((links + 1)); fi
  done
  [ "$masters" = 1 ] && [ "$links" = 1 ]
}
settled_sentinel() {
  local mip s
  mip="$(k -n "$NS" get pod -l app=redis-replication,redis-role=master -o jsonpath='{.items[0].status.podIP}')"
  [ -n "$mip" ] || return 1
  for s in 0 1 2; do
    [ "$(k exec -n "$NS" "redis-sentinel-sentinel-$s" -- redis-cli -p 26379 sentinel get-master-addr-by-name myMaster </dev/null 2>/dev/null | head -1)" = "$mip" ] || return 1
  done
  k exec -n "$NS" redis-sentinel-sentinel-0 -- redis-cli -p 26379 sentinel ckquorum myMaster </dev/null 2>/dev/null | grep -q '^OK'
}
deadline=$((SECONDS + 180))
until "settled_$1"; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "NOT settled after 3 min ($1): check roles, replica link and sentinels before the next step" >&2
    exit 1
  fi
  sleep 5
done
if [ "$1" = replication ]; then
  echo "settled: one master with one replica, link up"
else
  echo "settled: all 3 sentinels name the current master and quorum is OK"
fi
