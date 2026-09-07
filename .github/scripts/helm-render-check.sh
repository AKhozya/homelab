#!/usr/bin/env bash
# Render every HelmRelease's chart at its pinned version.
#
# kubeconform validates the HelmRelease CR, never the chart's own templates, so a
# chart whose templates reject our values passes every other job and fails only
# in-cluster after Flux applies it. kube-prometheus-stack 90.0.0 did exactly that
# on 2026-09-07 (see docs/HOMELAB_HISTORY.md).
set -euo pipefail

repo_root="${1:-.}"
cd "$repo_root" || exit 1

# Charts gate templates on the API versions and Kubernetes version the target
# cluster reports. Without --api-versions, traefik's servicemonitor.yaml aborts
# with "You have to deploy monitoring.coreos.com/v1 first" against a CRD the
# cluster does have.
KUBE_VERSION="${KUBERNETES_VERSION:-1.36.3}"
API_VERSIONS=(
  --api-versions monitoring.coreos.com/v1
  --api-versions monitoring.coreos.com/v1alpha1
)

mapfile -t hr_files < <(grep -rl "kind: HelmRelease" --include="*.yaml" apps/ infrastructure/ monitoring/)

declare -A repo_url
while read -r name url; do
  [ -n "$name" ] && repo_url["$name"]="$url"
done < <(
  grep -rl "kind: HelmRepository" --include="*.yaml" apps/ infrastructure/ monitoring/ |
    while read -r f; do
      yq -N 'select(.kind == "HelmRepository") | .metadata.name + " " + .spec.url' "$f"
    done | sort -u
)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

rc=0
rendered=0
for hr in "${hr_files[@]}"; do
  yq -N 'select(.kind == "HelmRelease") | .spec.chart.spec.chart + "|" + .spec.chart.spec.version + "|" + .spec.chart.spec.sourceRef.name' \
    "$hr" > "$tmp/meta"
  while IFS='|' read -r chart ver src; do
    [ -n "$chart" ] || continue
    if [ -z "$ver" ] || [ -z "$src" ]; then
      echo "UNPINNED $hr ($chart: version or sourceRef missing)"
      rc=1
      continue
    fi
    url="${repo_url[$src]:-}"
    if [ -z "$url" ]; then
      echo "UNRESOLVED $hr (HelmRepository '$src' not found)"
      rc=1
      continue
    fi
    yq -N 'select(.kind == "HelmRelease") | .spec.values' "$hr" > "$tmp/values.yaml"
    if [ "${url#oci://}" != "$url" ]; then
      target="$url/$chart"
    else
      helm repo add "chk-$src" "$url" >/dev/null 2>&1 || true
      target="chk-$src/$chart"
    fi
    if helm template rel "$target" --version "$ver" \
      --kube-version "$KUBE_VERSION" "${API_VERSIONS[@]}" \
      -f "$tmp/values.yaml" >/dev/null 2>"$tmp/err"; then
      echo "OK   $chart@$ver"
    else
      echo "FAIL $chart@$ver -> $(grep -m1 . "$tmp/err")"
      rc=1
    fi
    rendered=$((rendered + 1))
  done < "$tmp/meta"
done

# A resolution bug that skips every chart otherwise exits 0 and reads as a pass.
if [ "$rendered" -eq 0 ]; then
  echo "ERROR: no HelmRelease rendered — the check proved nothing"
  exit 1
fi

echo "--- rendered $rendered chart(s), exit $rc"
exit $rc
