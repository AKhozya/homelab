#!/usr/bin/env bash
# Kyverno CP→VP migration Phase-2 parity check (soak started 2026-07-04).
# Dual-run: ClusterPolicies (Enforce, source=kyverno) + ValidatingPolicy twins
# (Audit, source=KyvernoValidatingPolicy) share policy names; PolicyReports carry both.
# ALL THREE classes must print nothing for full parity. Any output = translation drift.
# Also per pod-policy: kubectl get vpol <name> -o jsonpath='{.status.autogen}'
# must list all 6 controllers (CanAutoGen silent-kill check).
set -euo pipefail

POLR_JSON=$(kubectl get polr -A -o json)

echo "=== Class 1: verdict mismatch — same (resource, policy), different WORST result across engines"
echo "=== (worst-of-source, not raw set: CP emits per-rule results, so cpu-fail+memory-pass is one CP"
echo "===  source with mixed results — only a fail-vs-pass disagreement BETWEEN engines is drift)"
jq -r '
  def worst: if any(. == "fail") then "fail" elif any(. == "error") then "error" else .[0] end;
  [.items[] | .scope as $s | .results[]
   | {res: ($s.namespace + "/" + $s.kind + "/" + $s.name), policy, source, result}]
  | group_by(.res + "|" + .policy)
  | map(select((map(.source) | unique | length) > 1))
  | map({key: .[0].res + "|" + .[0].policy,
         cp: ([.[] | select(.source == "kyverno") | .result] | worst),
         vp: ([.[] | select(.source == "KyvernoValidatingPolicy") | .result] | worst)})
  | map(select(.cp != .vp)) | .[] | @json' <<<"$POLR_JSON"

echo "=== Class 2: missing-source — (resource, policy) reported by exactly ONE engine"
echo "=== (CP-only = VP silently dead there: autogen loss, bad matchCondition; VP-only = over-match)"
jq -r '
  [.items[] | .scope as $s | .results[]
   | {res: ($s.namespace + "/" + $s.kind + "/" + $s.name), policy, source}]
  | group_by(.res + "|" + .policy)
  | map(select((map(.source) | unique) as $u
      | ($u | length) == 1 and (["kyverno","KyvernoValidatingPolicy"] | contains($u))))
  | .[] | {key: .[0].res + "|" + .[0].policy, only: (.[0].source)} | @json' <<<"$POLR_JSON"

echo "=== Class 3: per-source result-count mismatch — one of N validations went silent"
echo "=== (rule identity can't join cross-engine, cardinality can)"
echo "=== KNOWN-BENIGN exception (offline CLI-proven 2026-07-04): the VP engine emits ONE"
echo "=== result per (policy, resource) — multi-validation VPs short-circuit reporting. So"
echo "=== require-resource-limits expects cp=2 (two CP rules), vp=1 — that exact shape is"
echo "=== filtered below. VERIFY EARLY IN SOAK the live reporter matches the CLI (if live"
echo "=== polr shows vp=2 for a passing pod, delete the exception)."
jq -r '
  [.items[] | .scope as $s | .results[]
   | {res: ($s.namespace + "/" + $s.kind + "/" + $s.name), policy, source}]
  | group_by(.res + "|" + .policy)
  | map(select((map(.source) | unique | length) > 1))
  | map({key: .[0].res + "|" + .[0].policy, policy: .[0].policy,
         cp: (map(select(.source == "kyverno")) | length),
         vp: (map(select(.source == "KyvernoValidatingPolicy")) | length)})
  | map(select(.cp != .vp))
  | map(select((.policy == "require-resource-limits" and .cp == 2 and .vp == 1) | not))
  | .[] | @json' <<<"$POLR_JSON"
