# Homelab — Agent Instructions

K3s **production** (single env — no staging; merge to `main` deploys straight to prod), 4 nodes, Flux GitOps, 16 apps. Claude reads this through `CLAUDE.md`; Codex reads this file directly.

## Cluster
| Node | IP | Role | SSH |
|---|---|---|---|
| `gmk-k3s-control-plane` | 192.168.1.127 | CP | `ssh -p 65300 akhozya@gmk-k3s-control-plane` (alias `ssh_master_node`) |
| `worker-node` | 192.168.1.129 | W1 | `ssh -p 65300 akhozya@worker-node` (alias `ssh_worker_node`) |
| `worker-node-2` | 192.168.1.126 | W2 | `ssh -p 65300 z3us@worker-node-2` (alias `ssh_worker_node2` — no dash before 2) |
| `immich-vm` | 192.168.1.231 | GPU worker (Arch VM on the NAS, Intel QSV passthrough; joined 2026-07-10) | `ssh -p 65300 akhozya@immich-vm` — NEVER in-guest reboot / `virsh destroy` (GPU reset-bug; phase2 carve-out handles reboots) |

Kustomization deps (branching, not a chain): `flux-system` → `infrastructure-controllers` → { `coredns` | `infrastructure-configs` → `apps` | `monitoring-controllers` → `monitoring-configs` }.

## SSH / sudo
Agents do not have sudo. Node-side debug + fix workflow: `homelab-node-fix` skill (SSH+TTY pattern). Persistent fixes via ansible roles at `docs/scripts/node-maintenance/`; trigger via systemd: `sudo systemctl start node-maintenance-sync.service` (git pull) → `sudo systemctl start node-maintenance-config.service` (drift-heal).

## Hard Invariants (blast radius = cluster)
- **GitOps only.** `kubectl apply -f` no `--dry-run=server` = violation. Commit → Flux reconcile 60s. Never `kubectl edit/patch/replace`.
- **Pin all images** `major.minor.patch-variant`. Floating drift silent. Kyverno catch only `:latest`/no-tag. Helm chart-default images (no tag in values) count as pinned via the pinned chart version — don't mirror them into values (renovate-blind bare tags skew on chart bumps).
- **DB username = app name.** No direct SQL drops, no force-delete DB pods. Use CRDs (CNPG/Percona) + `kubectl rollout restart`.
- **Every ingress = NetworkPolicy.** Dual access (internal + Cloudflare Tunnel) = 2 ingress rules.
- **NetworkPolicy ports**: container port, not service port.
- **SOPS = truth** for secrets + Cloudflare tunnel config.
- **Kyverno enforce resource limits** all containers (init included), PSS, NetworkPolicy, image-pin.
- **`readOnlyRootFilesystem`** needs `/tmp` emptyDir volume.
- **CI validation — a signal, NOT a merge gate.** `.github/workflows/validate.yaml` runs yamllint + shellcheck + gitleaks + sops-check + init-resources + image-pin + kubeconform × 6 kustomize roots on every push (~45s p95; `paths-ignore` skips docs/markdown-only pushes). Branch protection is unavailable (private repo on the Free plan), so **nothing mechanically stops a validate-red commit from reaching prod**: Flux syncs `main` every 5 min whatever CI says, and `/gitops-workflow` step 3c blocking `fr` on red only withholds the manual nudge. The gates that actually hold are the pre-commit review loop below and `/homelab-yaml-validate` — both run before the commit exists.
- **Pre-commit review loop (substantive code/config — gate-of-record).** Before committing a non-trivial diff: (1) dispatch the opposite-family peer (resolve via `peer-reviewed-implementation/scripts/reviewer-peer`; from Claude = Codex `codex-rescue`, from Codex = Claude) for a **STATIC git-only** review — allowed `git diff/show/log` + file reads, FORBIDDEN run-anything (state gates already ran green; unconstrained it re-runs the full local gate and stalls ~14min with no verdict), demand a **one-message verdict** (no loop), point it at `.claude/review-invariants.md`. Codex runs `xhigh` reasoning (global `~/.codex/config.toml`). (2) Process findings via `superpowers:receiving-code-review` — verify each against the code, push back on wrong/YAGNI, fix in severity order, test each. (3) Re-review **delta-scoped** WHILE the latest round returns CRITICAL/HIGH, **cap 3 rounds**; a clean/nits-only round → commit. **No Gemini, no PR-babysitting.** Docs/markdown-only commits are exempt. Replaces the retired cavecrew pre-push gate.
- **Review rubric.** Any reviewer (Codex, ECC/security) MUST check the diff against `.claude/review-invariants.md` — semantic bug-classes CI misses (Flux healthCheck GVK, Kyverno `=()` soft-anchor, NetworkPolicy AND/OR, PSS Baseline hostPath, external-access = central `cloudflared.yaml` not a 2nd Ingress, etc.). Grep the target file to confirm name/GVK claims before flagging.

## Sessions & Worktrees (blast radius = uncommitted files)
Concurrent agent sessions share one checkout → silent file stomp. So:
- **Main tree = pristine.** `/Users/akhozya/source-code/homelab` is the checkout Flux reconciles. NEVER edit files there directly — `worktree-guard` PreToolUse hook BLOCKS Edit/Write/MultiEdit on it.
- **Edit in a worktree.** Per task: `git worktree add .claude/worktrees/<task> -b wt-<task> && cd $_`. Commit there → merge `wt-<task>` → main → push → `fr`. Flux source = `branch: main`, so worktree branches are invisible to the cluster until merged.
- **Solo escape.** No other agent session running? `touch .claude/.allow-main-edits` (gitignored, local) to edit main directly. One-off: `WORKTREE_GUARD_SKIP=1`.
- **Scope = this repo only.** Worktree isolates the homelab tree, NOT `~/.claude/**` (skills/hooks/dotfiles = separate chezmoi repo) — two sessions editing those still race.
- **Worktree ≠ cluster mutex.** Isolates FILES, not the live cluster. Concurrent `fr`/rollout/SSH still collide (cause of 2026-05-24 wedge). Serialize cluster ops via `cluster-reboot`/`cluster-roll`.

## Docs (read before acting)
- `docs/ARCHITECTURE.md` — how it's organized + why (design principles, mermaid diagrams, cut corners). Read first for orientation. Changes only when *design* changes, not counts.
- `docs/HOMELAB_ANALYSIS.md` — state tracker. Update after meaningful change (PostToolUse hook enforces).
- `docs/HOMELAB_HISTORY.md` — append-only changelog.
- `docs/CODEMAPS/` — structural maps ([index + content rules](docs/CODEMAPS/README.md)): [apps](docs/CODEMAPS/apps.md), [networking](docs/CODEMAPS/networking.md), [databases](docs/CODEMAPS/databases.md), [monitoring](docs/CODEMAPS/monitoring.md), [backup-restore](docs/CODEMAPS/backup-restore.md).
- `.backup/README.md` — DR runbook.
- `docs/SECRETS_ROTATION.md` — rotation schedule.

## Skills + shared scripts
Claude discovers homelab skills from `~/.claude/skills/`; Codex uses migrated skills from `~/.codex/skills/`. Each `SKILL.md` frontmatter advertises when it fires. Shared kubectl/flux/jq helpers live in the matching `_shared/` directory — reference these from new skills instead of inlining pipelines.

Homelab-coupled skills (non-exhaustive — frontmatter is source of truth):
- `cluster-stale-cleanup` — scan stale K8s (failed pods, jobs without TTL, RS over revisionHistoryLimit, released PVs, stuck Helm). GitOps cleanup recs.
