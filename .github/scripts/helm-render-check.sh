#!/usr/bin/env bash
# kubeconform validates the HelmRelease custom resource, never the chart's own
# templates, so a chart whose templates reject our values passes every other job and
# fails only in-cluster after Flux applies it. kube-prometheus-stack 90.0.0 did exactly
# that on 2026-09-07 (see docs/HOMELAB_HISTORY.md).
#
# Every path that renders nothing must fail. A check that silently skips a chart and
# exits 0 is worse than no check, because it reads as proof the chart is fine.
set -euo pipefail

repo_root="${1:-.}"
cd "$repo_root" || exit 1

# Charts gate templates on the API versions and Kubernetes version the target cluster
# reports. If --api-versions omits monitoring.coreos.com/v1, traefik's servicemonitor.yaml
# aborts with "You have to deploy monitoring.coreos.com/v1 first" against a CRD the
# cluster does have.
KUBE_VERSION="${KUBERNETES_VERSION:-1.36.3}"
API_VERSIONS=(
  --api-versions monitoring.coreos.com/v1
  --api-versions monitoring.coreos.com/v1alpha1
)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Keep the repo list out of the caller's helm config: a run must not depend on, or
# mutate, whatever repos the operator happens to have registered locally.
export HELM_REPOSITORY_CONFIG="$tmp/repositories.yaml"
export HELM_REPOSITORY_CACHE="$tmp/cache"

# grep on the bare kind name, not "kind: HelmRelease", so a quoted or oddly spaced
# manifest still reaches yq. yq decides what is actually a HelmRelease.
candidates="$tmp/candidates"
grep -rl --include="*.yaml" --include="*.yml" -E "HelmRe(lease|pository)" \
  apps/ infrastructure/ monitoring/ > "$candidates" || {
  echo "ERROR: manifest discovery found nothing — the check proved nothing"
  exit 1
}

declare -A repo_url
while IFS='|' read -r name url; do
  [ -n "$name" ] || continue
  if [ -n "${repo_url[$name]:-}" ] && [ "${repo_url[$name]}" != "$url" ]; then
    # Two HelmRepositories share a name. Rendering would pick one arbitrarily and
    # report success against the wrong chart source.
    echo "COLLISION HelmRepository '$name' maps to both ${repo_url[$name]} and $url"
    exit 1
  fi
  repo_url["$name"]="$url"
done < <(
  while read -r f; do
    yq -N 'select(.kind == "HelmRepository") | .metadata.name + "|" + .spec.url' "$f"
  done < "$candidates" | sort -u
)

rc=0
rendered=0
while read -r hr; do
  # Pair each release with its own values by document index. A file holding two
  # HelmReleases would otherwise render both against the concatenation of both values.
  while read -r idx; do
    [ -n "$idx" ] || continue
    meta=$(yq -N "select(document_index == $idx) | .spec.chart.spec.chart + \"|\" + .spec.chart.spec.version + \"|\" + .spec.chart.spec.sourceRef.name" "$hr")
    IFS='|' read -r chart ver src <<< "$meta"
    if [ -z "$chart" ] || [ -z "$ver" ] || [ -z "$src" ]; then
      echo "INCOMPLETE $hr doc $idx (chart/version/sourceRef missing)"
      rc=1
      continue
    fi
    url="${repo_url[$src]:-}"
    if [ -z "$url" ]; then
      echo "UNRESOLVED $hr doc $idx (HelmRepository '$src' not found)"
      rc=1
      continue
    fi
    yq -N "select(document_index == $idx) | .spec.values" "$hr" > "$tmp/values.yaml"
    if [ "${url#oci://}" != "$url" ]; then
      target="$url/$chart"
    elif helm repo add --force-update "chk-$src" "$url" >/dev/null 2>"$tmp/err"; then
      target="chk-$src/$chart"
    else
      echo "REPOADD $chart@$ver -> $(grep -m1 . "$tmp/err")"
      rc=1
      continue
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
  done < <(yq -N 'select(.kind == "HelmRelease") | document_index' "$hr")
done < "$candidates"

if [ "$rendered" -eq 0 ]; then
  echo "ERROR: no HelmRelease rendered — the check proved nothing"
  exit 1
fi

echo "--- rendered $rendered chart(s), exit $rc"
exit $rc
