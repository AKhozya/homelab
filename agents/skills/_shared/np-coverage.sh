#!/usr/bin/env bash
# Per-pod NetworkPolicy coverage audit — the gap np-gap.sh + Kyverno require-networkpolicy miss.
#
# np-gap.sh and Kyverno require-networkpolicy are NAMESPACE-level: a ns with >=1 NetworkPolicy
# passes, even if none of its NetworkPolicies selects a particular pod. That gap left the
# redis-operator pod with no NP in `databases` (which already had cnpg/redis-ha/couchdb NPs) from
# 2026-04-15 to 2026-05-29.
#
# This script is the per-pod complement. Two checks neither np-gap nor Kyverno do:
#   1. UNCOVERED — a Running pod that no NetworkPolicy's podSelector selects (the real gap).
#   2. ORPHAN    — a NetworkPolicy whose podSelector matches ZERO live pods, so it enforces
#                  nothing (catches typo'd selectors, e.g. the wrong redis-operator selector
#                  `app.kubernetes.io/name` vs the actual `name: redis-operator`).
#
# Scope: only namespaces that ALREADY have >=1 NetworkPolicy (the "guarded" set). Namespaces with
# zero NPs are np-gap.sh's job. If kube-system has no NetworkPolicy (none on 2026-10-04), its k3s
# pods stay out of the report too.
#
# Selector matching is delegated to kubectl's own engine (`-l`), so matchLabels + matchExpressions
# (In/NotIn/Exists/DoesNotExist) are honored exactly as the API server would.
#
# Output (one per line):
#   UNCOVERED: <ns>/<pod>  — Running pod selected by no NetworkPolicy
#   ORPHAN:    <ns>/<np>   — NetworkPolicy selects 0 pods (likely a wrong/stale selector)
# Exit 0 if clean; 1 if any UNCOVERED or ORPHAN found; 2 on misuse.
#
# Caveat: an app scaled to 0 replicas makes its NP show as ORPHAN (no pod to match) — expected
# false-positive, verify before acting. A pod "covered" here is selected by >=1 NP of ANY
# policyType; this does not assert the NP actually grants Ingress.

set -euo pipefail

# declare -A below — macOS /bin/bash is 3.2.
[ "${BASH_VERSINFO[0]}" -ge 4 ] || {
  echo "needs bash >=4 (brew bash); run via 'bash' not /bin/bash" >&2
  exit 2
}

command -v kubectl >/dev/null || {
  echo "kubectl not found" >&2
  exit 2
}
command -v jq >/dev/null || {
  echo "jq not found" >&2
  exit 2
}

# jq filter: turn a podSelector object into a kubectl -l selector string.
# shellcheck disable=SC2016  # literal jq program — must NOT expand in shell
SEL_FILTER='
  ( (.matchLabels // {}) | to_entries | map("\(.key)=\(.value)") ) as $ml
  | ( (.matchExpressions // []) | map(
        if   .operator=="In"          then "\(.key) in (\(.values|join(",")))"
        elif .operator=="NotIn"       then "\(.key) notin (\(.values|join(",")))"
        elif .operator=="Exists"      then .key
        elif .operator=="DoesNotExist" then "!\(.key)"
        else empty end) ) as $me
  | ($ml + $me) | join(",")
'

found=0

guarded_ns=$(kubectl get netpol -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' |
  sort -u)

while IFS= read -r ns; do
  [[ -z "$ns" ]] && continue

  # Build the covered-pod set for this ns by matching each NP's podSelector.
  declare -A covered=()

  while IFS= read -r np_json; do
    [[ -z "$np_json" ]] && continue
    np_name=$(jq -r '.metadata.name' <<<"$np_json")
    sel=$(jq -r ".spec.podSelector | $SEL_FILTER" <<<"$np_json")

    # Empty selector ({}) selects ALL pods in the ns.
    if [[ -z "$sel" ]]; then
      matched=$(kubectl get pods -n "$ns" -o name 2>/dev/null || true)
    else
      matched=$(kubectl get pods -n "$ns" -l "$sel" -o name 2>/dev/null || true)
    fi

    if [[ -z "$matched" ]]; then
      echo "ORPHAN:    $ns/$np_name"
      found=1
    else
      # `-o name` yields `pod/<name>`; store the bare name as the set key.
      while IFS= read -r p; do
        [[ -n "$p" ]] && covered["${p#pod/}"]=1
      done <<<"$matched"
    fi
  done < <(kubectl get netpol -n "$ns" -o json | jq -c '.items[]')

  # Skip hostNetwork pods — they bypass NetworkPolicy entirely (CNI), so they CANNOT be
  # covered (e.g. prometheus-node-exporter).
  # The UNCOVERED check includes only Running pods. Completed provisioning Jobs (audiobookshelf-init,
  # immich-admin-setup, *-user-provision, *-setup) never show here. The shared allow-dns-egress
  # policy EXCLUDES Job pods (batch.kubernetes.io/job-name DoesNotExist), so each Job needs its
  # own egress NP. Check Job pod egress in the manifests, not here.
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    if [[ -z "${covered["$pod"]:-}" ]]; then
      echo "UNCOVERED: $ns/$pod"
      found=1
    fi
  done < <(kubectl get pods -n "$ns" -o json 2>/dev/null |
    jq -r '.items[] | select(.status.phase=="Running") | select(.spec.hostNetwork != true) | .metadata.name' || true)

  unset covered
done <<<"$guarded_ns"

exit "$found"
