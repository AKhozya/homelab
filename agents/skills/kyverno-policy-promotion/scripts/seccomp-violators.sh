#!/usr/bin/env bash
# seccomp-violators.sh — authoritative LIVE-pod seccomp audit (bypasses lagging PolicyReports)
#
# Mirrors Kyverno `require-seccomp-runtimedefault`: a pod is COMPLIANT iff
#   pod-level securityContext.seccompProfile.type == RuntimeDefault
#   OR every container AND every initContainer sets it == RuntimeDefault.
# (RuntimeDefault only — a Localhost profile is policy-compliant but flagged here; rare here.)
#
# Why this exists alongside scan-violations.sh: PolicyReports lag ~1h
# (backgroundScanInterval) and false-clean right after a fix/--force-regen. This reads
# live pod specs directly — instant, no controller dependency. Use it as the cross-check
# before trusting scan-violations.sh during a seccomp soak or Audit->Enforce flip.
#
# Usage:
#   seccomp-violators.sh                      # human table, grouped by ns/owner
#   seccomp-violators.sh --json               # machine-readable array
#   seccomp-violators.sh --count              # bare integer count (for gates)
#   seccomp-violators.sh --exclude-ns a,b,c   # override default system-ns exclusions
#
# Exit: 0 = zero violators, 1 = violators present, 2 = usage/dependency error.

set -euo pipefail

EXCLUDE_NS="kube-system,kube-public,kube-node-lease,flux-system,kyverno"
MODE="table"

while [[ $# -gt 0 ]]; do
  case "$1" in
  --json)
    MODE="json"
    shift
    ;;
  --count)
    MODE="count"
    shift
    ;;
  --exclude-ns)
    EXCLUDE_NS="${2:-}"
    if [[ -z "$EXCLUDE_NS" ]]; then
      echo "error: --exclude-ns requires a value" >&2
      exit 2
    fi
    shift 2
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

for c in kubectl jq; do
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "error: required command not found: $c" >&2
    exit 2
  fi
done

# CSV -> jq array of excluded namespaces.
EX_JSON="$(printf '%s' "$EXCLUDE_NS" | jq -R 'split(",")')"

# Violating workloads, grouped by namespace + owner (controller).
VIOL="$(kubectl get pods -A -o json | jq -c --argjson ex "$EX_JSON" '
  [ .items[]
    | select(.metadata.namespace as $n | ($ex | index($n)) | not)
    | . as $p
    | (($p.spec.securityContext.seccompProfile.type // "") == "RuntimeDefault") as $pod
    | ( ([$p.spec.containers[]?     | (.securityContext.seccompProfile.type // "")] | all(. == "RuntimeDefault"))
        and
        ([$p.spec.initContainers[]? | (.securityContext.seccompProfile.type // "")] | all(. == "RuntimeDefault"))
      ) as $allc
    | select(($pod or $allc) | not)
    | { ns: $p.metadata.namespace,
        owner: ((($p.metadata.ownerReferences[0].kind) // "Pod") + "/" + (($p.metadata.ownerReferences[0].name) // $p.metadata.name)) }
  ]
  | group_by(.ns + "|" + .owner)
  | map({ ns: .[0].ns, owner: .[0].owner, pods: length })
')"

COUNT="$(printf '%s' "$VIOL" | jq 'length')"

case "$MODE" in
count)
  printf '%s\n' "$COUNT"
  ;;
json)
  printf '%s\n' "$VIOL"
  ;;
table)
  if [[ "$COUNT" -eq 0 ]]; then
    printf 'clean — 0 live seccomp violators (RuntimeDefault) outside excluded ns\n'
  else
    printf '%d violating workload(s):\n\n' "$COUNT"
    printf '%-16s %-50s %s\n' "NAMESPACE" "OWNER" "PODS"
    printf '%-16s %-50s %s\n' "---------" "-----" "----"
    printf '%s' "$VIOL" | jq -r '.[] | [.ns, .owner, (.pods | tostring)] | @tsv' |
      while IFS=$'\t' read -r ns owner pods; do
        printf '%-16s %-50s %s\n' "$ns" "$owner" "$pods"
      done
  fi
  ;;
esac

[[ "$COUNT" -eq 0 ]] && exit 0 || exit 1
