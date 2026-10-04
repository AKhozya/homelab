#!/usr/bin/env bash
# Audit a VMRule file for DEAD alerts — exprs whose metric never has series, or whose job=
# label literal matches no live target. Run BEFORE committing a vmrules change.
#
# WHY: a 2026-06-06 review found ~13 alerts silently dead — scrape selectors/metric names/job
# labels drifted from the live cluster (pg_* vs cnpg_*, app=redis vs redis-replication,
# up{job="kubelet"} vs kube-prometheus-stack-kubelet, kyverno_policy_rule_results_total vs
# kyverno_policy_results_total, gotk_reconcile_condition removed in Flux 2.8.x). A "clean scan"
# (0 firing) is exactly what a DEAD alert produces.
#
# NOT covered: a metric that EXISTS but the alert LOGIC false-fires (e.g. redis_connected_slaves<1
# firing on the replica's 0; cumulative slowlog_length>50). For that, after reconcile run
# check-alerts.sh and vmalert-state.sh (pending state and rule health).
#
# Usage:  vmrules-metric-audit.sh [path/to/vmrules.yaml]   (default: vmrules.yaml in the current
#         git checkout, so a worktree audits its own edited copy, not the main tree's)
# Exit:   0 = all metrics live + job labels match; 1 = dead metric(s)/unmatched job label(s).
# Read-only (port-forwards VMSingle, no writes). Needs: yq, jq, kubectl, curl.

set -euo pipefail

top="$(git rev-parse --show-toplevel 2>/dev/null)" || top="$HOME/source-code/homelab"
VMRULES="${1:-$top/monitoring/configs/victoria-metrics/vmrules.yaml}"
PF_PORT="${PF_PORT:-18431}"
VM="http://127.0.0.1:${PF_PORT}"

[ -f "$VMRULES" ] || {
  echo "no such file: $VMRULES" >&2
  exit 2
}
for t in yq jq kubectl curl; do command -v "$t" >/dev/null || {
  echo "needs $t" >&2
  exit 2
}; done

kubectl port-forward -n monitoring svc/vmsingle-vmsingle "${PF_PORT}:8429" >/dev/null 2>&1 &
PF=$!
trap '[ -n "${PF:-}" ] && kill "$PF" 2>/dev/null || true' EXIT
sleep 2
curl -s --max-time 6 "$VM/health" >/dev/null 2>&1 || {
  echo "VMSingle port-forward not ready" >&2
  exit 2
}

# Structural extraction — only expr: values, never annotation/description prose.
EXPRS="$(yq -r '.spec.groups[].rules[].expr' "$VMRULES" 2>/dev/null || true)"
[ -n "$EXPRS" ] || {
  echo "no exprs found (is this a VMRule with .spec.groups[].rules[].expr?)" >&2
  exit 2
}

q_count() { curl -s --max-time 8 --data-urlencode "query=count($1)" "$VM/api/v1/query" 2>/dev/null |
  jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || echo 0; }

# PromQL functions/keywords excluded from metric-name extraction.
DENY='^(rate|irate|increase|delta|idelta|sum|avg|min|max|count|count_values|stddev|stdvar|group|bottomk|topk|quantile|by|without|on|ignoring|group_left|group_right|offset|bool|and|or|unless|absent|absent_over_time|histogram_quantile|predict_linear|deriv|changes|resets|clamp|clamp_max|clamp_min|round|abs|ceil|floor|exp|ln|log2|log10|sqrt|sgn|time|timestamp|vector|scalar|label_replace|label_join|sort|sort_desc|avg_over_time|min_over_time|max_over_time|sum_over_time|count_over_time|quantile_over_time|stddev_over_time|stdvar_over_time|last_over_time|present_over_time|default|Inf|NaN|e)$'

echo "=== DEAD METRICS (referenced in an expr, 0 series live) ==="
dead=0
# Strip label matchers {..}, ranges [..], and aggregation/grouping label lists (by/without/on/
# ignoring/group_left/group_right (...)) so only metric names remain. Prometheus metric names are
# [a-zA-Z_:][a-zA-Z0-9_:]* — must allow uppercase (node_memory_MemTotal_bytes) or names get shredded.
metrics="$(printf '%s\n' "$EXPRS" |
  sed -E 's/\{[^}]*\}//g; s/\[[^]]*\]//g' |
  sed -E 's/(by|without|on|ignoring|group_left|group_right)[[:space:]]*\([^)]*\)//g' |
  grep -oE '[a-zA-Z_:][a-zA-Z0-9_:]*' | sort -u)"
while IFS= read -r m; do
  [ -z "$m" ] && continue
  echo "$m" | grep -qE "$DENY" && continue
  n="$(q_count "$m")"
  if [ "${n%%.*}" = "0" ]; then
    where="$(printf '%s\n' "$EXPRS" | awk -v pat="$m" '!found && index($0,pat){line=substr($0,1,70); found=1} END{if(found)print line}')"
    printf '  DEAD  %-46s  in: %s\n' "$m" "$where"
    dead=$((dead + 1))
  fi
done <<<"$metrics"
[ "$dead" -eq 0 ] && echo "  none — every referenced metric has series"

echo
echo "=== UNMATCHED job= LABELS (no live target; job_name= excluded) ==="
LIVE_JOBS="$(curl -s --max-time 8 "$VM/api/v1/label/job/values" | jq -r '.data[]' 2>/dev/null)"
bad=0
# Mask label keys that CONTAIN "job" (job_name, cronjob) -> placeholders first, so the plain
# `job=~?"` greps below don't match inside them. Portable (no grep -P lookbehind: GNU-only, BSD
# grep on macOS rejects -P). Then exact job="X" and regex job=~"Y" extract cleanly.
MASKED="$(printf '%s\n' "$EXPRS" | sed 's/job_name/__JN__/g; s/cronjob/__CJ__/g')"
while IFS= read -r j; do
  [ -z "$j" ] && continue
  echo "$LIVE_JOBS" | grep -qxF "$j" || {
    echo "  NO-MATCH  job=\"$j\""
    bad=$((bad + 1))
  }
done < <(printf '%s\n' "$MASKED" | grep -oE 'job="[^"]+"' | sed -E 's/job="([^"]+)"/\1/' | sort -u)
while IFS= read -r y; do
  [ -z "$y" ] && continue
  echo "$LIVE_JOBS" | grep -qE "$y" || {
    echo "  NO-MATCH  job=~\"$y\""
    bad=$((bad + 1))
  }
done < <(printf '%s\n' "$MASKED" | grep -oE 'job=~"[^"]+"' | sed -E 's/job=~"([^"]+)"/\1/' | sort -u)
[ "$bad" -eq 0 ] && echo "  none — every job= literal matches a live target"

echo
echo "=== TTL-DEAD ALERTS (metric series lifetime < staleness threshold) ==="
# Third dead-alert class (found 2026-07-03): a staleness alert
# `time() - <metric> > N` whose <metric> is a Job-scoped series can NEVER fire
# when N exceeds the Job's ttlSecondsAfterFinished — kube-state-metrics drops the
# series when the Job is TTL-reaped, so the condition is unsatisfiable before N is
# reached. NoRecentBackups was structurally dead this way (48h threshold, 24h Job
# TTL). The metric is ALIVE (passes the gate above) and the logic reads fine, so
# only a lifetime-vs-threshold check catches it. Heuristic: flag kube_job_*
# (per-Job, TTL-bound) inside a `> N` staleness compare where N > 86400 (a day) —
# the fix is almost always to rekey on the CronJob-status metric
# (kube_cronjob_status_last_successful_time), which is NOT TTL-reaped.
ttl=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  echo "  TTL-RISK  $line"
  echo "            ^ Job-scoped metric in a >1-day staleness compare — series is TTL-reaped before"
  echo "              the threshold; rekey on kube_cronjob_status_last_successful_time (persists)."
  ttl=$((ttl + 1))
done < <(printf '%s\n' "$EXPRS" |
  grep -oE 'time\(\)[[:space:]]*-[^>]*kube_job_[a-z_]+[^>]*>[[:space:]]*[0-9]+' |
  awk 'match($0,/>[[:space:]]*([0-9]+)/,m){ if (m[1]+0 > 86400) print }' 2>/dev/null ||
  printf '%s\n' "$EXPRS" | grep -E 'time\(\)[[:space:]]*-.*kube_job_.*>[[:space:]]*(8[7-9][0-9]{3}|9[0-9]{4}|[0-9]{6,})')
[ "$ttl" -eq 0 ] && echo "  none — no Job-metric staleness alert exceeds a 1-day series lifetime"

echo
if [ "$dead" -eq 0 ] && [ "$bad" -eq 0 ] && [ "$ttl" -eq 0 ]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL — $dead dead metric(s), $bad unmatched job label(s), $ttl TTL-dead alert(s)."
  echo "A 'DEAD' metric can be a false positive if genuinely absent only right now (exporter emits"
  echo "only under load, or recording rule not yet evaluated). Confirm live before deleting an alert."
  exit 1
fi
