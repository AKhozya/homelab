#!/usr/bin/env bash
# Pin homelab DB primary to a target node.
# Per-engine: cnpg|percona|redis. See SKILL.md.

set -euo pipefail

ENGINE="${1:?engine: cnpg|percona|redis}"
TARGET="${2:?cluster spec — ns/name for cnpg+percona, ns for redis}"
NODE="${3:?target node, e.g. worker-node}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

wait_until() {
  local label="$1" timeout="$2" check="$3"
  local start
  start=$(date +%s)
  while ! eval "$check"; do
    if [ "$(($(date +%s) - start))" -ge "$timeout" ]; then
      die "$label: timed out after ${timeout}s"
    fi
    sleep 3
  done
  echo "OK: $label"
}

case "$ENGINE" in

cnpg)
  NS="${TARGET%/*}"
  CLUSTER="${TARGET#*/}"
  [ "$NS" = "$CLUSTER" ] && die "cnpg cluster must be ns/name"

  current=$(kubectl get cluster -n "$NS" "$CLUSTER" -o jsonpath='{.status.currentPrimary}')
  [ -z "$current" ] && die "no current primary on $NS/$CLUSTER"

  current_node=$(kubectl get pod -n "$NS" "$current" -o jsonpath='{.spec.nodeName}')
  echo "current: $current on $current_node"
  if [ "$current_node" = "$NODE" ]; then
    echo "already on target node $NODE — nothing to do"
    exit 0
  fi

  # Find a replica on the target node to promote.
  target_pod=$(kubectl get pod -n "$NS" \
    -l "cnpg.io/cluster=$CLUSTER,cnpg.io/instanceRole=replica" \
    -o json | jq -r --arg n "$NODE" 'first(.items[] | select(.spec.nodeName==$n) | .metadata.name) // ""')
  [ -z "$target_pod" ] && die "no replica on $NODE; check anti-affinity / availability"

  echo "promoting $target_pod ..."
  kubectl cnpg promote -n "$NS" "$CLUSTER" "$target_pod"

  wait_until "primary on $NODE" 120 \
    "[ \"\$(kubectl get cluster -n \"$NS\" \"$CLUSTER\" -o jsonpath='{.status.currentPrimary}')\" = \"$target_pod\" ]"
  # Non-empty + nonzero guards: a kubectl failure expands both sides to "" and
  # "" = "" would pass the health wait instantly (false OK).
  wait_until "cluster healthy 2/2" 180 \
    "r=\"\$(kubectl get cluster -n \"$NS\" \"$CLUSTER\" -o jsonpath='{.status.readyInstances}')\"; i=\"\$(kubectl get cluster -n \"$NS\" \"$CLUSTER\" -o jsonpath='{.status.instances}')\"; [ -n \"\$r\" ] && [ \"\$r\" != 0 ] && [ \"\$r\" = \"\$i\" ]"
  ;;

percona)
  NS="${TARGET%/*}"
  CLUSTER="${TARGET#*/}"
  [ "$NS" = "$CLUSTER" ] && die "percona cluster must be ns/name"

  # Orchestrator picks primary; query via orc pod.
  ORC="${CLUSTER}-orc-0"
  fqdn_for() { echo "${CLUSTER}-mysql-${1}.${CLUSTER}-mysql.${NS}:3306"; }
  # The operator sets ORC_API_AUTH=true, so the API wants basic auth (user orchestrator reads
  # and writes). The wrapper reads the password inside the pod, from the file the orchestrator
  # entrypoint reads, so it never reaches this host or an argv.
  orc() {
    # shellcheck disable=SC2016
    kubectl exec -n "$NS" "$ORC" -c orchestrator -- bash -c '
      ORCHESTRATOR_AUTH_USER=orchestrator
      ORCHESTRATOR_AUTH_PASSWORD=$(<"/etc/orchestrator/orchestrator-users-secret/orchestrator") || exit 1
      export ORCHESTRATOR_AUTH_USER ORCHESTRATOR_AUTH_PASSWORD
      exec orchestrator-client "$@"' orc "$@"
  }
  # The primary line starts "<cluster>-mysql-<N>.<cluster>-mysql.<ns>:3306". Match the full cluster
  # prefix, because splitting on "-mysql-" turns main-mysql-mysql-1 into "mysql-1".
  primary_idx() {
    awk '/rw,/{print $1; exit}' | sed -n "s/^${CLUSTER}-mysql-\([0-9][0-9]*\)\..*/\1/p"
  }
  # mysql-replicas server names are pod IPs with dashes: "server 10-42-2-71 10-42-2-71.<svc>:3306 ...".
  replica_servers() {
    awk '$1=="backend"{f=($2=="mysql-replicas"); next} f && $1=="server"{print $2}' | sort
  }
  PROXY_SEL="app.kubernetes.io/instance=$CLUSTER,app.kubernetes.io/component=proxy"
  haproxy_ready() {
    kubectl get pod -n "$NS" "$1" -o json 2>/dev/null |
      jq -e --arg u "$2" '.metadata.uid != $u and any(.status.conditions[]?; .type=="Ready" and .status=="True")' >/dev/null
  }
  # If no other proxy is Ready, deleting this one stops all MySQL access until its replacement is Ready.
  other_proxy_ready() {
    kubectl get pod -n "$NS" -l "$PROXY_SEL" -o json |
      jq -e --arg x "$1" 'any(.items[]; .metadata.name != $x and .metadata.deletionTimestamp == null
        and any(.status.conditions[]?; .type=="Ready" and .status=="True"))' >/dev/null
  }
  case "${PIN_PARSE_ONLY:-}" in
  1)
    primary_idx
    exit 0
    ;;
  haproxy)
    replica_servers
    exit 0
    ;;
  esac

  current_idx=$(orc -c topology -i "$(fqdn_for 0)" | primary_idx)
  [ -z "$current_idx" ] && die "could not determine current primary index"

  current_pod="${CLUSTER}-mysql-${current_idx}"
  current_node=$(kubectl get pod -n "$NS" "$current_pod" -o jsonpath='{.spec.nodeName}')
  echo "current: $current_pod on $current_node"
  if [ "$current_node" = "$NODE" ]; then
    echo "already on target node $NODE — nothing to do"
    exit 0
  fi

  # Pre-flight: graceful-master-takeover-auto takes NO destination — it promotes the
  # most-advanced replica. Refuse to mutate unless a replica actually sits on $NODE.
  candidate=$(kubectl get pod -n "$NS" -o json |
    jq -r --arg pfx "${CLUSTER}-mysql-" --arg n "$NODE" --arg cur "$current_pod" \
      'first(.items[] | select((.metadata.name | startswith($pfx)) and .spec.nodeName==$n and .metadata.name!=$cur) | .metadata.name) // ""')
  [ -z "$candidate" ] && die "no mysql replica on $NODE — takeover would land elsewhere; check placement first"

  echo "graceful master takeover from $current_pod ..."
  new_primary_fqdn=$(orc -c graceful-master-takeover-auto -i "$(fqdn_for "$current_idx")" |
    awk 'NR==1{gsub(/[ \r]/,""); print; exit}')
  echo "orchestrator says new primary: $new_primary_fqdn"

  wait_until "topology primary changed" 120 \
    "idx=\"\$(orc -c topology -i \"$(fqdn_for 0)\" | primary_idx)\"; [ -n \"\$idx\" ] && [ \"\$idx\" != \"$current_idx\" ]"

  # Post-assert: the new primary must actually sit on $NODE (with >2 replicas the
  # takeover can land elsewhere — fail loud instead of printing a false OK).
  new_idx=$(orc -c topology -i "$(fqdn_for 0)" | primary_idx)
  [ -n "$new_idx" ] || die "could not resolve new primary index after takeover"
  new_node=$(kubectl get pod -n "$NS" "${CLUSTER}-mysql-${new_idx}" -o jsonpath='{.spec.nodeName}')
  [ "$new_node" = "$NODE" ] || die "takeover landed on ${CLUSTER}-mysql-${new_idx} ($new_node), NOT $NODE — re-run or fix placement"
  echo "OK: primary pod ${CLUSTER}-mysql-${new_idx} on $NODE"

  # HAProxy writes its mysql-replicas list only at pod start, and a takeover keeps the pod IPs, so
  # the list now names the new primary and MySQLReplicaExporterDown fires. Restart the proxies one
  # at a time, so one always serves, and require each list to name exactly the replicas.
  want=$(kubectl get pod -n "$NS" -l "app.kubernetes.io/instance=$CLUSTER,app.kubernetes.io/component=database" -o json |
    jq -r --arg p "${CLUSTER}-mysql-${new_idx}" '.items[] | select(.metadata.name != $p) | .status.podIP // "" | gsub("\\."; "-")' | sort)
  [ -n "$want" ] || die "found no replica pod IPs for $CLUSTER"
  proxies=$(kubectl get pod -n "$NS" -l "$PROXY_SEL" -o json |
    jq -r '.items[].metadata.name' | sort -r)
  [ -n "$proxies" ] || die "found no HAProxy pods for $CLUSTER"
  for hp in $proxies; do
    other_proxy_ready "$hp" || die "no other Ready HAProxy pod, so $hp stays up; restart it by hand once another proxy is Ready"
    old_uid=$(kubectl get pod -n "$NS" "$hp" -o jsonpath='{.metadata.uid}')
    kubectl delete pod -n "$NS" "$hp"
    wait_until "$hp recreated and Ready" 300 "haproxy_ready '$hp' '$old_uid'"
    got=$(kubectl exec -n "$NS" "$hp" -c haproxy -- cat /etc/haproxy/mysql/haproxy.cfg | replica_servers)
    [ "$got" = "$want" ] || die "$hp mysql-replicas lists '${got//$'\n'/ }', want '${want//$'\n'/ }'"
    echo "OK: $hp mysql-replicas = ${want//$'\n'/ }"
  done
  ;;

redis)
  # Redis pinning RETIRED 2026-07-04: the opstree redis-operator records RedisReplication
  # .status.masterNode and repairs topology — it reverses sentinel failovers within
  # seconds, and each one disrupts immich/paperless connections.
  # Placement report only; the CRD has no preferred-master setting.
  NS="$TARGET"
  master_name="${REDIS_MASTER_NAME:-myMaster}"
  sentinel_pod="redis-sentinel-sentinel-0"
  current_ip=$(kubectl exec -n "$NS" "$sentinel_pod" -c redis-sentinel-sentinel -- \
    redis-cli -p 26379 sentinel get-master-addr-by-name "$master_name" | awk 'NR==1{print; exit}')
  [ -z "$current_ip" ] && die "sentinel returned no master for $master_name"

  current_pod=$(kubectl get pod -n "$NS" -l app=redis-replication -o json |
    jq -r --arg ip "$current_ip" 'first(.items[] | select(.status.podIP==$ip) | .metadata.name) // ""')
  [ -z "$current_pod" ] && die "sentinel master IP $current_ip maps to no redis-replication pod (stale sentinel state?)"
  current_node=$(kubectl get pod -n "$NS" "$current_pod" -o jsonpath='{.spec.nodeName}')
  echo "current master: $current_pod ($current_ip) on $current_node"
  if [ "$current_node" = "$NODE" ]; then
    echo "master already on $NODE"
    exit 0
  fi
  die "redis pin RETIRED — operator repairs topology, failovers don't stick (see SKILL.md). Placement is cosmetic: apps use the master-following Service."
  ;;

*)
  die "unknown engine: $ENGINE (use cnpg|percona|redis)"
  ;;
esac
