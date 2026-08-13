#!/bin/sh
# Raises every installed extension in the immich database to the version the running
# PostgreSQL image provides.
#
# Both postgres-update-extensions (daily) and immich-init-extensions (on every CNPG image
# bump) mount this one file. If each workload keeps its own copy of the loop, a fix for a
# false success reaches only one of them.
#
# Immich updates pgvector itself at startup as DB user `immich`, which does not own the
# extension. PostgreSQL 18 has no `ALTER EXTENSION ... OWNER TO`, so immich can never hold
# that ownership and its worker exits 1 on the permission error. Only a postgres-admin
# connection can raise the installed version.
set -e

echo "Updating PostgreSQL extensions in immich database..."

PSQL="psql -v ON_ERROR_STOP=1 -h main-postgres-rw -U postgres-admin -d immich"

# One psql call per extension, deliberately not a single DO block: a DO block is one
# transaction, so a final RAISE that fails the job also rolls back every successful ALTER.
# ON_ERROR_STOP makes psql exit non-zero instead of reporting the error and continuing.
# If psql fails inside `for ... in $(psql)`, the loop receives an empty word list, does
# nothing and exits 0. Assign first, so set -e aborts on the failure instead.
# shellcheck disable=SC2086  # $PSQL holds a command with arguments and must word-split.
EXTS=$($PSQL -tAc "SELECT extname FROM pg_extension WHERE extname <> 'plpgsql' ORDER BY extname")
if [ -z "$EXTS" ]; then
  echo "❌ No extensions found in immich — refusing to report success."
  exit 1
fi

# Read one row per line rather than `for EXT in $EXTS`, which splits on any whitespace inside
# a quoted extension name. Use a here-doc, because a pipe runs the loop in a subshell and
# discards its RC assignment.
RC=0
while IFS= read -r EXT; do
  [ -n "$EXT" ] || continue
  # psql reports an extension already at its latest version as a NOTICE and exits 0, so a
  # non-zero exit here marks a real failure.
  if $PSQL -c "ALTER EXTENSION \"$EXT\" UPDATE"; then
    echo "OK $EXT"
  else
    echo "FAILED $EXT"
    RC=1
  fi
done <<EOF
$EXTS
EOF

echo "--- extension versions after update ---"
$PSQL -c "SELECT extname, extversion FROM pg_extension WHERE extname <> 'plpgsql' ORDER BY extname"

if [ "$RC" -ne 0 ]; then
  echo "❌ One or more extension updates failed."
  exit 1
fi

echo "✅ Finished updating extensions in immich database!"
