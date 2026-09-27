---
name: resource-sizing
description: Use when sizing CPU/memory requests/limits for homelab workloads. Tier definitions (Small/Medium/Large/Database/Init), tuning workflow, OOM diagnosis, CPU throttling check via VMSingle. Reminder Kyverno enforces limits on all containers including init.
user-invocable: false
---

# Resource Sizing Skill

## When to Use
- Deploying new app
- Fixing OOMKilled or CPU throttling
- Optimizing after app stable

## Golden Rule
**Start generous, tune down after 24-48h.** PriceBuddy had 4 limit increases, MySQL had 3. Faster to tune down than debug OOM.

## Standard Tiers

### Small (dashboards, static sites)
```yaml
resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```
**Apps**: homepage, homehub

### Medium (most apps)
```yaml
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 1000m
    memory: 1Gi
```
**Apps**: mealie, audiobookshelf, linkwarden, paperless-ngx, stirling-pdf

### Large (heavy apps)
```yaml
resources:
  requests:
    cpu: 200m
    memory: 512Mi
  limits:
    cpu: 2000m
    memory: 2Gi
```
**Apps**: authentik, immich, n8n, grafana

### Database
```yaml
resources:
  requests:
    cpu: 250m
    memory: 512Mi
  limits:
    cpu: 2000m
    memory: 2Gi
```
**Apps**: PostgreSQL, MySQL, CouchDB, Redis

### Init Container
```yaml
resources:
  requests:
    cpu: 10m
    memory: 32Mi
  limits:
    cpu: 100m
    memory: 64Mi
```
**Required for**: Kyverno compliance, all init/setup containers

## Diagnosis / tuning / namespace-quota — load `reference-tuning.md`

Not needed for a plain tier lookup; load `reference-tuning.md` when:

| Task | `reference-tuning.md` § |
|---|---|
| Find OOMKilled / measure usage / CPU-throttle rate (cpu-throttling.sh, VMSingle) | Diagnosis |
| The deploy-generous → monitor 24-48h → calc ×1.2/×1.5 → apply loop (calc.sh) | Tuning Workflow |
| Raise a limit on a live deployment (preflight-limit-change.sh) | Raising a Limit |
| Size a namespace ResourceQuota (Small/Medium/Large; quota.sh) | Namespace ResourceQuota Tiers |

## Pitfalls

| Pitfall | Problem | Fix |
|---------|---------|-----|
| limit = request | No burst, constant throttle | Limit 2-4x request |
| No init container limits | Kyverno blocks deploy | Add limits to ALL containers |
| Quota blocks rollout | "exceeded quota" rejects the pod outright. Under `strategy: Recreate` the old pod is already deleted, so this is an outage, not a failed rollout | Preflight before editing: `bash ~/.agents/skills/_shared/preflight-limit-change.sh <ns> <deploy> <new-mem>`. Raising the quota does not retry — see reference-tuning.md § Raising a Limit |
| Memory leak vs need | Grows forever vs stabilizes | Monitor over days. Leaks grow linearly. |

## Tools Allowed
- `Bash(kubectl *)`
- `Read`
- `Edit`
