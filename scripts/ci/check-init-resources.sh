#!/usr/bin/env bash
# Asserts every authored initContainer carries cpu+memory requests AND limits.
# Mirrors the in-cluster Kyverno `require-cpu-limit` / `require-memory-limit` policies
# extended to initContainers (2026-05-23).
# Operator-managed Pods (CNPG pooler, vmagent, Percona) are excluded by label-selector
# at the Kyverno layer, not here.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

command -v yq >/dev/null || {
  echo "yq required" >&2
  exit 2
}

mapfile -t files < <(grep -rl 'initContainers:' \
  apps infrastructure monitoring \
  --include='*.yaml' 2>/dev/null || true)

fail=0
for f in "${files[@]}"; do
  # A yq error fails the file. Ignoring a yq error would let an unchecked file pass.
  if ! kind=$(yq eval '.kind' "$f"); then
    echo "::error file=$f::yq could not parse the file"
    fail=1
    continue
  fi
  case "$kind" in
    # Skip Helm wrappers (rendered server-side) and operator CRs (Cluster/Pooler/VMAgent).
    HelmRelease|HelmChart|HelmRepository|Cluster|Pooler|VMAgent)
      continue
      ;;
  esac
  if ! out=$(yq eval '
    [
      .spec.template.spec.initContainers[]?,
      .spec.jobTemplate.spec.template.spec.initContainers[]?
    ] |
    .[] |
    select(
      .resources.requests.cpu == null or
      .resources.requests.memory == null or
      .resources.limits.cpu == null or
      .resources.limits.memory == null
    ) | .name
  ' "$f"); then
    echo "::error file=$f::yq could not parse the file"
    fail=1
    continue
  fi
  missing=$(grep -v '^null$\|^$' <<<"$out" || true)
  if [ -n "$missing" ]; then
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      echo "::error file=$f::initContainer '$name' missing resources.{requests,limits}.{cpu,memory}"
      fail=1
    done <<< "$missing"
  fi
done

[ "$fail" -eq 0 ] && echo "init-resources: all initContainers carry resource limits"
exit "$fail"
