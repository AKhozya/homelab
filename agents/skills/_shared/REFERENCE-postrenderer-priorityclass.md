# Reference: HelmRelease `priorityClassName` injection — values vs postRenderers

Codifies F-30 (2026-05-28→29) learnings. Reference doc, not auto-fired.

## When chart-native values key works

Chart exposes `priorityClassName` (top-level or per-component) and renders into Deployment/STS/DS spec.
- ✅ **cnpg / cloudnative-pg 0.28.2** — `values.priorityClassName` top-level. Used in F-30 Commit E.
- ✅ **bjw-s common-library** — `defaultPodOptions.priorityClassName` or per-controller `controllers.<name>.defaultPodOptions.priorityClassName`.
- ✅ **prometheus-operator Alertmanager CR** — `alertmanagerSpec.priorityClassName` (chart key under `values.alertmanager.alertmanagerSpec`); Prom-Op propagates to the generated STS. Used for KPS alertmanager F-30 Commit G.

## When postRenderers JSON6902 is required (chart has no hook)

Verified upstream at the versions named — these omitted any `priorityClassName` value then. Since `88fe2598` (2026-09-28), chart values set it for cert-manager, victoria-metrics-operator and alloy. Check a chart's values before you add a postRenderer.
- ❌ **ps-operator 1.1.0** (Percona Server for MySQL operator) — Commit I.
- ❌ **cert-manager 1.20.2** — Commit G (3 deployments).
- ❌ **kyverno 3.8.1** — Commit G (4 deployments).
- ❌ **kube-prometheus-stack 86.0.1** — chart-managed Deployments + DaemonSet (operator/grafana/KSM/node-exporter) — Commit G. (Alertmanager STS uses native values path above.)
- ❌ **victoria-metrics-operator 0.63.1** — Commit G.
- ❌ **loki (grafana) 7.0.0** — STS + Deploy + DS — Commit G.
- ❌ **alloy (grafana) 1.8.2** — DaemonSet — Commit G.

## Chart-support detection workflow

Before editing HR, probe upstream — 30 seconds saves a no-op push:

```bash
CHART_URL_BASE="https://raw.githubusercontent.com/<org>/<chart-repo>/main/charts/<chart>"
# 1. values.yaml has priorityClassName key?
curl -sf "$CHART_URL_BASE/values.yaml" | grep -i priorityclass
# 2. deployment template consumes .Values.priorityClassName?
curl -sf "$CHART_URL_BASE/templates/deployment.yaml" | grep -i priorityclass
```
Both empty → use postRenderers. Either non-empty → use `values.priorityClassName` (or sub-path).

If context-mode blocks `curl` with a redirect, use `mcp__plugin_exa_exa__web_fetch_exa` on the GitHub blob URL.

## Canonical postRenderers patch shape

Sits at `spec.postRenderers` (sibling of `values:`, NOT inside it):

```yaml
spec:
  # ...
  postRenderers:
    - kustomize:
        patches:
          - target:
              kind: Deployment              # or StatefulSet / DaemonSet
              name: <chart-rendered-name>   # match live pod prefix
            patch: |-
              - op: add
                path: /spec/template/spec/priorityClassName
                value: homelab-standard     # or homelab-critical / homelab-batch
  values:
    # ...
```

Multiple targets — one entry per `target.name` (NOT a single multi-target list).

## Validation chain

```bash
# 1. yamllint on the HR file (stdin form if path errors)
yamllint -d 'relaxed' < <file>
# 2. server dry-run (HelmRelease CR validates; Kyverno doesn't see render until Flux applies)
kubectl apply --dry-run=server -f <file>
# 3. Flux reconcile then audit
flux reconcile source git flux-system && flux reconcile kustomization <ks> --with-source
bash ~/.agents/skills/_shared/audit-priority-class.sh --missing    # MUST be empty for target workload
```

## Pre-existing patterns in repo

- `apps/immich/release.yaml:31` — full postRenderers example (serviceAccount + securityContext + GPU + priorityClassName).
- `infrastructure/controllers/databases/mysql/helmrelease.yaml:13` — minimal postRenderers (just priorityClassName).
- `clusters/flux-system/kustomization.yaml` (a patch, not an inline line in gotk-components) — system-cluster-critical parity for Flux notification-controller (upstream gotk omits it from notification-controller only; other 3 have it). Path flattened from `clusters/staging/` 2026-06-12.

## Cross-refs

- `~/.agents/skills/_shared/audit-priority-class.sh` — gap detector. Always run `--missing` post-deploy.
- `~/.agents/skills/gitops-verify/SKILL.md` — invokes audit as optional post-deploy check.
- `~/.agents/skills/cnpg-full-roll/SKILL.md` — for CNPG v1.29.x cases where spec change isn't auto-rolled.
