#!/usr/bin/env bash
# Grafana health: pods + datasource list.
# Admin secret is `grafana-admin-secret` (not `kube-prometheus-stack-grafana`).

set -euo pipefail

echo "=== pods ==="
kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana 2>/dev/null || true

echo
echo "=== datasources (via Grafana CRD — basic auth blocked by OIDC enforcement) ==="
# Basic auth via curl returns 401 because the cluster Grafana enforces OIDC-only.
# Read datasource state from the Grafana operator CRDs instead.
kubectl get grafanadatasources.grafana.integreatly.org -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.datasource.type,URL:.spec.datasource.url 2>/dev/null || echo "(grafanadatasources CRD not found — fall back to Grafana UI)"
