#!/usr/bin/env bash
# Each fixture is output captured from the live cluster, not hand-written.
# 1. Primary index from orchestrator-client topology, 2026-09-28 (primary main-mysql-mysql-1).
set -euo pipefail
PIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pin.sh"
topology='main-mysql-mysql-1.main-mysql-mysql.databases:3306 (main-mysql-mysql-1)   [0s,ok,8.4.11-11,rw,ROW,>>,GTID]
+ main-mysql-mysql-0.main-mysql-mysql.databases:3306 (main-mysql-mysql-0) [0s,ok,8.4.11-11,ro,ROW,>>,GTID]'
got="$(PIN_PARSE_ONLY=1 bash "$PIN" percona databases/main-mysql unused <<<"$topology")"
if [ "$got" = 1 ]; then
  echo "PASS: primary index 1"
else
  echo "FAIL: expected 1, got '$got'" >&2
  exit 1
fi

# 2. HAProxy mysql-replicas servers from main-mysql-haproxy-0's haproxy.cfg, 2026-11-04
# (primary 10.42.1.113, replica 10.42.2.71). Every other backend lists both pods.
cfg='    backend mysql-primary
      mode tcp
      option srvtcpka
      balance roundrobin
      option external-check
      external-check command /opt/percona/haproxy_check_primary.sh
server 10-42-1-113 10-42-1-113.main-mysql-mysql-proxy.databases.svc.cluster.local:3306  resolvers kubernetes inter 10000 rise 1 fall 2 check weight 1 on-marked-up shutdown-backup-sessions
server 10-42-2-71 10-42-2-71.main-mysql-mysql-proxy.databases.svc.cluster.local:3306  resolvers kubernetes inter 10000 rise 1 fall 2 check weight 1 backup
    backend mysql-replicas
      mode tcp
      option srvtcpka
      balance roundrobin
      option external-check
      external-check command /opt/percona/haproxy_check_replicas.sh
server 10-42-2-71 10-42-2-71.main-mysql-mysql-proxy.databases.svc.cluster.local:3306  resolvers kubernetes inter 10000 rise 1 fall 2 check weight 1
    backend mysql-x
      mode tcp
      option srvtcpka
      balance roundrobin
      option external-check
      external-check command /opt/percona/haproxy_check_primary.sh
server 10-42-1-113 10-42-1-113.main-mysql-mysql-proxy.databases.svc.cluster.local:33060  resolvers kubernetes inter 10000 rise 1 fall 2 check weight 1 on-marked-up shutdown-backup-sessions
server 10-42-2-71 10-42-2-71.main-mysql-mysql-proxy.databases.svc.cluster.local:33060  resolvers kubernetes inter 10000 rise 1 fall 2 weight 1 backup track mysql-primary/10-42-2-71
    backend mysql-admin
      mode tcp
      option srvtcpka
      balance roundrobin
      option external-check
      external-check command /opt/percona/haproxy_check_primary.sh
server 10-42-1-113 10-42-1-113.main-mysql-mysql-proxy.databases.svc.cluster.local:33062 resolvers kubernetes inter 10000 rise 1 fall 2 check weight 1 on-marked-up shutdown-backup-sessions
server 10-42-2-71 10-42-2-71.main-mysql-mysql-proxy.databases.svc.cluster.local:33062 resolvers kubernetes inter 10000 rise 1 fall 2 weight 1 backup track mysql-primary/10-42-2-71'
got="$(PIN_PARSE_ONLY=haproxy bash "$PIN" percona databases/main-mysql unused <<<"$cfg")"
if [ "$got" = 10-42-2-71 ]; then
  echo "PASS: mysql-replicas 10-42-2-71"
else
  echo "FAIL: expected 10-42-2-71, got '$got'" >&2
  exit 1
fi
