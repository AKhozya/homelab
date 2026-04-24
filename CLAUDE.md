# Homelab — Claude Instructions

K3s staging, 3 nodes, Flux GitOps, 18 apps. Follow global `~/.claude/CLAUDE.md` for workflow (GitOps, DBs, SSH, shell gotchas, skills).

## Docs (read before acting)
- `docs/HOMELAB_ANALYSIS.md` — state tracker. Update after meaningful infra/app change (enforced via PostToolUse hook).
- `.backup/README.md` — DR runbook.
- `docs/SECRETS_ROTATION.md` — rotation schedule.

## Cluster
| Node | IP | Role |
|---|---|---|
| `gmk-k3s-control-plane` | 192.168.1.127 | CP |
| `worker-node` | 192.168.1.129 | W1 |
| `worker-node-2` | 192.168.1.126 | W2 |

Kustomization dep order: `flux-system` → `infrastructure-controllers` → `infrastructure-configs` → `monitoring-controllers` → `monitoring-configs` → `apps`.

## Hard Invariants (blast radius = cluster)
- **GitOps only.** `kubectl apply -f` no `--dry-run=server` = violation. Commit → Flux reconcile 60s.
- **Pin all images** `major.minor.patch-variant`. Floating drift silent. Kyverno catch only `:latest`/no-tag.
- **DB username = app name.** No direct SQL drops, no force-delete DB pods. Use CRDs (CNPG/Percona) + `kubectl rollout restart`.
- **Every ingress = NetworkPolicy.** Dual access (internal + Cloudflare Tunnel) = 2 ingress rules.
- **SOPS = truth** for secrets + Cloudflare tunnel config. 51 SOPS secrets tracked.
- **Kyverno enforce resource limits** all containers (init included), PSS, NetworkPolicy, image-pin.
- **`readOnlyRootFilesystem`** needs `/tmp` emptyDir volume.

## App Conventions
- **Ingress middlewares** (new apps): `traefik-redirect-https@kubernetescrd,traefik-security-headers@kubernetescrd`
- **Rate limits**: 200/min default, 500/min heavy (n8n/immich/HA), none on authentik.
- **Namespace prefix**: `traefik-*` (app middlewares) | `monitoring-*` (monitoring middlewares).
- **NetworkPolicy ports**: container port, not service port.

## DB Proxies
- Postgres: `main-postgres-rw-pooler.databases.svc.cluster.local:5432` (PgBouncer)
- MySQL: `main-mysql-haproxy.databases.svc.cluster.local:3306` (HAProxy)
- MySQL root: `kubectl get secret -n databases mysql-cluster-secrets -o jsonpath='{.data.root}' | base64 -d`

## Teardown Pattern
```bash
flux suspend kustomization <name>
kubectl delete -f <file.yaml>
git rm <files> && git commit -m "Remove: <resource>" && git push
flux resume kustomization <name>
flux reconcile kustomization <name> --timeout=60s
```