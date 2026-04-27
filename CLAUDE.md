# Homelab — Claude Instructions

K3s staging, 3 nodes, Flux GitOps, 17 apps. Follow global `~/.claude/CLAUDE.md` for workflow base (caveman, coding rules, parallel calls, chezmoi, safety hook).

## Cluster
| Node | IP | Role | SSH |
|---|---|---|---|
| `gmk-k3s-control-plane` | 192.168.1.127 | CP | `ssh -p 65300 akhozya@gmk-k3s-control-plane` (alias `ssh_master_node`) |
| `worker-node` | 192.168.1.129 | W1 | `ssh -p 65300 akhozya@worker-node` (alias `ssh_worker_node`) |
| `worker-node-2` | 192.168.1.126 | W2 | `ssh -p 65300 z3us@worker-node-2` (alias `ssh_worker_node2` — no dash before 2) |

Kustomization dep order: `flux-system` → `infrastructure-controllers` → `infrastructure-configs` → `monitoring-controllers` → `monitoring-configs` → `apps`.

## SSH / sudo
- Claude NO sudo. Any sudo over SSH → give user command with `ssh -p 65300 -t` (TTY for password prompt).
- Ansible playbooks on CP under `node-maintenance` user. Trigger via systemd: `sudo systemctl start node-maintenance-sync.service` (git pull) → `sudo systemctl start node-maintenance-config.service` (drift-heal apply).

## Hard Invariants (blast radius = cluster)
- **GitOps only.** `kubectl apply -f` no `--dry-run=server` = violation. Commit → Flux reconcile 60s. Never `kubectl edit/patch/replace`.
- **Pin all images** `major.minor.patch-variant`. Floating drift silent. Kyverno catch only `:latest`/no-tag.
- **DB username = app name.** No direct SQL drops, no force-delete DB pods. Use CRDs (CNPG/Percona) + `kubectl rollout restart`.
- **Every ingress = NetworkPolicy.** Dual access (internal + Cloudflare Tunnel) = 2 ingress rules.
- **NetworkPolicy ports**: container port, not service port.
- **SOPS = truth** for secrets + Cloudflare tunnel config. 55 SOPS secrets tracked.
- **Kyverno enforce resource limits** all containers (init included), PSS, NetworkPolicy, image-pin.
- **`readOnlyRootFilesystem`** needs `/tmp` emptyDir volume.

## Docs (read before acting)
- `docs/HOMELAB_ANALYSIS.md` — state tracker. Update after meaningful infra/app change (PostToolUse hook enforces).
- `docs/HOMELAB_HISTORY.md` — historical changelog (append, don't rewrite).
- `docs/CODEMAPS/` — token-lean structural snapshots: [architecture](docs/CODEMAPS/architecture.md), [apps](docs/CODEMAPS/apps.md), [networking](docs/CODEMAPS/networking.md), [databases](docs/CODEMAPS/databases.md), [monitoring](docs/CODEMAPS/monitoring.md), [backup-restore](docs/CODEMAPS/backup-restore.md). Refresh on major changes.
- `.backup/README.md` — DR runbook.
- `docs/SECRETS_ROTATION.md` — rotation schedule.

## Quick Skills
| Command | Purpose |
|---------|---------|
| `/k8s-diagnostics` | Diagnose cluster (nodes, pods, events, DBs) |
| `/gitops-workflow` | Safe GitOps deploy flow |
| `/db-operations` | DB queries, backups, replication |
| `/monitoring-check` | VictoriaMetrics, Grafana, Loki, Alertmanager, Popeye, Kyverno |
| `/networkpolicy-helper` | Generate NetworkPolicy (ports, dual-access, egress) |
| `/ha-enablement` | HA checklist (replicas, anti-affinity, gossip) |
| `/resource-sizing` | CPU/mem limits by tier, tuning |
| `/gitops-verify` | Cluster state verify (7-point check) |
| `/checkpoint` | Capture/compare infra snapshots |

## GitOps Workflow
```
investigate → plan → fix → commit → push → reconcile → verify
```
Validate YAML: `kubectl apply -f <file> --dry-run=server`. Research first; latest helm charts/images; Flux reconciles 60s.

### Flux Reconciliation
**Default: `fr`** — full-stack reconcile zsh function. Refresh helm repos + git source + all 6 kustomizations in dep order, per-unit timeouts. Defined in `~/.zshrc`.

Granular:
```bash
flux reconcile kustomization <name> --timeout=60s
flux reconcile helmrelease <name> -n <namespace> --timeout=60s
flux reconcile source git flux-system --timeout=60s
```

### Teardown Pattern
```bash
flux suspend kustomization <name>
kubectl delete -f <file.yaml>
git rm <files> && git commit -m "Remove: <resource>" && git push
flux resume kustomization <name>
flux reconcile kustomization <name> --timeout=60s
```

## App Conventions
- **Ingress middlewares** (new apps): `traefik-redirect-https@kubernetescrd,traefik-security-headers@kubernetescrd`
- **Rate limits**: 200/min default, 500/min heavy (n8n/immich/HA), none on authentik.
- **Namespace prefix**: `traefik-*` (app middlewares) | `monitoring-*` (monitoring middlewares).
- **Resources**: tier quotas may block rolling updates (need 2x during rollout) — temp bump if needed.

## Database Connections

### PostgreSQL (PgBouncer)
```bash
# App connection
main-postgres-rw-pooler.databases.svc.cluster.local:5432

# Query
kubectl exec -n databases main-postgres-1 -- psql -U postgres -d <database> -c "<query>"
```

### MySQL (HAProxy)
```bash
# App connection
main-mysql-haproxy.databases.svc.cluster.local:3306

# Root password
kubectl get secret -n databases mysql-cluster-secrets -o jsonpath='{.data.root}' | base64 -d

# Query
MYSQL_PASS=$(kubectl get secret -n databases mysql-cluster-secrets -o jsonpath='{.data.root}' | base64 -d)
kubectl exec -n databases main-mysql-mysql-0 -- bash -c "mysql -uroot -p'${MYSQL_PASS}' -e '<query>'"
```

### CouchDB
```bash
kubectl exec -n databases couchdb-couchdb-0 -- curl -s -u <user>:<pass> http://localhost:5984/<db>/_all_docs
```

### Redis
```bash
kubectl exec -n databases deploy/redis -- redis-cli -a <password> INFO
```

## Monitoring Quick Checks

TSDB = VictoriaMetrics (`vmsingle`, `vmagent`, `vmalert`). kube-prometheus-stack chart kept only operator + grafana + alertmanager + kube-state-metrics + node-exporter — no `kube-prometheus-stack-prometheus` pod.

### Firing Alerts (check both VMAlert and Alertmanager)
```bash
# VMAlert (rule eval)
kubectl exec -n monitoring deploy/vmalert-vmalert -- wget -qO- 'http://localhost:8080/api/v1/alerts' 2>/dev/null | \
  jq -r '.data.groups[].rules[] | select(.state=="firing") | "[\(.labels.severity // "unknown")] \(.name)"'

# Alertmanager (delivery — templates can break independently)
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  wget -qO- 'http://localhost:9093/api/v2/alerts' 2>/dev/null | jq -r '.[] | .labels.alertname'
```

### TSDB / Series
```bash
kubectl top pod -n monitoring -l app.kubernetes.io/name=vmsingle
kubectl exec -n monitoring deploy/vmsingle-vmsingle -- wget -qO- 'http://localhost:8429/api/v1/status/tsdb' 2>/dev/null
```

### Popeye Scan
```bash
kubectl create job --from=cronjob/popeye popeye-manual-$(date +%s) -n popeye
```

### Kyverno Violations
```bash
kubectl get policyreport -A -o json | jq -r '.items[].results[]? | select(.result=="fail") | .policy' | sort | uniq -c
```

## Rebuilderd Stats
```bash
echo "=== worker-node ===" && ssh -p 65300 akhozya@worker-node "journalctl -u 'rebuilderd-worker@*' --since today --no-pager 2>/dev/null | grep -oE 'marking as (GOOD|BAD)' | sort | uniq -c" && echo "=== worker-node-2 ===" && ssh -p 65300 z3us@worker-node-2 "journalctl -u 'rebuilderd-worker@*' --since today --no-pager 2>/dev/null | grep -oE 'marking as (GOOD|BAD)' | sort | uniq -c"
```
