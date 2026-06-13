# Homelab — Claude Instructions

K3s **production** (single env — no staging; merge to `main` deploys straight to prod), 3 nodes, Flux GitOps, 16 apps. Global base: `~/.claude/CLAUDE.md`.

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
- **CI gate-of-record.** `.github/workflows/validate.yaml` runs yamllint + shellcheck + sops-check + init-resources + kubeconform × 5 kustomize roots on every push (~45s p95; `paths-ignore` skips docs/markdown-only pushes). `/gitops-workflow` step 3c blocks `fr` on CI red. Local validation (`/homelab-yaml-validate`) is fast iteration, not bypass.
- **Review rubric.** Any code/diff review (cavecrew-reviewer pre-push gate, ECC/security reviewers) MUST read `.claude/review-invariants.md` and check the diff against it — semantic bug-classes CI and these invariants miss (Flux healthCheck GVK, Kyverno `=()` soft-anchor, NetworkPolicy AND/OR, PSS Baseline hostPath, external-access = central `cloudflared.yaml` not a 2nd Ingress, etc.). Grep the target file to confirm name/GVK claims before flagging.

## Sessions & Worktrees (blast radius = uncommitted files)
Concurrent Claude sessions share one checkout → silent file stomp. So:
- **Main tree = pristine.** `/Users/akhozya/source-code/homelab` is the checkout Flux reconciles. NEVER edit files there directly — `worktree-guard` PreToolUse hook BLOCKS Edit/Write/MultiEdit on it.
- **Edit in a worktree.** Per task: `git worktree add .claude/worktrees/<task> -b wt-<task> && cd $_`. Commit there → merge `wt-<task>` → main → push → `fr`. Flux source = `branch: main`, so worktree branches are invisible to the cluster until merged.
- **Solo escape.** No other Claude running? `touch .claude/.allow-main-edits` (gitignored, local) to edit main directly. One-off: `WORKTREE_GUARD_SKIP=1`.
- **Scope = this repo only.** Worktree isolates the homelab tree, NOT `~/.claude/**` (skills/hooks/dotfiles = separate chezmoi repo) — two sessions editing those still race.
- **Worktree ≠ cluster mutex.** Isolates FILES, not the live cluster. Concurrent `fr`/rollout/SSH still collide (cause of 2026-05-24 wedge). Serialize cluster ops via `cluster-reboot`/`cluster-roll`.

## Docs (read before acting)
- `docs/ARCHITECTURE.md` — how it's organized + why (design principles, mermaid diagrams, cut corners). Read first for orientation. Changes only when *design* changes, not counts.
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
