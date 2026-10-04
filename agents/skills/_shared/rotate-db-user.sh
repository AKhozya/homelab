#!/usr/bin/env bash
# Rotate a DB user's password: generate pw -> write SOPS secret -> ALTER live DB
# -> print the GitOps post-steps. Mirrors the proven 2026-06-12 MySQL rotation.
#
# Gotcha (caused an outage): to make the running app use the new password, cycle its pods with
# `_shared/restart-workload.sh` (one pod delete at a time), NOT `kubectl rollout restart`.
# Rollout restart writes a `restartedAt` annotation that is NOT in Git; Flux removes it on the
# next reconcile, which can leave the old pod running with the old password. On 2026-06-12 the
# uptime-kuma pod kept using a password the database rejected, for four hours.
#
# Ordering / downtime: this updates SOPS (git, undeployed) and ALTERs the live DB
# together, so running pods (old pw) fail auth until you deploy the new secret and
# cycle pods. Brief blip — fine for the single-env homelab. For zero-downtime,
# run with --no-alter, deploy the secret, then re-run with --alter-only.
#
# Usage:
#   rotate-db-user.sh <mysql|postgres> <secret-file> <key> <db-user> [<db>]
#
# Args:
#   secret-file  path to the SOPS-encrypted k8s Secret (e.g. apps/foo/mysql-credentials.yaml)
#   key          stringData key holding the bare password (e.g. password, app-user-password)
#   db-user      DB role/user name (= app name by convention)
#   db           database to connect through (defaults: mysql=db-user, postgres=db-user)
#
# Flags:
#   --dry-run            show the new pw + every action, mutate nothing
#   --no-alter           write SOPS only, skip the live ALTER (deploy-first ordering)
#   --alter-only         run the live ALTER only, skip SOPS (reads pw from the secret)
#   --pod-selector SEL   label selector echoed in the pod-cycle step (e.g. app=uptime-kuma)
#
# Requires: sops, kubectl, openssl, and the db-operations helpers (mysql-exec.sh / pg-primary.sh).
set -euo pipefail

SHARED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBOPS="$(cd "$SHARED_DIR/../db-operations/scripts" 2>/dev/null && pwd || true)"

dry=0
no_alter=0
alter_only=0
selector=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
  --dry-run) dry=1 ;;
  --no-alter) no_alter=1 ;;
  --alter-only) alter_only=1 ;;
  --pod-selector)
    shift
    selector="${1:-}"
    [ -n "$selector" ] || {
      echo "--pod-selector needs a value (e.g. app=uptime-kuma)" >&2
      exit 2
    }
    ;;
  -*)
    echo "unknown flag: $1" >&2
    exit 2
    ;;
  *) args+=("$1") ;;
  esac
  shift
done
set -- "${args[@]}"

ENGINE="${1:-}"
SECRET="${2:-}"
KEY="${3:-}"
DB_USER="${4:-}"
DB="${5:-}"
if [ -z "$ENGINE" ] || [ -z "$SECRET" ] || [ -z "$KEY" ] || [ -z "$DB_USER" ]; then
  sed -n '2,40p' "${BASH_SOURCE[0]}"
  exit 2
fi
[ -f "$SECRET" ] || {
  echo "secret file not found: $SECRET" >&2
  exit 1
}
case "$ENGINE" in mysql | postgres) ;; *)
  echo "engine must be mysql|postgres (got: $ENGINE)" >&2
  exit 2
  ;;
esac
[ -n "$DB" ] || DB="$DB_USER"

# Mutually exclusive: both flags together would skip BOTH steps and print only the
# next-steps banner — a silent no-op.
if [ "$no_alter" = 1 ] && [ "$alter_only" = 1 ]; then
  echo "--no-alter and --alter-only are mutually exclusive" >&2
  exit 2
fi

# Preflight the engine helper BEFORE any mutation: DBOPS resolves to "" when the
# db-operations dir is missing — without this check step 1 rewrites the SOPS secret
# and the script then dies rc-127 at the ALTER, leaving a half-rotated state.
if [ "$no_alter" = 0 ]; then
  case "$ENGINE" in
  mysql) helper="$DBOPS/mysql-exec.sh" ;;
  *) helper="$DBOPS/pg-primary.sh" ;;
  esac
  [ -n "$DBOPS" ] && [ -x "$helper" ] || {
    echo "db-operations helper not found/executable: ${helper:-<unresolved>} — aborting BEFORE touching the secret" >&2
    exit 1
  }
fi

# new password — hex, so no quoting hazards in SQL literals or DSNs
if [ "$alter_only" = 1 ]; then
  PW="$(sops -d "$SECRET" | yq -r ".stringData.\"$KEY\"")"
  [ -n "$PW" ] && [ "$PW" != "null" ] || {
    echo "could not read key '$KEY' from $SECRET" >&2
    exit 1
  }
else
  PW="$(openssl rand -hex 32)"
fi

echo "engine=$ENGINE secret=$SECRET key=$KEY user=$DB_USER db=$DB"
# --alter-only reads the live password from the secret, so print a prefix only of a new one.
if [ "$dry" = 1 ]; then
  if [ "$alter_only" = 1 ]; then
    echo "[dry-run] password read from $SECRET  no changes made"
  else
    echo "[dry-run] new pw (first 8): ${PW:0:8}…  no changes made"
  fi
fi

# 1. write SOPS secret
if [ "$alter_only" = 0 ]; then
  if [ "$dry" = 1 ]; then
    echo "[dry-run] sops set --value-stdin $SECRET '[\"stringData\"][\"$KEY\"]'  (new pw on stdin)"
  else
    # --value-stdin keeps the password out of argv, where ps on this host would show it.
    printf '"%s"' "$PW" | sops set --value-stdin "$SECRET" "[\"stringData\"][\"$KEY\"]"
    echo "✅ SOPS secret updated: ${SECRET}[${KEY}]"
  fi
fi

# 2. ALTER the live DB
if [ "$no_alter" = 0 ]; then
  if [ "$ENGINE" = mysql ]; then
    SQL="ALTER USER '$DB_USER'@'%' IDENTIFIED BY '$PW';"
    CMD=("$DBOPS/mysql-exec.sh" "$DB" -)
  else
    SQL="ALTER ROLE \"$DB_USER\" WITH PASSWORD '$PW';"
    CMD=("$DBOPS/pg-primary.sh" exec "$DB" -)
  fi
  # The SQL holds the password, so it goes on stdin, never in argv.
  if [ "$dry" = 1 ]; then
    echo "[dry-run] ${CMD[*]}  <<< ${SQL//"$PW"/<pw>}"
  else
    printf '%s\n' "$SQL" | "${CMD[@]}" >/dev/null
    echo "✅ live ALTER applied on $ENGINE user '$DB_USER'"
  fi
fi

cat <<EOF

Next (GitOps — the new pw is in the secret file but NOT yet in the cluster):
  1. commit the SOPS change in your worktree, merge -> main, push
  2. flux reconcile source git flux-system && flux reconcile kustomization apps
  3. cycle the app pods onto the new secret one at a time — do NOT rollout-restart:
       ~/.agents/skills/_shared/restart-workload.sh <ns> ${selector:-<app-selector>}
     (rollout restart's restartedAt annotation is not in Git; Flux reverts it. A bare
     'kubectl delete pod -l' deletes every replica at once.)
  4. verify: new pod 1/1 Running, no auth errors, MySQLHighAbortedConnections quiet
EOF
