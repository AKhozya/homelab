#!/usr/bin/env bash
# Grafana health: pods + datasource list.
# Admin secret is `grafana-admin-secret` (not `kube-prometheus-stack-grafana`).

set -euo pipefail

echo "=== pods ==="
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana 2>/dev/null || true

echo
echo "=== datasources (sidecar ConfigMaps labelled grafana_datasource) ==="
# Basic auth via curl returns 401 because the cluster Grafana enforces OIDC-only, and there is no
# Grafana operator. The grafana-sc-datasources sidecar loads every ConfigMap with this label, so
# they are the datasource list. Print only name, type and url, because a payload can hold
# credentials; the url loses any user:password@ part and any query or fragment for the same reason.
# No datasource at all is a failure, not an empty healthy list.
cms="$(kubectl get cm -A -l grafana_datasource -o json)" || {
  echo "(cannot list datasource ConfigMaps)"
  exit 1
}
ds="$(jq -r '.items[].data // {} | to_entries[] | "---\n" + .value' <<<"$cms" |
  yq -r '.datasources[]? | .name + "  " + .type + "  " + (.url // "" | sub("//[^@/]*@", "//") | sub("[?#].*$", ""))')" || {
  echo "(cannot parse datasource ConfigMaps)"
  exit 1
}
if [ -z "$ds" ]; then
  echo "(no datasource found in ConfigMaps labelled grafana_datasource)"
  exit 1
fi
printf '%s\n' "$ds"
