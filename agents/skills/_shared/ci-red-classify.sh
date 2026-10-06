#!/usr/bin/env bash
# Classify the latest validate.yaml CI run as GREEN / CONTENT-RED / INFRA-RED.
#
# Why: only content-red (any failure outside the INFRA-RED criteria below) means the change is
# broken. If the Actions runner cannot execute (billing or minutes exhausted, runner outage),
# jobs can fail within seconds with no logs, on other authors' commits too. That is infra-red:
# the required PR checks cannot pass, so nothing merges until the runner works again.
#
# Signal (robust, no timestamp math):
#   GREEN       target run conclusion == success
#   INFRA-RED   target failed, and one of:
#                 - every job failed with 0 steps executed (fail-to-start)
#                 - every job that ran a step succeeded (ci-ok aside), and some job ran 0
#                   steps and did not succeed. ci-ok then fails only because of those jobs
#                 - every job failed AND all of the last N runs failed (other SHAs too)
#   CONTENT-RED any other failure (a job failed on its own steps, or predecessors were green)
#
# Usage:
#   ci-red-classify.sh [branch] [sha] [depth]    # defaults: main, latest run, 6
#
# Exit: 0 GREEN | 5 PENDING (run not finished) | 10 CONTENT-RED (block, fix manifest)
#       11 INFRA-RED (nothing merges; on main, re-run) | 12 CANCELLED (sha never validated —
#       re-run; NOT infra-red) | 2 misuse | 3 gh/jq missing

set -euo pipefail

WORKFLOW=validate.yaml
branch="${1:-main}"
want_sha="${2:-}"
depth="${3:-6}"

command -v gh >/dev/null || {
  echo "need gh CLI" >&2
  exit 3
}
command -v jq >/dev/null || {
  echo "need jq" >&2
  exit 3
}
[[ "$depth" =~ ^[0-9]+$ ]] || {
  echo "depth must be int" >&2
  exit 2
}

runs="$(gh run list --workflow="$WORKFLOW" --branch "$branch" --limit "$depth" \
  --json databaseId,headSha,conclusion,status 2>/dev/null)"
[[ "$(jq 'length' <<<"$runs")" -gt 0 ]] || {
  echo "no $WORKFLOW runs on $branch" >&2
  exit 3
}

# Target run: matching sha if given, else most recent.
if [[ -n "$want_sha" ]]; then
  target="$(jq --arg s "$want_sha" 'map(select(.headSha|startswith($s)))[0] // empty' <<<"$runs")"
  [[ -n "$target" ]] || {
    echo "no run for sha $want_sha on $branch" >&2
    exit 3
  }
else
  target="$(jq '.[0]' <<<"$runs")"
fi

id="$(jq -r '.databaseId' <<<"$target")"
sha="$(jq -r '.headSha[0:8]' <<<"$target")"
status="$(jq -r '.status' <<<"$target")"
conclusion="$(jq -r '.conclusion' <<<"$target")"

verdict() { printf '%s  run=%s sha=%s\n' "$1" "$id" "$sha"; }

if [[ "$status" != "completed" ]]; then
  verdict "PENDING ($status) — wait, re-run when finished"
  exit 5
fi
if [[ "$conclusion" == "success" ]]; then
  verdict "GREEN ✅ — proceed to fr"
  exit 0
fi
# Cancelled (concurrency/rapid pushes): its jobs are also 0-step, which would otherwise
# satisfy the fail-to-start predicate below and falsely unblock a sha CI never validated.
if [[ "$conclusion" == "cancelled" ]]; then
  verdict "CANCELLED 🚫 — this sha was never validated (concurrency cancellation). Re-run CI or push again; not infra-red"
  exit 12
fi

jobs="$(gh run view "$id" --json jobs --jq '.jobs' 2>/dev/null || echo '[]')"
total="$(jq 'length' <<<"$jobs")"
failed="$(jq '[.[]|select(.conclusion=="failure")]|length' <<<"$jobs")"
# Fail-to-start: run is red yet NO job executed a single step (billing block / runner
# outage). Conclusion-agnostic on purpose: GitHub leaves some fail-to-start jobs with a
# null/empty conclusion (seen 2026-07-23: 12 failure + 1 null, all 0 steps — the old
# conclusion=="failure" filter undercounted and misclassified as content-red).
# Caveat: a workflow-file content error that breaks job dispatch (e.g. bad runs-on) presents
# the same way — if YOUR diff touched .github/workflows, treat this verdict as content-red.
zerostep="$(jq '[.[]|select(((.steps // [])|length)==0)]|length' <<<"$jobs")"
# ci-ok (validate.yaml) aggregates the other jobs' results, so its failure alone says nothing.
# If you rename ci-ok in validate.yaml, update this filter.
# A job that hits timeout-minutes ends cancelled after running steps, so count every
# conclusion but success, not only failure.
own_fail="$(jq '[.[]|select(((.steps // [])|length)>0 and .conclusion!="success" and .name!="ci-ok")]|length' <<<"$jobs")"
never_ran="$(jq '[.[]|select(((.steps // [])|length)==0 and .conclusion!="success")]|length' <<<"$jobs")"
red_runs="$(jq '[.[]|select(.conclusion=="failure")]|length' <<<"$runs")"

if [[ "$conclusion" == "failure" && "$total" -gt 0 && "$zerostep" -eq "$total" ]]; then
  verdict "INFRA-RED ⚙️ — all $total jobs failed with 0 steps executed (fail-to-start: billing/runner — but content-red if your diff touched .github/workflows). Nothing merges until the runner works; on main: gh run rerun $id"
  exit 11
fi

# GitHub cancels a job that waits in the queue too long, before any step (2026-10-05 Actions
# incident: 6 of 16 jobs). A cancelled run exits above as CANCELLED. This run concluded
# failure only because ci-ok saw those jobs fail to succeed.
if [[ "$conclusion" == "failure" && "$own_fail" -eq 0 && "$never_ran" -gt 0 ]]; then
  verdict "INFRA-RED ⚙️ — $never_ran job(s) never started (0 steps) and every job that ran a step succeeded, ci-ok aside (GitHub queue/runner — but content-red if your diff touched .github/workflows). Re-run them: gh run rerun $id --failed"
  exit 11
fi

if [[ "$total" -gt 0 && "$failed" -eq "$total" && "$red_runs" -eq "$(jq 'length' <<<"$runs")" ]]; then
  verdict "INFRA-RED ⚙️ — runner/billing, NOT your content (all $total jobs failed; last $red_runs runs incl. other SHAs all red). Nothing merges until the runner works; on main: gh run rerun $id"
  exit 11
fi

verdict "CONTENT-RED ❌ — real failure ($failed/$total jobs). BLOCK fr; gh run view $id --log-failed"
exit 10
