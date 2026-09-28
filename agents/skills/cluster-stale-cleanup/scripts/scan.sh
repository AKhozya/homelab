#!/usr/bin/env bash
# Cluster stale resource scan. Read-only. Surfaces categories for GitOps cleanup.
set -euo pipefail

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
row() { printf '%-30s %s\n' "$1" "$2"; }

bold "=== STALE RESOURCE SCAN ==="

failed=$(kubectl get pods -A --field-selector=status.phase=Failed -o json |
  jq '.items | length')
row "Failed/evicted pods" "$failed"

# Counted separately because `--field-selector=status.phase=Failed` above misses most of
# them: a container that handles SIGTERM exits 0, so a node reboot leaves mostly Succeeded
# pods (10 of 11 on 2026-08-08). Nothing reaps either kind — the ReplicaSet controller
# ignores terminal pods it owns, and the pod-GC controller acts only past
# --terminated-pod-gc-threshold, default 12500. They keep DeploymentReplicasMismatch and
# PodPhaseNotRunning firing. Job-owned pods are excluded: that history belongs to the
# CronJob and ttlSecondsAfterFinished clears it.
leftover=$(kubectl get pods -A -o json |
  jq '[.items[]
         | select(.status.phase == "Failed" or .status.phase == "Succeeded")
         | select(any(.metadata.ownerReferences[]?;
             .controller == true
             and (.kind == "ReplicaSet" or .kind == "StatefulSet" or .kind == "DaemonSet")))]
       | length')
row "Controller-owned terminal pods" "$leftover"

no_ttl=$(kubectl get jobs -A -o json |
  jq '[.items[]
         | select(.status.completionTime != null)
         | select(.spec.ttlSecondsAfterFinished == null)
         | select(.metadata.ownerReferences == null
                  or (.metadata.ownerReferences[0].kind != "CronJob"))]
       | length')
row "Jobs without TTL" "$no_ttl"

unbound=$(kubectl get pvc -A -o json |
  jq '[.items[] | select(.status.phase != "Bound")] | length')
row "Unbound PVCs" "$unbound"

released=$(kubectl get pv -o json |
  jq '[.items[] | select(.status.phase == "Released" or .status.phase == "Failed")] | length')
row "Released/Failed PVs" "$released"

# Sentinel '?' on helm missing/failing — never a false-clean 0.
stuck=$(helm list -A --failed --pending -o json 2>/dev/null |
  jq 'length' 2>/dev/null || echo '?')
row "Stuck Helm releases" "$stuck"

echo
bold "--- Deployments with zero-replica RS > 5 ---"
rs_out=$(kubectl get rs -A -o json 2>/dev/null |
  jq -r '
    [.items[] | select(.spec.replicas == 0)
              | "\(.metadata.namespace)/\(.metadata.ownerReferences[0].name // "orphan")"]
    | group_by(.) | map({owner: .[0], count: length})
    | sort_by(-.count) | .[] | select(.count > 5)
    | "  \(.owner)  count=\(.count)"' || echo "  (rs query failed)")
if [ -n "$rs_out" ]; then
  printf '%s\n' "$rs_out"
else
  echo "  none"
fi

echo
bold "--- Top 5 orphan ConfigMaps (oldest, no controller, unreferenced) ---"
# A "real orphan" = CM that no controller manages AND no workload uses.
# Skip categories that LOOK orphan but aren't:
#   - ownerReferences set    → controller will delete it when parent goes
#   - cluster-infra ns       → kube-system / flux-system / cert-manager / etc.
#   - platform CA bundles    → kube-root-ca / istio-ca / similar
#   - Helm-managed           → release lifecycle handles it
#   - Flux Kustomize-managed → label `kustomize.toolkit.fluxcd.io/name` set;
#                              Flux prunes when removed from git
#   - Grafana sidecar-discovered → label `grafana_dashboard` or `grafana_datasource`
#   - Referenced by any spec → recursive walk over pod/deploy/sts/ds/job/cronjob
#     pulling .configMap/.configMapRef/.configMapKeyRef names from volumes + env
#
# REFS set built once (single kubectl get); each CM does set-membership via `inside`.
REFS_JSON="$(kubectl get pods,deployments,statefulsets,daemonsets,jobs,cronjobs -A -o json |
  jq '[.. | objects | (.configMap?.name // .configMapRef?.name // .configMapKeyRef?.name // empty)] | unique')"

kubectl get cm -A -o json |
  jq -r --argjson refs "$REFS_JSON" '.items[]
           | select(.metadata.ownerReferences == null)
           | select(.metadata.namespace | test("^(kube-system|flux-system|cert-manager|kube-public|kube-node-lease)$") | not)
           | select(.metadata.name | test("^(kube-root-ca|istio-ca)") | not)
           | select((.metadata.labels["app.kubernetes.io/managed-by"] // "") != "Helm")
           | select((.metadata.annotations["meta.helm.sh/release-name"] // "") == "")
           | select((.metadata.labels["kustomize.toolkit.fluxcd.io/name"] // "") == "")
           | select((.metadata.labels["grafana_dashboard"] // "") == "")
           | select((.metadata.labels["grafana_datasource"] // "") == "")
           | select(([.metadata.name] | inside($refs)) | not)
           | "  \(.metadata.namespace)/\(.metadata.name) created=\(.metadata.creationTimestamp)"' |
  sort -k2 | awk 'NR<=5'

echo
bold "=== JOBS WITHOUT TTL (detail) ==="
kubectl get jobs -A -o json |
  jq -r '.items[]
           | select(.status.completionTime != null)
           | select(.spec.ttlSecondsAfterFinished == null)
           | select(.metadata.ownerReferences == null
                    or (.metadata.ownerReferences[0].kind != "CronJob"))
           | "  \(.metadata.namespace)/\(.metadata.name)  completed=\(.status.completionTime)"'

echo
bold "=== STUCK HELM RELEASES (detail) ==="
# Distinguish "helm broke" from "genuinely none stuck".
if helm_json=$(helm list -A --failed --pending -o json 2>/dev/null); then
  helm_out=$(printf '%s' "$helm_json" |
    jq -r '.[] | "  \(.namespace)/\(.name) status=\(.status) updated=\(.updated)"')
  if [ -n "$helm_out" ]; then
    printf '%s\n' "$helm_out"
  else
    echo "  none"
  fi
else
  echo "  (helm query failed)"
fi

echo
bold "=== CLEANUP PROPOSAL ==="
cat <<'PROPOSAL'
  Jobs without TTL      → patch ttlSecondsAfterFinished: 86400 → /gitops-workflow
  RS > 5 per Deploy     → patch spec.revisionHistoryLimit: 2 in Deployment manifest
  Stuck Helm            → read helm history + flux get hr, fix values/chart version in Git
                          → /gitops-workflow; the HelmRelease remediation handles rollback
                          (never a manual helm rollback: out-of-band prod change)
  Released/Failed PVs   → kubectl delete pv <name> (out-of-band OK, post-PVC-del)
  Failed pods           → root-cause via /k8s-diagnostics (NOT a cleanup target)
  Terminal ctrl-owned   → kubectl -n <ns> delete pod \
                            --field-selector="metadata.name=<name>,status.phase=<phase>"
                          (phase in the selector, NOT a bare name: StatefulSet names are
                           stable, so if a pod is recreated in between, a delete by name
                           takes the live one. phase2 sweeps these after a reboot; if the
                           count is non-zero otherwise, that sweep did not run)
  Orphan ConfigMaps     → manual audit; check if referenced by removed Deployments
PROPOSAL
