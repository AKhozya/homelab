#!/usr/bin/env bash
# After a CNPG password rotation, show per user which client IPs AUTHENTICATED through the
# PgBouncer pooler since a time, and which IPs failed auth. An authentication from a NEW pod's IP
# is the positive proof; pg_stat_activity cannot give it, because the pooler's server connections
# opened before the rotation stay open.
#
# PgBouncer logs `login attempt` BEFORE auth, so an attempt alone proves nothing. A connection
# counts as authenticated only if it closed with `client close request` (a client ends a finished
# session that way), or if it is still open and its attempt is over 60s old: client_login_timeout
# (default 60s) closes any login still unfinished by then. Any other close reason, such as
# `client unexpected eof`, can happen before auth and counts as neither.
# Each `login attempt` opens a new record, and a close applies to the open record for that
# user@ip:port, so a reused source port cannot inherit another connection's outcome. If a new
# attempt arrives while a record for the same user@ip:port is still open, the old one counts as
# neither. Lines arrive grouped per pooler pod, and one client connection stays on one pod, so
# per-pod order suffices.
#
# Reads all lines: `kubectl logs -l` keeps only the last 10 per pod unless --tail=-1 is given.
#
# Usage: pooler-login-proof.sh <since RFC3339, e.g. 2026-10-02T11:17:00Z> <user>...
# Exit 1 if any user has no authenticated connection.
set -euo pipefail
if [ "$#" -lt 2 ]; then
  echo "usage: $0 <since-RFC3339> <user>..." >&2
  exit 2
fi
since="$1"
shift
# PgBouncer's own timestamp format; plain string comparison orders it.
cutoff="$(date -u -v-60S '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -d '60 seconds ago' '+%Y-%m-%d %H:%M:%S')"
# User names can hold digits (n8n), so the extraction class is [a-z0-9_-].
events="$(kubectl logs -n databases -l cnpg.io/poolerName=main-postgres-rw-pooler \
  --since-time="$since" --tail=-1 --all-containers |
  sed -n -E 's/.*"timestamp":"([0-9-]+ [0-9:]+)[^"]*".*C-0x[0-9a-f]+: ([a-z0-9_-]+)\/([a-z0-9_-]+)@([0-9.]+):([0-9]+) (login attempt|closing because: [^"(]*).*/\1|\3|\4:\5|\6/p')"

rc=0
for u in "$@"; do
  awk -F'|' -v u="$u" -v cutoff="$cutoff" '
    $2 != u { next }
    $4 == "login attempt" {
      if ($3 in open) { r[open[$3]] = "superseded"; isopen[open[$3]] = 0 }
      n++; t[n] = $1; split($3, a, ":"); cip[n] = a[1]; open[$3] = n; isopen[n] = 1; next
    }
    ($3 in open) { r[open[$3]] = $4; isopen[open[$3]] = 0; delete open[$3] }
    END {
      for (i = 1; i <= n; i++) {
        if (r[i] ~ /authentication failed|login_timeout/) { bad[cip[i]] = 1; continue }
        if (r[i] ~ /^closing because: client close request/ || (isopen[i] && t[i] < cutoff)) {
          okc++; ok[cip[i]] = 1
        }
      }
      for (ip in ok) okl = okl (okl ? "," : "") ip
      for (ip in bad) badl = badl (badl ? "," : "") ip
      printf "%s authenticated=%d from=[%s] auth-failed-from=[%s]\n", u, okc, okl, badl
      exit (okc > 0 ? 0 : 1)
    }' <<<"$events" || rc=1
done
exit "$rc"
