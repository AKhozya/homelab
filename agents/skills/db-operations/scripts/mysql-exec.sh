#!/usr/bin/env bash
# Run mysql query via HAProxy (auto-routes to primary, survives failover).
# Resolves root password from cluster secret.
#
# Usage:
#   mysql-exec.sh <db> "QUERY"
#   mysql-exec.sh --shell <db>      # interactive
#
# Override:
#   MYSQL_NS=databases MYSQL_STS=main-mysql-mysql MYSQL_PROXY=main-mysql-haproxy MYSQL_SECRET=mysql-cluster-secrets

set -euo pipefail
NS="${MYSQL_NS:-databases}"
STS="${MYSQL_STS:-main-mysql-mysql}"
PROXY="${MYSQL_PROXY:-main-mysql-haproxy}"
SECRET="${MYSQL_SECRET:-mysql-cluster-secrets}"

if [ "${1:-}" = "--shell" ]; then
  DB="${2:-}"
  if [ -z "$DB" ]; then
    echo "usage: $0 --shell <db>" >&2
    exit 2
  fi
  PW="$(kubectl get secret -n "$NS" "$SECRET" -o jsonpath='{.data.root}' | base64 -d)"
  exec kubectl exec -it -n "$NS" "sts/$STS" -- mysql -h "$PROXY" -uroot -p"$PW" "$DB"
fi

DB="${1:-}"
QUERY="${2:-}"
if [ -z "$DB" ] || [ -z "$QUERY" ]; then
  echo "usage: $0 <db> \"QUERY\"   |   $0 --shell <db>" >&2
  exit 2
fi

PW="$(kubectl get secret -n "$NS" "$SECRET" -o jsonpath='{.data.root}' | base64 -d)"
exec kubectl exec -n "$NS" "sts/$STS" -- mysql -h "$PROXY" -uroot -p"$PW" -e "$QUERY" "$DB"
