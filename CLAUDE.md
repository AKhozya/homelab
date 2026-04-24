# Homelab — Claude Project Instructions

Personal K3s homelab on 3 nodes (1 CP + 2 workers) managed via Flux GitOps.

## Critical Reference
- **State tracker**: [`docs/HOMELAB_ANALYSIS.md`](docs/HOMELAB_ANALYSIS.md) — update after any meaningful infra/app change.
- **Disaster recovery**: [`.backup/README.md`](.backup/README.md)
- **Secrets rotation schedule**: [`docs/SECRETS_ROTATION.md`](docs/SECRETS_ROTATION.md)

## Workflow Rules
- **GitOps only** — never `kubectl apply -f` without `--dry-run=server`. Commit to Git; Flux reconciles every 60s.
- **Validate before commit**: `kubectl apply -f <file> --dry-run=server`.
- **Never force-delete DB pods** — use `kubectl rollout restart` or delete via CNPG/Percona CRDs.
- **Never direct SQL drops** — use K8s CRDs.
- **DB username = app name** (convention).

## Flux Reconciliation
Default: `fr` alias (defined in `~/.zshrc`) — full-stack reconcile in dep order.

Granular:
```bash
flux reconcile source git flux-system --timeout=60s
flux reconcile kustomization <name> --timeout=60s
flux reconcile helmrelease <name> -n <ns> --timeout=60s
```

Kustomizations (dep order): `flux-system` → `infrastructure-controllers` → `infrastructure-configs` → `monitoring-controllers` → `monitoring-configs` → `apps`.

## Teardown Pattern
```bash
flux suspend kustomization <name>
kubectl delete -f <file.yaml>
git rm <files> && git commit -m "Remove: <resource>" && git push
flux resume kustomization <name>
flux reconcile kustomization <name> --timeout=60s
```

## Quick-Access Skills
| Command | Purpose |
|---------|---------|
| `/k8s-diagnostics` | Diagnose cluster (nodes, pods, events, DBs) |
| `/gitops-workflow` | Safe GitOps deploy flow |
| `/gitops-verify` | 7-point cluster state check |
| `/db-operations` | DB queries, backups, replication |
| `/monitoring-check` | Alerts, Prometheus, Popeye, Kyverno |
| `/networkpolicy-helper` | Generate NetworkPolicy (ports, dual-access, egress) |
| `/ha-enablement` | HA checklist (replicas, anti-affinity, gossip) |
| `/resource-sizing` | CPU/mem limits by tier |
| `/checkpoint` | Capture/compare infra snapshots |

## DB Connection Patterns
- **Postgres (via PgBouncer)**: `main-postgres-rw-pooler.databases.svc.cluster.local:5432`
- **MySQL (via HAProxy)**: `main-mysql-haproxy.databases.svc.cluster.local:3306`
- **MySQL root secret**: `kubectl get secret -n databases mysql-cluster-secrets -o jsonpath='{.data.root}' | base64 -d`

## Nodes (SSH)
```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane
ssh -p 65300 akhozya@worker-node
ssh -p 65300 z3us@worker-node-2
```
No sudo over SSH (triggers pam_faillock). Create bash script + scp + user-run.

## Security / Ingress
New ingress apps need:
```yaml
traefik.ingress.kubernetes.io/router.middlewares: |
  traefik-redirect-https@kubernetescrd,
  traefik-security-headers@kubernetescrd
```
Namespace prefix: `traefik-*` (apps) | `monitoring-*` (monitoring).
Rate limits: 200/min (default) | 500/min (n8n/immich/HA) | none (authentik).

## Shell Gotchas
- Always `-f` flag with `rm/cp/mv` (aliases require confirmation).
- Parallel Bash: one fail → all siblings cancelled. Add `|| true` to fragile commands (SSH, kubectl exec, curl).
- Never batch fragile remote commands with important ones.
- jq: avoid `!=`, use `| select(.x > 0)` (bash escaping breaks `!`).
