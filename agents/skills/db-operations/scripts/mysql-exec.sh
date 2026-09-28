#!/usr/bin/env bash
# Run mysql query via HAProxy (auto-routes to primary, survives failover).
# The root password never leaves the pod: the mysql container reads it from the operator's mounted
# users secret into MYSQL_PWD, so it is in no argv, here or in the pod. MySQL 8.4 deprecates
# MYSQL_PWD but still honours it.
#
# Usage:
#   mysql-exec.sh <db> "QUERY"
#   mysql-exec.sh <db> -            # SQL on stdin (keeps a password in the SQL out of argv)
#   mysql-exec.sh --shell <db>      # interactive
#
# Override:
#   MYSQL_NS=databases MYSQL_STS=main-mysql-mysql MYSQL_PROXY=main-mysql-haproxy
#   MYSQL_PW_FILE=/etc/mysql/mysql-users-secret/root

set -euo pipefail
NS="${MYSQL_NS:-databases}"
STS="${MYSQL_STS:-main-mysql-mysql}"
PROXY="${MYSQL_PROXY:-main-mysql-haproxy}"
PW_FILE="${MYSQL_PW_FILE:-/etc/mysql/mysql-users-secret/root}"

# Runs inside the pod: $1 = password file, the rest = mysql arguments.
# shellcheck disable=SC2016
IN_POD='MYSQL_PWD=$(<"$1") || exit 1; export MYSQL_PWD; shift; exec mysql "$@"'

if [ "${1:-}" = "--shell" ]; then
  DB="${2:-}"
  if [ -z "$DB" ]; then
    echo "usage: $0 --shell <db>" >&2
    exit 2
  fi
  exec kubectl exec -it -n "$NS" "sts/$STS" -c mysql -- bash -c "$IN_POD" in-pod "$PW_FILE" -h "$PROXY" -uroot "$DB"
fi

DB="${1:-}"
QUERY="${2:-}"
if [ -z "$DB" ] || [ -z "$QUERY" ]; then
  echo "usage: $0 <db> \"QUERY\"   |   $0 <db> -   |   $0 --shell <db>" >&2
  exit 2
fi

if [ "$QUERY" = "-" ]; then
  exec kubectl exec -i -n "$NS" "sts/$STS" -c mysql -- bash -c "$IN_POD" in-pod "$PW_FILE" -h "$PROXY" -uroot "$DB"
fi
exec kubectl exec -n "$NS" "sts/$STS" -c mysql -- bash -c "$IN_POD" in-pod "$PW_FILE" -h "$PROXY" -uroot -e "$QUERY" "$DB"
