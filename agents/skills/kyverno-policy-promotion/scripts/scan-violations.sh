#!/usr/bin/env bash
# scan-violations.sh — read-only PolicyReport aggregator
#
# Usage:
#   scan-violations.sh                    # cluster-wide scan, human table
#   scan-violations.sh --policy <name>    # filter to single policy
#   scan-violations.sh --json             # machine-readable JSON
#   scan-violations.sh --force-regen      # nuke + regenerate reports first (see below)
#   scan-violations.sh --policy <name> --json
#
# Exit codes:
#   4 = --force-regen could not restart the reports controller AFTER deleting every report.
#       Reports are invalidated; the run is NOT a scan result.
#   0 = clean (no PolicyReport fails, reports present)
#   1 = violations present (listed on stdout)
#   2 = usage / dependency error
#   3 = false-clean suspected (0 fail AND 0 pass → reports absent/incomplete;
#       re-run with --force-regen), or --force-regen timed out before the
#       report set stopped growing
#
# Notes:
# - Reads PolicyReport CRs (Kyverno emits these as background scans evaluate).
# - Per-pod reports LAG policy changes (~1h backgroundScanInterval): after you
#   add an exclude / fix a workload, controller-scoped reports clear fast but
#   per-pod reports stay stale and the scan shows old fails. A soak-start
#   baseline also undercounts. Use --force-regen to get a trustworthy gate.
# - --force-regen deletes all PolicyReports (Kyverno-generated, NOT git-managed),
#   restarts the reports-controller, and polls until BOTH hold: every live pod
#   outside the system namespaces has a Pod-scoped report again, and the result
#   count is unchanged across STABLE_POLLS polls. The controller writes reports
#   one resource at a time, so the first pass>0 is a partial set that can miss
#   fails, and a pause in growth alone does not prove the set is complete.
#   If you pass --policy, a policy with no results at all still exits 3 at the freshness
#   guard below. Residual: nothing here evaluates which resources a policy should
#   match, so a policy whose results lag every other policy's by more than
#   STABLE_POLLS polls can still pass with a partial set.
# - The freshness guard (exit 3) catches "clean because reports are absent"
#   vs "clean because everything passes/is excluded".

set -euo pipefail

POLICY_FILTER=""
OUTPUT_JSON=0
FORCE_REGEN=0
REGEN_NS="kyverno"
REGEN_DEPLOY="kyverno-reports-controller"
REGEN_TIMEOUT=300 # seconds to wait for the regenerated report set to stop growing
STABLE_POLLS=3    # equal non-zero result counts in a row, 10s apart

while [[ $# -gt 0 ]]; do
  case "$1" in
  --policy)
    POLICY_FILTER="${2:-}"
    if [[ -z "$POLICY_FILTER" ]]; then
      echo "error: --policy requires a value" >&2
      exit 2
    fi
    shift 2
    ;;
  --json)
    OUTPUT_JSON=1
    shift
    ;;
  --force-regen)
    FORCE_REGEN=1
    shift
    ;;
  -h | --help)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "error: unknown arg: $1" >&2
    exit 2
    ;;
  esac
done

for cmd in kubectl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: required command not found: $cmd" >&2
    exit 2
  fi
done

# Live Running/Pending pods with no Pod-scoped report. Every policy excludes kube-system,
# kube-public, kube-node-lease and default, so pods there get no report (measured 2026-09-28: the
# only pods without one were in kube-system). An empty pod list proves nothing, so it returns -1.
uncovered_pods() {
  local reports="$1" pods
  pods="$(kubectl get pods -A -o json 2>/dev/null)" || {
    echo -1
    return
  }
  if [[ "$(jq '.items | length' <<<"$pods" 2>/dev/null)" =~ ^0?$ ]]; then
    echo -1
    return
  fi
  # Both documents on stdin: --argjson puts them in argv, which overflows ARG_MAX here.
  printf '%s\n%s\n' "$reports" "$pods" | jq -s '
		.[0] as $r | .[1] as $p
		| ([$r.items[] | select(.scope.kind == "Pod") | .scope.uid]) as $have
		| [$p.items[]
		   | select(.metadata.namespace as $n
		       | ["kube-system", "kube-public", "kube-node-lease", "default"] | index($n) | not)
		   | select(.status.phase == "Running" or .status.phase == "Pending")
		   | .metadata.uid
		   | select(. as $u | $have | index($u) | not)]
		| length'
}

# Count results for the (optionally filtered) policy in a raw report blob; $3 limits to one result.
result_count() {
  local raw="$1" filter="$2" result="${3:-}"
  printf '%s' "$raw" | jq --arg p "$filter" --arg r "$result" '
		[.items[].results[]? | select($r == "" or .result == $r)
		 | select($p == "" or .policy == $p)] | length'
}
pass_count() { result_count "$1" "$2" pass; }

if [[ "$FORCE_REGEN" -eq 1 ]]; then
  echo "[regen] deleting all PolicyReports (Kyverno-generated, not git-managed)…" >&2
  kubectl delete policyreport -A --all >/dev/null 2>&1 || true
  kubectl delete clusterpolicyreport --all >/dev/null 2>&1 || true
  echo "[regen] restarting ${REGEN_DEPLOY}..." >&2
  # NOT `rollout restart`: the bot lost workload `patch` on 2026-08-06, and this used to be
  # `|| true`, so the restart silently did nothing AFTER every report had already been deleted —
  # the run then reported "clean" having destroyed the evidence. Fail loudly instead: a regen that
  # cannot restart the controller must not go on to interpret the empty reports it caused.
  if ! "$(dirname "${BASH_SOURCE[0]}")/../../_shared/restart-workload.sh" \
    "$REGEN_NS" "app.kubernetes.io/component=reports-controller" 180; then
    echo "[regen] FATAL: could not restart ${REGEN_DEPLOY}; reports were deleted and cannot be" >&2
    echo "[regen] repopulated. Do NOT treat this run as a scan result." >&2
    exit 4
  fi
  echo "[regen] polling until the report set stops growing (timeout ${REGEN_TIMEOUT}s)…" >&2
  elapsed=0 last=-1 same=0 missing=-1
  while :; do
    probe="$(kubectl get policyreport -A -o json 2>/dev/null || echo '{"items":[]}')"
    # All results, not the --policy subset: the filtered count can stay unchanged while the
    # controller writes reports for other resources.
    n="$(result_count "$probe" "")"
    missing="$(uncovered_pods "$probe")"
    [[ "$missing" =~ ^[0-9]+$ ]] || missing=-1 # "" would compare equal to 0 in [[ -eq ]]
    if [[ "$n" -gt 0 && "$n" -eq "$last" ]]; then
      same=$((same + 1))
    else
      same=1
    fi
    last="$n"
    if [[ "$missing" -eq 0 && "$n" -gt 0 && "$same" -ge "$STABLE_POLLS" ]]; then
      echo "[regen] every pod has a report; set stable at ${n} results after ${elapsed}s" >&2
      break
    fi
    if [[ "$elapsed" -ge "$REGEN_TIMEOUT" ]]; then
      echo "[regen] TIMEOUT after ${REGEN_TIMEOUT}s: ${missing} pod(s) without a report (-1 = pod list failed), last count ${n}." >&2
      echo "[regen] Do NOT treat this run as a scan result." >&2
      exit 3
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
fi

# Pull all PolicyReports cluster-wide. Empty result = clean (or Kyverno not installed).
RAW="$(kubectl get policyreport -A -o json 2>/dev/null || echo '{"items":[]}')"

# Build flat list of fail rows: {ns, scope_kind, scope_name, policy, rule, message}
# kubectl/policyreport JSON shape: .items[].results[] where .result == "fail"
FAILS="$(printf '%s' "$RAW" | jq -c '
	[.items[]
	 | . as $rep
	 | .results[]?
	 | select(.result == "fail")
	 | {
	     namespace: ($rep.metadata.namespace // ""),
	     scope_kind: ($rep.scope.kind // "n/a"),
	     scope_name: ($rep.scope.name // "n/a"),
	     policy: (.policy // ""),
	     rule: (.rule // ""),
	     message: (.message // "")
	   }
	]
')"

if [[ -n "$POLICY_FILTER" ]]; then
  # Match either bare policy name or autogen-prefixed (Kyverno mirrors rules
  # for controller variants by prefixing with "autogen-"). Compare on the
  # underlying policy name, NOT the rule name.
  FAILS="$(printf '%s' "$FAILS" | jq --arg p "$POLICY_FILTER" '
		map(select(.policy == $p))
	')"
fi

COUNT="$(printf '%s' "$FAILS" | jq 'length')"
PASS="$(pass_count "$RAW" "$POLICY_FILTER")"

# Freshness guard runs BEFORE either output branch. It used to sit inside the human-readable path
# only, so `--json` printed `[]` and exited 0 on absent reports — the loudest possible false clean,
# and the one --force-regen can cause itself.
if [[ "$COUNT" -eq 0 && "$PASS" -eq 0 ]]; then
  if [[ -n "$POLICY_FILTER" ]]; then
    printf 'WARN: 0 fail AND 0 pass for policy %s — reports absent/incomplete (false-clean).\n' "$POLICY_FILTER" >&2
  else
    printf 'WARN: 0 fail AND 0 pass cluster-wide — reports absent/incomplete (false-clean).\n' >&2
  fi
  printf 'Re-run with --force-regen to repopulate, then re-check.\n' >&2
  exit 3
fi

if [[ "$OUTPUT_JSON" -eq 1 ]]; then
  printf '%s\n' "$FAILS"
  [[ "$COUNT" -gt 0 ]] && exit 1 || exit 0
fi

if [[ "$COUNT" -eq 0 ]]; then
  # PASS > 0 is guaranteed here — the freshness guard above already exited on 0-fail-and-0-pass.
  if [[ -n "$POLICY_FILTER" ]]; then
    printf 'clean — 0 fails for policy %s (%s pass)\n' "$POLICY_FILTER" "$PASS"
  else
    printf 'clean — 0 PolicyReport fails cluster-wide (%s pass)\n' "$PASS"
  fi
  exit 0
fi

printf '%d violation(s)' "$COUNT"
[[ -n "$POLICY_FILTER" ]] && printf ' for policy %s' "$POLICY_FILTER"
printf ':\n\n'

printf '%-22s %-18s %-40s %s\n' "NAMESPACE" "KIND" "NAME" "POLICY/RULE"
printf '%-22s %-18s %-40s %s\n' "---------" "----" "----" "-----------"

# jq -r → tab rows → printf column-format
printf '%s' "$FAILS" | jq -r '
	.[] | [
		.namespace,
		.scope_kind,
		.scope_name,
		"\(.policy)/\(.rule)"
	] | @tsv
' | while IFS=$'\t' read -r ns kind name pr; do
  printf '%-22s %-18s %-40s %s\n' "$ns" "$kind" "$name" "$pr"
done

printf '\nfix-forward checklist (per row):\n'
printf '  • in-repo workload (apps/<app>/...) → add resources / fix securityContext / etc.\n'
printf '  • operator-managed (CNPG pooler, vmagent, percona, kyverno) → add label-selector exclude\n'
printf '\nlabel discovery: kubectl -n <ns> get pod <name> --show-labels\n'

exit 1
