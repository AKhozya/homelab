#!/usr/bin/env bash
# Discover CNPG current primary pod.
# CNPG renumbers pods over time — never hardcode main-postgres-1.
#
# Usage:
#   pg-primary.sh                            # prints primary pod name
#   pg-primary.sh exec <db> -c "QUERY"       # one-shot psql via primary
#   pg-primary.sh exec <db> -                # SQL on stdin; stops at the first error
#   pg-primary.sh shell <db>                 # interactive psql

set -euo pipefail
CLUSTER="${PG_CLUSTER:-main-postgres}"
NS="${PG_NS:-databases}"

PRIMARY="$(kubectl get cluster -n "$NS" "$CLUSTER" -o jsonpath='{.status.currentPrimary}' 2>/dev/null)"
if [ -z "$PRIMARY" ]; then
  echo "could not resolve primary for cluster=$CLUSTER ns=$NS" >&2
  exit 3
fi

ACTION="${1:-print}"
case "$ACTION" in
print)
  echo "$PRIMARY"
  ;;
exec)
  shift
  DB="${1:-}"
  shift || true
  if [ -z "$DB" ]; then
    echo "usage: $0 exec <db> -c \"QUERY\"" >&2
    exit 2
  fi
  # "-" reads the SQL from stdin, which keeps a password in the SQL out of argv. -i only here: if
  # the -c path also used -i, kubectl would consume the caller's stdin, including a while-read
  # loop's input.
  if [ "${1:-}" = "-" ]; then
    exec kubectl exec -i -n "$NS" "$PRIMARY" -- psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -f -
  fi
  exec kubectl exec -n "$NS" "$PRIMARY" -- psql -U postgres -d "$DB" "$@"
  ;;
shell)
  DB="${2:-postgres}"
  exec kubectl exec -it -n "$NS" "$PRIMARY" -- psql -U postgres -d "$DB"
  ;;
*)
  echo "unknown action: $ACTION (print|exec|shell)" >&2
  exit 2
  ;;
esac
