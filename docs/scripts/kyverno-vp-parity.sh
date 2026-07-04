#!/usr/bin/env bash
# Kyverno CP→VP migration Phase-2 parity check (soak started 2026-07-04).
# Dual-run: ClusterPolicies (Enforce, source=kyverno) + ValidatingPolicy twins
# (Audit, source=KyvernoValidatingPolicy) share policy names; PolicyReports carry both.
# Classes 1/2/3 must print nothing for full parity — any output there = translation drift.
# Class 2e is the exception: real violations surfaced by strengthened VP controller
# coverage (fix the workload, not the twin).
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
echo "=== Filtered as EXPECTED (2026-07-04): (a) vp-canary rows — structural, no CP twin exists;"
echo "=== (b) VP-only CONTROLLER-kind rows for the 5 CPs whose selector-based excludes suppress"
echo "===     Kyverno autogen (CP never checked controllers; VP twins with CEL matchConditions do —"
echo "===     deliberate strengthening, kept). Live-verified 2026-07-04: those 5 CPs report Pod-only"
echo "===     cluster-wide. FAILs from that strengthened coverage still print below as Class 2e."
echo "=== (c) VP-only ALL-SKIP groups — report-shape difference, not drift: CP exclude emits NO row,"
echo "===     the twin matchCondition emits a skip row (live-verified: databases/kube-system rows all"
echo "===     skip). A VP-only PASS or FAIL row still prints — that is real over-match."
jq -r '
  def suppressed: ["require-resource-limits","require-readonly-rootfs",
                   "require-drop-all-capabilities","disallow-privilege-escalation",
                   "disallow-host-namespaces"];
  [.items[] | .scope as $s | .results[]
   | select(.policy != "vp-canary")
   | {res: ($s.namespace + "/" + $s.kind + "/" + $s.name), kind: $s.kind, policy, source, result}]
  | group_by(.res + "|" + .policy)
  | map(select((map(.source) | unique) as $u
      | ($u | length) == 1 and (["kyverno","KyvernoValidatingPolicy"] | contains($u))))
  | map({key: .[0].res + "|" + .[0].policy, policy: .[0].policy, kind: .[0].kind,
         only: .[0].source, fail: any(.[]; .result == "fail"),
         skiponly: all(.[]; .result == "skip")})
  | map(. + {expected: (.only == "KyvernoValidatingPolicy"
             and ((.kind != "Pod" and (.policy as $p | suppressed | index($p) != null))
                  or .skiponly))})
  | map(select(.expected | not))
  | .[] | {key, only} | @json' <<<"$POLR_JSON"

echo "=== Class 2e: FAIL/ERROR rows surfaced by strengthened VP controller coverage (not parity drift —"
echo "=== real violations the CP was blind to; fix the workload, e.g. haproxy mysql-monit 2026-07-04)"
jq -r '
  def suppressed: ["require-resource-limits","require-readonly-rootfs",
                   "require-drop-all-capabilities","disallow-privilege-escalation",
                   "disallow-host-namespaces"];
  [.items[] | .scope as $s | .results[]
   | select(.source == "KyvernoValidatingPolicy") | select(.result == "fail" or .result == "error")
   | select((.policy as $p | suppressed | index($p) != null))
   | select($s.kind != "Pod")
   | {key: ($s.namespace + "/" + $s.kind + "/" + $s.name + "|" + .policy)}]
  | .[] | @json' <<<"$POLR_JSON"

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
