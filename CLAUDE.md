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
Claude no sudo. Node-side debug + fix workflow: `/homelab-node-fix` skill (SSH+TTY pattern). Persistent fixes via ansible roles at `docs/scripts/node-maintenance/`; trigger via systemd: `sudo systemctl start node-maintenance-sync.service` (git pull) → `sudo systemctl start node-maintenance-config.service` (drift-heal).

## Hard Invariants (blast radius = cluster)
- **GitOps only.** `kubectl apply -f` no `--dry-run=server` = violation. Commit → Flux reconcile 60s. Never `kubectl edit/patch/replace`.
- **Pin all images** `major.minor.patch-variant`. Floating drift silent. Kyverno catch only `:latest`/no-tag.
- **DB username = app name.** No direct SQL drops, no force-delete DB pods. Use CRDs (CNPG/Percona) + `kubectl rollout restart`.
- **Every ingress = NetworkPolicy.** Dual access (internal + Cloudflare Tunnel) = 2 ingress rules.
- **NetworkPolicy ports**: container port, not service port.
- **SOPS = truth** for secrets + Cloudflare tunnel config.
- **Kyverno enforce resource limits** all containers (init included), PSS, NetworkPolicy, image-pin.
- **`readOnlyRootFilesystem`** needs `/tmp` emptyDir volume.
- **CI gate-of-record.** `.github/workflows/validate.yaml` runs yamllint + shellcheck + sops-check + init-resources + kubeconform × 5 kustomize roots on every push (~45s p95). `/gitops-workflow` step 3c blocks `fr` on CI red. Local validation (`/homelab-yaml-validate`) is fast iteration, not bypass.

## Docs (read before acting)
- `docs/HOMELAB_ANALYSIS.md` — state tracker. Update after meaningful change (PostToolUse hook enforces).
- `docs/HOMELAB_HISTORY.md` — append-only changelog.
- `docs/CODEMAPS/` — structural snapshots: [architecture](docs/CODEMAPS/architecture.md), [apps](docs/CODEMAPS/apps.md), [networking](docs/CODEMAPS/networking.md), [databases](docs/CODEMAPS/databases.md), [monitoring](docs/CODEMAPS/monitoring.md), [backup-restore](docs/CODEMAPS/backup-restore.md).
- `.backup/README.md` — DR runbook.
- `docs/SECRETS_ROTATION.md` — rotation schedule.

## Skills + shared scripts
Auto-discovered from `~/.claude/skills/` (each SKILL.md frontmatter advertises when it fires). Shared kubectl/flux/jq helpers live in `~/.claude/skills/_shared/` — reference these from new skills instead of inlining pipelines.

Homelab-coupled skills (non-exhaustive — frontmatter is source of truth):
- `cluster-stale-cleanup` — scan stale K8s (failed pods, jobs without TTL, RS over revisionHistoryLimit, released PVs, stuck Helm). GitOps cleanup recs.
- `rebuilderd-progress` — reproducible-build progress from worker-node + worker-node-2 over N h/d window. Per-worker table + recent BAD summary.
