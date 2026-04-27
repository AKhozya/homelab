# Homelab — Claude Instructions

K3s staging, 3 nodes, Flux GitOps, 17 apps. Global base: `~/.claude/CLAUDE.md`.

## Cluster
| Node | IP | Role | SSH |
|---|---|---|---|
| `gmk-k3s-control-plane` | 192.168.1.127 | CP | `ssh -p 65300 akhozya@gmk-k3s-control-plane` (alias `ssh_master_node`) |
| `worker-node` | 192.168.1.129 | W1 | `ssh -p 65300 akhozya@worker-node` (alias `ssh_worker_node`) |
| `worker-node-2` | 192.168.1.126 | W2 | `ssh -p 65300 z3us@worker-node-2` (alias `ssh_worker_node2` — no dash before 2) |

Kustomization dep order: `flux-system` → `infrastructure-controllers` → `infrastructure-configs` → `monitoring-controllers` → `monitoring-configs` → `apps`.

## SSH / sudo
- Claude NO sudo. Sudo over SSH → give user command with `ssh -p 65300 -t` (TTY for password prompt).
- Ansible on CP under `node-maintenance` user. Trigger via systemd: `sudo systemctl start node-maintenance-sync.service` (git pull) → `sudo systemctl start node-maintenance-config.service` (drift-heal).

## Hard Invariants (blast radius = cluster)
- **GitOps only.** `kubectl apply -f` no `--dry-run=server` = violation. Commit → Flux reconcile 60s. Never `kubectl edit/patch/replace`.
- **Pin all images** `major.minor.patch-variant`. Floating drift silent. Kyverno catch only `:latest`/no-tag.
- **DB username = app name.** No direct SQL drops, no force-delete DB pods. Use CRDs (CNPG/Percona) + `kubectl rollout restart`.
- **Every ingress = NetworkPolicy.** Dual access (internal + Cloudflare Tunnel) = 2 ingress rules.
- **NetworkPolicy ports**: container port, not service port.
- **SOPS = truth** for secrets + Cloudflare tunnel config.
- **Kyverno enforce resource limits** all containers (init included), PSS, NetworkPolicy, image-pin.
- **`readOnlyRootFilesystem`** needs `/tmp` emptyDir volume.

## Docs (read before acting)
- `docs/HOMELAB_ANALYSIS.md` — state tracker. Update after meaningful change (PostToolUse hook enforces).
- `docs/HOMELAB_HISTORY.md` — append-only changelog.
- `docs/CODEMAPS/` — structural snapshots: [architecture](docs/CODEMAPS/architecture.md), [apps](docs/CODEMAPS/apps.md), [networking](docs/CODEMAPS/networking.md), [databases](docs/CODEMAPS/databases.md), [monitoring](docs/CODEMAPS/monitoring.md), [backup-restore](docs/CODEMAPS/backup-restore.md).
- `.backup/README.md` — DR runbook.
- `docs/SECRETS_ROTATION.md` — rotation schedule.

## Skills
- `/k8s-diagnostics` — cluster health
- `/gitops-workflow` — deploy flow
- `/db-operations` — DB queries, backups, replication
- `/monitoring-check` — VictoriaMetrics, Grafana, Loki, Alertmanager, Popeye, Kyverno
- `/networkpolicy-helper` — NetworkPolicy generation
- `/ha-enablement` — HA replicas
- `/resource-sizing` — CPU/mem limits
- `/gitops-verify` — 7-point cluster verify
- `/checkpoint` — infra state snapshots

## GitOps
Flow: `investigate → plan → fix → commit → push → reconcile → verify`. Validate YAML: `kubectl apply -f <file> --dry-run=server`.

**Reconcile**: `fr` zsh function = full-stack reconcile (helm repos + git source + 6 kustomizations in dep order). Granular:
```bash
flux reconcile kustomization <name> --timeout=60s
flux reconcile helmrelease <name> -n <namespace> --timeout=60s
flux reconcile source git flux-system --timeout=60s
```

**Teardown**:
```bash
flux suspend kustomization <name>
kubectl delete -f <file.yaml>
git rm <files> && git commit -m "Remove: <resource>" && git push
flux resume kustomization <name>
flux reconcile kustomization <name> --timeout=60s
```

## App Conventions
- **Ingress middlewares**: `traefik-redirect-https@kubernetescrd,traefik-security-headers@kubernetescrd`
- **Rate limits**: 200/min default, 500/min heavy (n8n/immich/HA), none on authentik.
- **Namespace prefix**: `traefik-*` (apps) | `monitoring-*` (monitoring).

## DB Proxies
- Postgres: `main-postgres-rw-pooler.databases.svc.cluster.local:5432` (PgBouncer)
- MySQL: `main-mysql-haproxy.databases.svc.cluster.local:3306` (HAProxy)
- Deep query patterns: `/db-operations` skill.

## Monitoring
TSDB = VictoriaMetrics (`vmsingle`/`vmagent`/`vmalert`). kube-prometheus-stack chart kept only operator + grafana + alertmanager + kube-state-metrics + node-exporter — no `kube-prometheus-stack-prometheus` pod. Query patterns: `/monitoring-check` skill.
