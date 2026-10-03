# Homelab — Agent Instructions

K3s **production** (single env — no staging; merge to `main` deploys straight to prod), 4 nodes, Flux GitOps, 17 apps. Claude reads this through `CLAUDE.md`; Codex reads this file directly.

## Cluster
| Node | IP | Role | SSH |
|---|---|---|---|
| `gmk-k3s-control-plane` | 192.168.1.127 | CP | `ssh -p 65300 akhozya@gmk-k3s-control-plane` (alias `ssh_master_node`) |
| `worker-node` | 192.168.1.129 | W1 | `ssh -p 65300 akhozya@worker-node` (alias `ssh_worker_node`) |
| `worker-node-2` | 192.168.1.126 | W2 | `ssh -p 65300 z3us@worker-node-2` (alias `ssh_worker_node2` — no dash before 2) |
| `immich-vm` | 192.168.1.231 | GPU worker (Arch VM on the NAS, Intel QSV passthrough; joined 2026-07-10) | `ssh -p 65300 akhozya@immich-vm` — NEVER in-guest reboot / `virsh destroy` (GPU reset-bug; phase2 carve-out handles reboots) |

Kustomization deps (branching, not a chain): `flux-system` → { `coredns` | `infrastructure-controllers` → { `infrastructure-configs` → `apps` | `monitoring-controllers` → `monitoring-configs` } }. `coredns` has no `dependsOn`, so DNS never waits on cert-manager or Kyverno health.

## SSH / sudo
Agents do not have sudo. Node-side debug + fix workflow: `homelab-node-fix` skill (SSH+TTY pattern). Persistent fixes via ansible roles at `node-maintenance/`. Only the CP runs the node-maintenance timers. Its playbook configures the CP locally and the other three nodes over SSH. To apply a fix now, run on the CP: `sudo systemctl start node-maintenance-sync.service`. It pulls main. If HEAD differs from the recorded applied SHA, it starts `node-maintenance-config.service` to apply the configuration. If the SHAs match, start `node-maintenance-config.service` on the CP instead.

Read cluster state with `kubectl` (+ `jq`); the API is reachable directly from anywhere an agent runs. Never run a `kubectl proxy` on a node: it serves the API with the rights of the kubeconfig behind it to any local process, without a login. No playbook needs one. The claude-telegram pod has no `python3` — `jq`, `node` and `bun` are its JSON tools. The bot has no `pods/exec` in `monitoring`: exec into node-exporter, which runs in each node's host network, would reach the whole LAN. It reads vmsingle, vmalert and Alertmanager through the API server's service proxy (`kubectl get --raw /api/v1/namespaces/monitoring/services/<name>:<port>/proxy/<path>`). The proxy dials pods from the CP's flannel address, 10.42.0.0, so a target's NetworkPolicy must admit that address.

**From the claude-telegram pod**, node SSH runs under a forced command (`/usr/local/bin/agent-diag`) and serves read-only diagnostics only: `journalctl`, `systemctl` (`status`/`show`/`cat`/`is-*`/`list-*`), `uptime`, `vmstat`, `ps`, `ls`, `cat`. One command per call — no pipes, redirects, quotes, `&&`, no pty, no interactive shell, so `homelab-node-fix` does not apply there. Filter locally (`ssh worker-node journalctl -u k3s-agent --since=-10min | grep sandbox`) and write `--since=…`, not `--since '…'`: an argument cannot contain a space. **Options are an allowlist and must be spelled in full** — `--no-pager`, `-u`/`--unit=`, `-n`/`--lines=`, `--since=`, `--until=`, `-p`/`--priority=`, `-o`/`--output=`, `-k`, `-r`, `-x`, and for `systemctl` `--property=`, `--type=`, `--state=`, `--value`, `--all`. An abbreviation (`--sinc=`) or a cluster (`-qn`) is refused even when the underlying tool would accept it, because that is how `-H` (remote ssh) and `--vacuum-size` (deletes journals) sneak past a pattern. `sar` and `dmesg` are unavailable at all. **`cat` and `ls` accept a path only under `/etc`, `/sys`, `/var/log`, `/usr/local/bin` or `/usr/local/sbin`** (a bare `ls` with no path still lists the login home), and any path containing `..` is refused before the prefix is tested — the login account is the operator's own, so an unrestricted `cat` was an arbitrary-file read. `/proc` is listed file by file rather than as a prefix, because `/proc/self/root` is a symlink to `/`: the system-wide one-component files (`/proc/meminfo`, `/proc/loadavg`, …), `/proc/pressure/{cpu,io,memory}`, and per-PID `status`/`stat`/`cmdline`/`io`/`limits` — anything deeper is refused. A previous-boot journal needs the offset attached (`journalctl -b-1`, `--boot=-1`, or `--list-boots`); `-b -1` is refused because a lone `-1` is matched as an option. `ps` still takes `-e`/`-f`/`-ef`/`--sort=`, but its only permitted bare-word operand is `aux` or `auxww`; `-o`/`-eo` are gone, because their format list is a bare word too and `ps aux` already carries RSS. Operator sessions from the Mac use a different key and are unrestricted.

## Hard Invariants (blast radius = cluster)
- **GitOps only.** `kubectl apply -f` no `--dry-run=server` = violation. Flux fetches `main` every 5 min; the six Kustomizations below `flux-system` reconcile every 1 min. Never `kubectl edit/patch/replace`. Two carve-outs, both in `docs/disaster-recovery/README.md`:

  | Carve-out | When | Why |
  |---|---|---|
  | the one-shot DR restore Jobs | during a restore; never committed, deleted after use | if committed, Flux would re-run a destructive restore every reconcile |
  | `kubectl apply -k infrastructure/coredns/` | if the cluster is fresh, before `flux bootstrap` | Flux's controllers need that DNS to fetch the repo; Flux adopts the objects on its first reconcile |

- **Pin all images** `major.minor.patch-variant`. Floating drift silent. Kyverno catch only `:latest`/no-tag. Helm chart-default images (no tag in values) count as pinned via the pinned chart version — don't mirror them into values (renovate-blind bare tags skew on chart bumps).
- **DB username = app name.** No direct SQL drops, no force-delete DB pods. Use CRDs (CNPG/Percona) + `kubectl rollout restart`, with two exceptions:

  | Workload | Restart by | Why not `rollout restart` |
  |---|---|---|
  | opstree Redis pods | deleting one pod at a time, replicas before the master | it re-arms the operator's annotation loop (`bf7bf65d`) |
  | a Flux-managed Deployment | `agents/skills/_shared/restart-workload.sh` | Flux strips the `restartedAt` annotation, so it silently does nothing (`d6d67c20`) |

- **Every ingress = NetworkPolicy.** Dual access (internal + Cloudflare Tunnel) = 2 ingress rules.
- **NetworkPolicy ports**: container port, not service port.
- **SOPS = truth** for secrets + Cloudflare tunnel config.
- **Kyverno enforce resource limits** all containers (init included), PSS, NetworkPolicy, image-pin.
- **`readOnlyRootFilesystem`** needs `/tmp` emptyDir volume.
- **CI validation — only the secret scan is a required check.** The checks are listed in `.github/workflows/README.md`:

  | Workflow | Runs on | Note |
  |---|---|---|
  | `validate.yaml` | push to `main`, PR to `main`; `paths-ignore` skips docs/markdown-only changes | p50 28s, max 69s across the 35 successful runs measured 2026-10-02. kubeconform validates the HelmRelease CR. helm-render checks the chart's own templates |
  | `gitleaks.yaml` | push to `main`, PR to `main`; no `paths-ignore` | scans markdown runbooks too |

  The `main` ruleset:

  | Rule | Effect |
  |---|---|
  | a PR to `main` needs 1 approval and a successful `gitleaks secret scan` | only the owner has write access, so only the owner's approval counts |
  | the repo admin role is a bypass actor (mode `always`) | the owner pushes to `main` directly and can merge a PR without an approval or a finished scan |
  | no rule requires the Validate checks | if they fail, a commit can still reach `main` |

  A direct push reaches prod whatever CI reports, because Flux syncs `main` every 5 min. If checks fail, `/gitops-workflow` step 3c skips the manual `fr` reconcile, and Flux still deploys on its next sync. Two checks run before a direct push exists: the pre-commit review loop below and `/homelab-yaml-validate`. If a commit changes only docs or markdown, the review loop does not apply.
- **Pre-commit review loop (substantive code/config — gate-of-record).** Before committing a non-trivial diff: (1) dispatch the opposite-family peer (resolve via `peer-reviewed-implementation/scripts/reviewer-peer`; from Claude = Codex `codex-rescue`, from Codex = Claude) for a **STATIC git-only** review — allowed `git diff/show/log` + file reads, FORBIDDEN run-anything (state gates already ran green; unconstrained it re-runs the full local gate and stalls ~14min with no verdict), demand a **one-message verdict** (no loop), point it at `.claude/review-invariants.md`. `codex-review.sh` runs Codex at `xhigh` by default. If you pass `--effort`, it uses that level instead. If a `codex-rescue` dispatch sets no effort, it runs at `high`, the global default in `~/.codex/config.toml`. The operator's rule for the peer-reviewed-implementation flow requires `xhigh` for plan and code reviews (`~/.codex/AGENTS.md`). `reviewer-peer` prints that effort. A review in that flow must request it. (2) Process findings via `superpowers:receiving-code-review` — verify each against the code, push back on wrong/YAGNI, fix in severity order, test each. (3) Re-review **delta-scoped**. Severity decides whether you may commit. The round count
decides when to escalate to the user.

| Round returns | Rounds 1-5 | Round 6 |
|---|---|---|
| CRITICAL, HIGH or MEDIUM | fix, then re-review. Reset the LOW streak to zero | do not commit. Hand the open findings to the user |
| only LOW or NIT, first in a row | fix, then re-review | fix, then commit |
| only LOW or NIT, second in a row | fix, then commit. Those fixes ship unreviewed. That is the accepted cost | fix, then commit |
| nothing | commit | commit |

If a dispatch returns no verdict, re-dispatch it. That is not a round. It never counts as
clean. If three dispatches in a row return no verdict, stop and tell the user.

A round count alone is the wrong gate. A 3-round cap that permitted a commit shipped two real
defects on 2026-08-08:

| Defect | Why it mattered |
|---|---|
| a helper documented as comparing bytes used `$(cat f)` | command substitution strips trailing newlines, so it never compared bytes |
| a rule named `bash -e {0}` as GitHub's shell command | an explicit `shell: bash` resolves to `bash --noprofile --norc -eo pipefail {0}`. The added `-o pipefail` changes a piped command's exit code |

Rounds 4 and 5 found them. The severity rule requires both rounds. If a 3-round cap applies, it permits an earlier commit:

| Round | CRITICAL | HIGH | MEDIUM | LOW/NIT | Rule says |
|---|---|---|---|---|---|
| 1 | 0 | 3 | 5 | 2 | continue |
| 2 | 0 | 2 | 3 | 3 | continue |
| 3 | 0 | 0 | 2 | 5 | continue |
| 4 | 0 | 0 | 1 | 3 | continue |
| 5 | 0 | 0 | 1 | 3 | continue |
| 6 | 0 | 0 | 0 | 0 | commit |

**No Gemini, no PR-babysitting.** Docs/markdown-only commits are exempt. Replaces the retired cavecrew pre-push gate.
- **Review rubric.** Any reviewer (Codex, ECC/security) MUST check the diff against `.claude/review-invariants.md` — semantic bug-classes CI misses (Flux healthCheck GVK, Kyverno `=()` soft-anchor, NetworkPolicy AND/OR, PSS Baseline hostPath, external-access = central `cloudflared.yaml` not a 2nd Ingress, etc.). Grep the target file to confirm name/GVK claims before flagging.

## Sessions & Worktrees (blast radius = uncommitted files)
Concurrent agent sessions share one checkout → silent file stomp. So:
- **Main tree = pristine.** `/Users/akhozya/source-code/homelab` is the checkout Flux reconciles. NEVER edit files there directly — `worktree-guard` PreToolUse hook BLOCKS Edit/Write/MultiEdit on it.
- **Edit in a worktree.** Per task: `git worktree add .claude/worktrees/<task> -b wt-<task> && cd .claude/worktrees/<task>`. Commit there → merge `wt-<task>` → main → push → `fr`. Flux source = `branch: main`, so worktree branches are invisible to the cluster until merged.
- **Solo escape.** No other agent session running? `touch .claude/.allow-main-edits` (gitignored, local) to edit main directly. One-off: `WORKTREE_GUARD_SKIP=1`.
- **Scope = this repo only.** Worktree isolates the homelab tree, NOT `~/.claude/**` (skills/hooks/dotfiles = separate chezmoi repo) — two sessions editing those still race.
- **Worktree ≠ cluster mutex.** Isolates FILES, not the live cluster. Concurrent `fr`/rollout/SSH still collide (cause of 2026-05-24 wedge). Serialize cluster ops via `cluster-reboot`/`cluster-roll`.

## Docs (read before acting)
- `docs/ARCHITECTURE.md` — how it's organized + why (design principles, mermaid diagrams, cut corners). Read first for orientation. Changes only when *design* changes, not counts.
- `docs/HOMELAB_ANALYSIS.md` — state tracker. Update after meaningful change (PostToolUse hook enforces).
- `docs/HOMELAB_HISTORY.md` — changelog of the last 3 months. A new entry goes at the top; the monthly review deletes entries older than 3 months, and git keeps them. To point another doc at a change, cite its commit, not a HISTORY date.
- `docs/subsystems/` — structural maps ([index + content rules](docs/subsystems/README.md)): [apps](docs/subsystems/apps.md), [networking](docs/subsystems/networking.md), [databases](docs/subsystems/databases.md), [monitoring](docs/subsystems/monitoring.md), [backup-restore](docs/subsystems/backup-restore.md).
- `docs/disaster-recovery/README.md` — DR runbook.
- `docs/SECRETS_ROTATION.md` — rotation schedule.

## Skills + shared scripts
The skills and their helpers live in dotfiles, in `~/.agents/skills/`; `~/.claude/skills/` and `~/.codex/skills/` link into it. [`agents/`](agents/README.md) in this repo is a read-only copy for readers. No tool loads it, and `scripts/sync-agents.sh --update` refreshes it from dotfiles, so edit the dotfiles copy. Each `SKILL.md` frontmatter advertises when it fires. Shared kubectl/flux/jq helpers live in `_shared/`; reference these from new skills instead of inlining pipelines.

Homelab-coupled skills (non-exhaustive — frontmatter is source of truth):
- `cluster-stale-cleanup` — scan stale K8s (failed pods, jobs without TTL, RS over revisionHistoryLimit, released PVs, stuck Helm). GitOps cleanup recs.
