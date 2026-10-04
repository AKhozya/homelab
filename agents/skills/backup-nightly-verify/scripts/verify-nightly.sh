#!/usr/bin/env bash
# Verify last night's backup cycle: five CronJobs ran and succeeded, and the two whose
# failure modes are SILENT (couchdb partial dump, replication uploading what it then
# deletes) produced the right log evidence.
#
# Read-only. Never triggers a job — backup-replication posts to Telegram from inside the
# run and its Step 4 deletes the source on success, so a "just re-run it to see" is
# destructive. A manual couchdb-backup IS safe, but this script still won't do it.
#
# Exit: 0 all checks passed; 1 a check failed; 2 could not determine (treat as failure —
# an inconclusive backup check is the thing that hid two nights of broken CouchDB dumps).

set -uo pipefail

SHARED="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_shared" && pwd)"
DATE="${1:-$(date -u +%Y-%m-%d)}" # UTC: all five schedules are UTC
RC=0

red() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
grn() { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
wrn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
fail() {
  red "$*"
  RC=1
}
undet() {
  wrn "$*"
  [ "$RC" -eq 0 ] && RC=2
  return 0
}

# name:namespace:schedule — the expected set IS the spec, so it is hardcoded. A CronJob
# that silently vanished from the cluster must surface as a failure, which a "list what
# exists and check those" approach can never do.
JOBS="postgres-backup:databases:03:00
couchdb-backup:databases:03:05
pvc-backup:kube-system:03:10
mysql-backup:databases:03:15
backup-replication:backup-replication:03:30"

echo "=== Backup cycle for $DATE (UTC) ==="

# ---------------------------------------------------------------- 1. firing alerts
echo
echo "--- Firing alerts ---"
# Reuses the shared dual check (VMAlert + Alertmanager). Deliberately NOT a vmsingle
# ALERTS{} query: that metric lags ~5min behind rule state, and an exec against the
# non-existent pod name `vmsingle-vmsingle-0` (vmsingle is a Deployment) writes to stderr
# and returns empty stdout that reads as "nothing firing".
if ALERTS="$("$SHARED/check-alerts.sh" 2>/dev/null)"; then
  if grep -q '(fetch failed)' <<<"$ALERTS"; then
    undet "alert source unreachable — cannot claim the cluster is clean"
    # shellcheck disable=SC2001  # per-line prefix; ${var//} has no line anchor
    sed 's/^/        /' <<<"$ALERTS"
  # Watchdog is a dead-man switch: it fires permanently by design, so its ABSENCE means the
  # rule pipeline is broken, not that the cluster is quiet. Without this, a check-alerts.sh
  # that emitted nothing at all (its jq failures are swallowed by `|| true`) counts zero
  # non-Watchdog lines and reports "clean" — the precise false-clean this script exists to stop.
  elif ! grep -q '|Watchdog|' <<<"$ALERTS"; then
    undet "Watchdog not firing — alert pipeline is not reporting, so no alert result is trustworthy"
    # shellcheck disable=SC2001  # per-line prefix; ${var//} has no line anchor
    sed 's/^/        /' <<<"$ALERTS"
  else
    OTHER="$(grep -v '|Watchdog|' <<<"$ALERTS" | grep -c '|' || true)"
    if [ "$OTHER" -eq 0 ]; then
      grn "only Watchdog firing"
    else
      fail "$OTHER non-Watchdog alert(s) firing"
      grep -v '|Watchdog|' <<<"$ALERTS" | sed 's/^/        /'
    fi
  fi
else
  undet "check-alerts.sh did not run"
fi

# ---------------------------------------------------------------- 2. the five jobs
echo
echo "--- Nightly jobs ---"
# Select by TIMESTAMP, never by sorting job NAMES: the suffix is minutes since epoch, so a
# lexical sort picks the wrong run once digit count matters, and yesterday's jobs linger here
# until TTL expires. Ordering uses creationTimestamp because a Job that has not started yet has
# a null .status.startTime, and null sorts before every RFC3339 string.
#
# Exit 1 means the QUERY failed; empty output with exit 0 means no such run. Collapsing those
# two into "empty" is how a kubectl/API error becomes "the job simply didn't run".
latest_job() { # <cronjob> <namespace> [date] -> "name<TAB>startTime<TAB>succeeded"
  local raw
  raw="$(kubectl get jobs -n "$2" -o json 2>/dev/null)" || return 1
  [ -n "$raw" ] || return 1
  jq -r --arg cj "$1" --arg d "${3:-}" '
      [ .items[]
        | select(.metadata.ownerReferences[]? | .kind == "CronJob" and .name == $cj)
        | select($d == "" or ((.status.startTime // .metadata.creationTimestamp // "") | startswith($d)))
      ] | sort_by(.metadata.creationTimestamp) | last
      | if . == null then empty
        else "\(.metadata.name)\t\(.status.startTime // "")\t\(.status.succeeded // 0)" end' <<<"$raw" || return 1
}

REPL_JOB=""
COUCH_JOB=""
while IFS=: read -r NAME NS H M; do
  [ -n "$NAME" ] || continue
  if ! ROW="$(latest_job "$NAME" "$NS" "$DATE")"; then
    undet "$NAME ($NS): could not query Jobs — result unknown, not clean"
    continue
  fi
  if [ -z "$ROW" ]; then
    fail "$NAME ($NS): no Job dated $DATE — did not run, suspended, or already TTL-reaped"
    continue
  fi
  JN="$(cut -f1 <<<"$ROW")"
  ST="$(cut -f2 <<<"$ROW")"
  SU="$(cut -f3 <<<"$ROW")"
  case "$JN" in
  backup-replication-*) REPL_JOB="$NS/$JN" ;;
  couchdb-backup-*) COUCH_JOB="$NS/$JN" ;;
  esac

  if [ -z "$ST" ]; then
    undet "$NAME ($NS): $JN exists for $DATE but has not started"
  elif [ "$SU" != "1" ]; then
    fail "$NAME ($NS): $JN started $ST but succeeded=$SU"
  else
    grn "$NAME ($NS) $JN  sched $H:$M  started $ST"
  fi
done <<EOF
$JOBS
EOF

# immich-backup is WEEKLY (Sun 03:00). A run today is as wrong as a missing daily run.
# Queried WITHOUT a date filter — the question here is "when did it last run", not "did it run
# on $DATE".
if ! IROW="$(latest_job immich-backup backup-replication)"; then
  undet "immich-backup: could not query Jobs"
  IROW=""
elif [ -z "$IROW" ]; then
  wrn "immich-backup: no Job present (expected between weekly runs — TTL reaps it)"
fi
if [ -n "$IROW" ]; then
  IST="$(cut -f2 <<<"$IROW")"
  if [ "${IST%%T*}" = "$DATE" ] && [ "$(date -u -d "$DATE" +%u 2>/dev/null || date -j -f %Y-%m-%d "$DATE" +%u)" != "7" ]; then
    fail "immich-backup ran on $DATE, which is not a Sunday — it is a weekly job"
  else
    grn "immich-backup last ran ${IST%%T*} (weekly, Sun 03:00)"
  fi
fi

# ---------------------------------------------------------------- 3. couchdb content
echo
echo "--- CouchDB dump content ---"
# A CouchDB job can exit 0 having written an empty or partial dump. The database name and
# a plausible size are the only proof the dump has content in it.
if [ -z "$COUCH_JOB" ]; then
  undet "no couchdb-backup Job to read"
elif CLOG="$(kubectl logs -n "${COUCH_JOB%%/*}" "job/${COUCH_JOB##*/}" 2>/dev/null)" && [ -n "$CLOG" ]; then
  # Count completions against the discovered databases. `head -1` would pass on the FIRST
  # database completing while a later one died — the exact partial-success this section exists
  # to catch, invisible today only because there happens to be one database.
  WANT="$(sed -n 's/.*Found databases: *//p' <<<"$CLOG" | head -1 | wc -w | tr -d ' ')"
  GOT="$(grep -cE '✅.*completed' <<<"$CLOG" || true)"
  # A dump that produced nothing still logs a completion line. `(0` / `(0B` is the shape of an
  # empty artifact, and an empty dump is precisely the silent failure being hunted.
  ZERO="$(grep -cE '✅.*completed \(0[^0-9.]' <<<"$CLOG" || true)"
  if [ "${WANT:-0}" -eq 0 ]; then
    fail "couchdb-backup logged no 'Found databases:' line"
  elif [ "$GOT" -lt "$WANT" ]; then
    fail "couchdb-backup: $GOT of $WANT databases completed"
  elif [ "$ZERO" -gt 0 ]; then
    fail "couchdb-backup: $ZERO database(s) completed with a zero-size dump"
  else
    grep -E '✅.*completed' <<<"$CLOG" | sed 's/^\[[^]]*\] *//' |
      while read -r L; do grn "$L"; done
  fi
  # No `^` anchor: the job prefixes its own lines with `[Ns elapsed] `, so `^ERROR` can never
  # match the lines that would actually carry an error.
  # Here-string, not `printf | grep -q`: grep -q exits at the first match, printf then takes
  # SIGPIPE, and under `pipefail` this check can miss a log that contains an error. This occurs
  # only if the log is big enough that printf is still writing when grep quits.
  if grep -qiE 'error|failed' <<<"$CLOG"; then
    fail "couchdb-backup log contains an error line"
  fi
else
  undet "couchdb-backup pod logs already reaped"
fi

# ---------------------------------------------------------------- 4. replication
echo
echo "--- Replication transfer ---"
if [ -z "$REPL_JOB" ]; then
  undet "no backup-replication Job to read"
elif RLOG="$(kubectl logs -n "${REPL_JOB%%/*}" "job/${REPL_JOB##*/}" 2>/dev/null)" && [ -n "$RLOG" ]; then
  SENT="$(sed -n 's/^sent \([0-9,]*\) bytes.*/\1/p' <<<"$RLOG" | tr -d ',' | head -1)"
  if [ -z "$SENT" ]; then
    fail "no 'sent N bytes' line — the rsync step did not complete"
  elif [ "$SENT" -gt 1000000000 ]; then
    # 1GB — ~8x the 126MB a healthy night sends, and far below the 129G regression, so a partial
    # regression also fails. If replication sends more than 1GB, check for a path another job
    # owns: on 2026-07-27 it re-uploaded 129G of immich generations nightly that its own keep-2
    # pruned minutes later. Check `--exclude='/immich/'` on the Step 2 rsync first. Reported in MB:
    # integer GB division prints "1GB" for anything under 2GB, which reads as near the limit.
    fail "sent $((SENT / 1000000))MB — expected under 1000MB; is --exclude='/immich/' still on the Step 2 rsync?"
  else
    grn "sent $((SENT / 1000000))MB"
  fi

  if grep -q 'pruning dir: immich/' <<<"$RLOG"; then
    fail "pruned an immich/ dir — replication is uploading what immich-backup already owns"
  else
    grn "no immich/ dirs pruned"
  fi

  # if/else, not `grep -q X && grn … || fail …`: if grep succeeds but grn fails,
  # `A && B || C` also runs fail (SC2015).
  # The count varies nightly (one artifact per PVC archive since 54b4069a), so a type that
  # failed Step 1 cannot show as a short count; the job names it on its own line instead.
  if grep -q 'failed Step 1)' <<<"$RLOG"; then
    fail "Step 1 failed for:$(sed -n 's/.*failed Step 1)://p' <<<"$RLOG" | head -1) — held back from the NAS"
  elif grep -qE 'OK: all [0-9]+ validated artifact\(s\) present on NAS' <<<"$RLOG"; then
    grn "$(grep -oE 'all [0-9]+ validated artifact' <<<"$RLOG" | head -1)s present on NAS"
  else
    fail "Step 3 did not confirm the validated artifacts on the NAS"
  fi

  if grep -q 'Source cleaned' <<<"$RLOG"; then
    grn "source cleaned"
  else
    fail "Step 4 did not clean the source"
  fi
else
  undet "backup-replication pod logs already reaped"
fi

echo
case "$RC" in
0) printf '\033[32mPASS\033[0m — backup cycle for %s verified\n' "$DATE" ;;
1) printf '\033[31mFAIL\033[0m — see above. Do NOT manually trigger backup-replication.\n' ;;
2) printf '\033[33mUNDETERMINED\033[0m — a check could not run; treat as unverified, not as clean.\n' ;;
esac
exit "$RC"
