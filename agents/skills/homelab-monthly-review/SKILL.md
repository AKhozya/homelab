---
name: homelab-monthly-review
description: Use when running the monthly homelab review ("monthly review", "homelab review", review wakeup fires — 1st week each month). Full posture sweep — node security scans, Kyverno PolicyReports, trivy-scan image-CVE run, Popeye score diff, alerts, Flux/CI, certs, backups, disk, DB health, stale resources, renovate, rotation deadlines, pending-item sweep, upstream re-checks, skill stocktake + skill review/actualization pass, subsystem-map verify, docs currency, code comment hygiene, memory/KB health, worktree-guard marker age, then actions via worktree + /gitops-workflow.
---

# Homelab monthly review

**Lesson (2026-06-05): checklist-following ≠ completeness** — sweep every posture surface, then act. ANALYSIS `Monthly Review Checklist` section points here.

## Phase 0 — prep
1. `git pull --ff-only origin main` in main tree.
2. Worktree: `git worktree add .claude/worktrees/monthly-review -b wt-monthly-review`.
3. Gather: ANALYSIS `Upcoming deadlines` table, `docs/SECRETS_ROTATION.md` due dates, memory `project_maintenance_schedules` rotation deadlines, HOMELAB_HISTORY last-month entries.
4. List overdue + due-this-month + event-gated items whose event fired (check evidence, e.g. kernel upgrade for UFW-class validations).

## Phase 1 — posture sweep (read-only, parallel-safe)

| Surface | How | Record (diff vs prior month) |
|---|---|---|
| Node security scans | compact grep below — NO sudo (logs `root:adm` 640, both users in adm) | suspect files / rootkits / warning count per node |
| Kyverno | `kubectl get vpol` (12 CEL ValidatingPolicies, all READY true + `validationActions: [Deny]` — sole engine since 2026-07-12, CPs/parity retired) + polr summary jq below | fail must = 0 |
| Image CVEs — trivy-scan (monthly CronJob in `trivy-scan` ns since 2026-07-14; replaced trivy-operator) | **Run it on review night**: `kubectl create job trivy-scan-manual-<date> --from=cronjob/trivy-scan -n trivy-scan` → ~15-30min for ~80 images (11min measured 2026-07-14 authenticated) → `kubectl logs job/... -c trivy` (per-image CRITICAL/HIGH tables; job FAILS on any image error — rerun after checking FATAL lines). Scheduled run (1st 08:00 UTC) output lands in Loki if pod already TTL-reaped (24h). **Saturday caveat**: weekly upgrade+rolling-reboot window = Sat 04:30 UTC + cascade — a reboot mid-scan kills the job; review night on a Saturday → launch well clear of the window (late evening UTC or Sunday) | per-image CRITICAL/HIGH tally trend; fixable = Renovate bump or upstream issue (see 3 filed 2026-07-05) |
| Popeye | `kubectl create job --from=cronjob/popeye popeye-manual-<date> -n popeye` → wait → logs | score + section deltas. Resource warns (POP-109/110/505) = right-sizing class, load-dependent — don't panic-tune. Operator-owned Service lints in `databases/` (POP-1106/1100/1102 on Percona/Redis svcs) = known cosmetic |
| Alerts | Alertmanager v2 via pod exec, exclude Watchdog | 0 expected |
| Flux | `flux get kustomizations` — READY is column 4, not 3 | all True |
| CI | `gh run list --limit 1` | green |
| Certs | `kubectl get certificate -A` — any not Ready / renewal near | all Ready |
| Backups | 6 backup CronJobs last-run status + NAS replication recency | all on schedule |
| Disk | per-node `df` on `/` + W2 `/mnt/extra-storage` (DiskPressure history) | % used trend |
| DB health | CNPG status + Percona ready + Redis sentinel `ckquorum`; PG/MySQL primaries pinned W1 (`db-primary-pin` drift check — pin drifts SILENTLY on failover; Redis NOT pinnable, report-only) | healthy + on-pin |
| Stale resources | `/cluster-stale-cleanup` quick scan | cleanup recs |
| Node-maintenance | phase1/phase2 last `systemctl show -p ActiveState,Result` + CP `phase2-pending` absent + per-node `checkupdates` count | both `success`, no stuck flag, counts ≈ 0 — proves workers actually current, not just CP (AUR-build cascade left workers a week stale 2026-06-20; see `gotcha_node_maintenance_aur_build`) |
| Renovate | `gh pr list --state open` | open PRs triaged |

```bash
# security scan rollup — all 4 nodes, current + prior month, prev computed
bash ~/.agents/skills/homelab-monthly-review/scripts/security-scan-rollup.sh

# kyverno violations summary (strict shared check — exit 2 on fetch fail)
bash ~/.agents/skills/_shared/check-kyverno.sh --summary
```

## Phase 2 — checklist core
1. **Skill stocktake + skill review/actualization pass** — `/skill-stocktake full` (background agent OK; read-only verdicts; apply factual fixes + `/chezmoi-sync` after). Then over `~/.agents/skills/` (method validated by the 2026-07-16 full skills review — read-only finder agents per axis, verify STALE against repo before editing, lossless-verify on relocations):
   - **Mechanical**: `bash ~/.agents/skills/kb-hygiene/scripts/lint-skill-scripts.sh` (shellcheck + shfmt + rg-as-command) + `bash ~/.agents/skills/kb-hygiene/scripts/skill-sizes.sh` (FAT >1000w → relocate situational detail to `reference-*.md`, keep routing pointer in SKILL.md).
   - **Descriptions**: frontmatter `description:` loads into EVERY session's system prompt — trim body-detail/history narration, but preserve ALL trigger phrases, "NOT for → sibling-skill" routing, and NEVER/ONLY safety rules. Touch only the description value, never other frontmatter keys (`metadata.triggers`, `user-invocable`).
   - **Retirement propagation**: for anything retired/replaced since last review, `grep -ril "<name>" ~/.agents/skills` — the dominant skill-rot class (2026-07-16 run: trivy-operator ghosts in 3 skills, 3-node fleet claims in 4 skills after immich-vm joined).
   - **Changelog narration**: cut skill-self-history ("built/added X after Y"); KEEP incident dates/SHAs/repro that change operator behavior.
   - **Codification**: inline pipelines that are deterministic AND (repeated across skills OR quoting-fragile) → `scripts/` or `_shared/` (reuse before new); invoke by absolute `~/.agents/skills/...` path; remove the inline copy. Check for drifted script COPIES across skills — consolidate to `_shared/`.
   - **Upstream skills**: check `~/.agents/.skill-lock.json` — never hand-edit upstream-installed skills (update clobbers); findings there = report or uninstall.
   - Flag skills with no invocation in >3 months for retirement review.
   - **Repo snapshot** (`agents/` in the homelab repo, a read-only copy of the published skills and rules). Run it in this review's task worktree, never in the main tree. If `scripts/sync-agents.sh` is absent, or the review is not running on the Mac, skip the step and say so in the report. Otherwise run `scripts/sync-agents.sh --check` and act on its exit code, or on the exit code of any `--update` a row below asks for:

     | Exit of `--check` or `--update` | Action |
     |---|---|
     | 0 from `--check` | If an earlier row changed a file in this worktree, continue with row 1's commit step. Otherwise nothing to do |
     | 0 from `--update` | continue row 1. If the `CLAUDE.md` source changed, hand-edit `CLAUDE.global.md`. Run `--check` until it exits 0, then review and commit |
     | 2 | read each path the report names. If a skill was renamed or deleted, update the allowlist in the repo or the denylist in dotfiles, then run `chezmoi-sync` for the denylist |
     | 3, 4 | For a copied skill, helper or `AGENTS.global.md`, fix the source in dotfiles, run `chezmoi-sync`, then run `--update`. For `README.md`, `sync/` or `CLAUDE.global.md`, fix the file in the repo. If a forbidden entry exists only in the target, delete it in the worktree. If git tracks it, remove it with `git rm --cached`. If `origin/main` contains the file or term, decide on a history rewrite before the next push. If the repo is public, GitHub already shows that history. Then run `--check` again |
     | 5 | fix the flagged helper's or skill's source in dotfiles, run `chezmoi-sync`, then run `--update` again |
     | 70 | read the error, fix its cause, run the mode again |
     | 1 | resolve every finding. For a list finding, update the allowlist in the repo, or the denylist in dotfiles and run `chezmoi-sync`. If an allowlisted skill or helper mentions a denylisted helper, choose one: edit the mention in dotfiles, or move the skill to the denylist. Run `chezmoi-sync` after either. Never allowlist the helper. The denylist holds it back from publication. Run `--update`. If the `CLAUDE.md` source changed, hand-edit `CLAUDE.global.md`. Repeat until `--check` exits 0. Then `git add -A agents` and commit through `/gitops-workflow`, with the Codex loop on `git diff --cached agents/` |
2. **Subsystem-map verify** — the maps in `docs/subsystems/` carry structure/relations/gotchas only, per the content rules in `docs/subsystems/README.md`: NO image/chart versions, NO counts, NO changelog (that content was the drift treadmill — 17+ stale pins found 2026-07-16 before the rule). Pass = 1-2 agents checking each map's path anchors + relation claims against manifests (trust manifest over doc), plus a rule-violation grep: `rg -n '\b\d+\.\d+\.\d+' docs/subsystems/` (hits other than IPs/ports = drift back into versions). No live-cluster fact dump — nothing in the maps should need one.
3. **Docs currency** — beyond the subsystem maps: ARCHITECTURE.md, HOMELAB_ANALYSIS platform facts, `docs/disaster-recovery/README.md`, `node-maintenance/README.md`, SECRETS_ROTATION. Spot-check dated claims, versions, counts, and schedules against live/repo; for anything retired or replaced THIS month, `git grep -il "<name>" docs/` and purge live-voiced references (same retirement-sweep method as the memory item below). Docs asserting something the cluster no longer does = highest-priority fix.
4. **Code comment hygiene** — two lenses over repo comments (start from subsystems touched in the last month, `git log --since` file list):
   - *Stale*: claim-bearing comments (versions, schedules, counts, "temporary", "since <date>", "X does Y") cross-checked against the code and docs they describe — reason about which side is wrong; a comment contradicting reality gets fixed or deleted in the same worktree.
   - *AI-slop*: captain-obvious comments (restating the next line), over-verbose multi-paragraph prose where one line carries the constraint. Keep only comments stating what the code can't show (why, gotcha, external coupling); delete the rest.
5. **Over-engineering sweep (ponytail)** — `/ponytail-audit` on the script/tooling surface (`node-maintenance/**`, `scripts/**`, `.claude/hooks/`) + `/ponytail-debt` to harvest deferred `ponytail:` markers into a ledger. Triage findings against GitOps conventions; drop nits that fit homelab patterns. See gap-note on scope before acting.
6. **Memory/KB health (light — full pass = `/kb-hygiene`)** — dominant rot class is staleness, esp. RETIREMENTS NOT PROPAGATED (2026-07-13: one retired gate live-voiced in 6 files):
   - `bash ~/.agents/skills/kb-hygiene/scripts/index-integrity.sh <memory-dir>` — 0 orphans/dangling expected.
   - `wc -c <memory-dir>/MEMORY.md` — soft target ≤17.1KB, hard read-limit 24.4KB; over soft → per-line trim (fact-coverage method in kb-hygiene reference).
   - Retirement sweep: for anything retired/replaced THIS month (gate, procedure, workload, role), `grep -ril "<name>" <memory-dir> ~/.agents/skills` — mark superseded, don't leave live-voiced advice.
   - Spot-check 3-5 version/count pins in memory vs repo (`installed_plugins.json`, role count, image tags) — pins ALWAYS drift; point at authoritative file instead of re-pinning.
   - Corpus feels prose-heavy or >6 months since full pass → run `/kb-hygiene` (last full: 2026-07-13 run 6).
7. **Worktree-guard marker** — `ls -la <repo>/.claude/.allow-main-edits 2>/dev/null`; older than a day → delete (stale marker = guard silently down; 3-week guard-down incident 2026-07-04, memory `reference_worktree_isolation`).

## Phase 3 — pending sweep + upstream re-checks
- Re-check each pending item's upstream issue state (`gh api repos/<o>/<r>/issues/<n>`); retarget or close with evidence.
- Anything metric-gated (memory limits, soak windows): query VMSingle (`port-forward svc/vmsingle-vmsingle 8429` + `max_over_time(...)`) — record peak windows, not just instant. Limit ≠ reservation — don't shrink limits on critical-path (DNS) for cosmetic savings.

## Phase 4 — actions
- Decisions (security tradeoffs, live failovers) → AskUserQuestion ONCE, batched.
- Live cluster ops (failover tests, re-pins) serialized, AFTER GitOps edits validated; verify app reconnect (immich ioredis — see `db-primary-pin` caveats).
- Edits: worktree → `/homelab-yaml-validate` → peer static pre-commit review loop (per /gitops-workflow) → commit → merge → push → CI green → `fr` → verify.
- The review loop's state table decides when to commit.

## Phase 5 — docs + memory
1. ANALYSIS: pending table rows (close/retarget with evidence), changelog highlight, `**Next Review**` date.
2. HISTORY: one dated entry at the top, per-item outcome + evidence. Then trim: HISTORY keeps 3 months. Delete every entry whose `### YYYY-MM-DD` date is more than 3 months before the review date. An entry runs from its heading to the next `## ` or `### ` heading. Git keeps the deleted text. Then find each link to a deleted entry, from other files (`git grep -n 'HOMELAB_HISTORY.md#<date>'`) and inside HISTORY (`grep -n '(#<date>' docs/HOMELAB_HISTORY.md`), and replace it with the entry's commit.
3. Memory: update files whose claims changed (e.g. auth flow shape); MEMORY.md index hooks.
4. `/chezmoi-sync` any `~/.claude/**` edits.
5. Teardown worktree. Quarterly (every 3rd month, see ANALYSIS): add `/automation-audit-ops`.

## Known gap-classes (keep honest)
- **Popeye score fluctuates with load** — compare section-level, not headline; 100→90 ≈ resource warns, not security.
- **Pin drift is silent** — check DB primaries every review even when nothing alerted.
- **Event-gated items need evidence hunting** — "validate on next kernel upgrade" class: the event may have already fired unnoticed.
- **ponytail sweep is greenfield-first** — homelab is YAML/bash, not app code: `/ponytail-audit` value is marginal (over-built scripts only) and `/ponytail-debt` is ~empty (no `ponytail:` markers accumulate with mode=off default). If the review runs IN the claude-telegram bot, ponytail must be installed there first (bot plugins are seeded-once on PVC, no auto-update — see `apps/claude-telegram` init plugin-update fix).
