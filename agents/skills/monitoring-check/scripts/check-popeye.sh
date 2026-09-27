#!/usr/bin/env bash
# Popeye scanner: trigger manual scan + show latest results.
#
# Flags:
#   --run     trigger new scan job
#   (default) show latest results only

set -euo pipefail

if [ "${1:-}" = "--run" ]; then
  JOB="popeye-manual-$(date +%s)"
  kubectl create job --from=cronjob/popeye "$JOB" -n popeye
  echo "started job: $JOB"
  echo "wait then re-run without --run for results"
  exit 0
fi

# CronJob runs weekly; pods deleted by TTL after success. Find last by creation timestamp.
echo "=== latest scores + warnings ==="
LAST="$(kubectl get pods -n popeye --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
if [ -z "$LAST" ]; then
  LAST_RUN="$(kubectl get cronjob -n popeye popeye -o jsonpath='{.status.lastScheduleTime}' 2>/dev/null || echo unknown)"
  echo "(no pods present; last cron schedule: $LAST_RUN — pods cleaned by TTL)"
  echo "trigger fresh scan: bash $0 --run"
else
  kubectl logs -n popeye "$LAST" --tail=200 2>/dev/null |
    grep -E "(Score|WARN|ERR)" || echo "(no Score/WARN/ERR lines in $LAST)"
fi
