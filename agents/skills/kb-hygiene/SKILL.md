---
name: kb-hygiene
description: Use when cross-reviewing the agent knowledge corpora — memory files, gotchas, skill .md/.sh, CLAUDE.md, repo docs — for duplication, stale claims, or drift, or when the user asks to "clean up memory/skills", "dedup gotchas", "find stale memory", or run a periodic KB hygiene pass. Knowledge-base maintenance only; not for source-code review.
---

# KB Hygiene Cross-Review

## Why this exists

Agent knowledge (memory, gotchas, skills, CLAUDE.md, repo docs) accretes duplication, stale claims, and drift. This skill finds it and fixes it **without quality loss**.

Core law: **lean ≠ lossy** — keep every why/gotcha/repro/date/SHA. Almost all cross-corpus overlap is complementary-by-design — skill = how-to (canonical), memory/gotcha = why + SHA + history, repo-doc = authoritative mechanics — so bias **KEEP-BOTH**, expect near-zero forced deletes. A pass that cuts substance to look terse is the opposite failure.

## When to use / not

- **Use**: periodic KB sweep; user says "cross-review memory/gotchas/skills", "dedup memory", "find stale gotchas", "do a KB hygiene pass".
- **Not**: source-code/diff review (→ Codex / ECC reviewers); a single known-file edit (just edit it).

## How to run

### Phase 1 — Find (read-only agents, one per relevant axis — 8 axes total, scoped runs pick a subset)

Dispatch ONE read-only agent per axis via the **Agent tool**, `subagent_type: general-purpose` (or `Explore` for pure find). Each returns `file:line + verdict` and makes **NO edits**. The reusable prompts live in `prompts/axis-prompts.md` (shared preamble + one block per axis — paste the preamble plus the axis block into each agent's prompt). Axes are independent and read-only → dispatch the chosen subset in one parallel batch (see superpowers:dispatching-parallel-agents).

Axis 1's mechanical checks are scripted: run `scripts/index-integrity.sh [MEMORY_DIR]` first (deterministic orphans / dangling index links / broken `[[wiki-links]]`) and feed its output to the Axis-1 agent, which then does only the semantic dup + count-drift judgment.

| # | Axis | Scope |
|---|---|---|
| 1 | within-memory dup + index integrity | `memory/*.md` + `MEMORY.md` (orphans, broken `[[links]]`, count drift) |
| 2 | memory/gotchas **stale** | each claim vs live repo/cluster — conservative: mark UNVERIFIED, never delete on a guess |
| 3 | memory ↔ skills | `memory/*.md` vs skill `.md`/`.sh` |
| 4 | skill `.sh` captain-obvious comments | `skills/**/*.sh` |
| 5 | memory/gotchas ↔ **repo truth** | vs `docs/`, both `CLAUDE.md`, `.claude/review-invariants.md` (repo authoritative; memory copy = drift-risk) |
| 6 | skills ↔ CLAUDE.md + skill specs | operationalize = keep vs re-declare = dup; shipped+surpassed specs in `docs/superpowers/` = archivable |
| 7 | gotchas ↔ skills | most operational memory, most echoed — don't skip (user-flagged axis) |
| 8 | prose bloat + doesn't-belong | memory-corpus runs: per-file prose-density + RELOCATE (changelog restatements vs HISTORY, dead work, generic knowledge). Validated run 6 — expect most files OK; wins concentrate in session-journal project files |

**Scoped runs are valid** — the ask sets the axis subset: memory-only sweep = axes 1/2/3/5/7/8 (run 6); skills-only = 3/4/6/7 (runs 3-4); MEMORY.md over its size target (soft 17.1KB / hard 24.4KB read limit) = the index-compaction recipe in `reference/authoring-guidance.md` (run 5), no fan-out needed. Also grep the corpus for anything RETIRED that month — retirement-not-propagated is the dominant rot class (run 6: one retired gate live-voiced in 6 files).

Axis 4's mechanical lint is scripted: run `scripts/lint-skill-scripts.sh [SKILLS_ROOT]` (shellcheck + shfmt + rg-as-command audit across all skill `.sh`); the Axis-4 agent then judges only captain-obvious comments.

The axes overlap by design (axes 3/5/7 all touch skills↔memory↔repo) → the same `file:line` will surface in several tables. That redundancy is the point — it cross-checks. Do NOT collapse the axis set to avoid it.

### Phase 1.5 — Consolidate

Merge the axis tables into one, deduped by `file:line`. On a verdict conflict for the same finding, **the more conservative verdict wins**: KEEP-BOTH beats DUP-COLLAPSE, UNVERIFIED beats STALE. This is the single source of truth Phase 2 acts on.

### Phase 2 — Fix

Apply findings under the rules in `reference/authoring-guidance.md` — **read it before editing**. It holds the KEEP-BOTH heuristics, the per-verdict action map, the **caveman-for-files** rule (principles yes, grammar no), the **token-efficiency lens** (long SKILL.md = relocate detail, not delete; emoji = verdict, keep), and the traps that each cost real time on real runs.

Default KEEP-BOTH + add cross-pointers both ways. Collapse only a true verbatim dup where one side is canonical AND nothing is lost. Shrink-to-pointer ONLY after grepping the target confirms it holds every dropped fact. **UNVERIFIED rows are not fixed** — you (the orchestrator, who can grep the repo / kubectl the cluster a read-only finder could not) verify them, then treat as STALE or OK; never auto-edit on an unverified claim.

## Gates (mandatory)

- **Dual peer-review**: review the CHANGES (losslessness) AND the PLAN; fold both.
- **Lossless gate** after any relocate / shrink-to-pointer: `scripts/lossless-verify.sh OLD NEW...` confirms no SHA/command/port/flag/filename dropped + sweeps for subagent tag-leaks (`scripts/tag-leak-sweep.sh`). Don't trust an agent's self-check (trap table: `reference/authoring-guidance.md`).
- **Peer static pre-commit review** (opposite-family reviewer via `peer-reviewed-implementation/scripts/reviewer-peer`) on the as-built diff — this is the TRUTH gate: lossless-verify checks token PRESENCE, not truth; a fix-agent can resurrect a refuted claim only a diff-vs-repo review catches. But VERIFY its findings before acting — reviewers have produced false CRITICALs from misread context. Dated incidents behind both rules: `reference/authoring-guidance.md` traps + `[[reference_review_invariants]]`.
- **chezmoi**: the memory dir IS chezmoi-tracked (`dot_claude/private_projects/.../memory/`). `chezmoi re-add` EXPLICIT files only — never `add -A`; status carries unrelated drift. Confirm source `git status` shows only your files before commit. Deleted memory files → `chezmoi forget --force`. Route the sync through `/chezmoi-sync`.

## Output

Produce: (1) the consolidated findings table, (2) a one-line-per-change summary of what was edited and why nothing was lost, (3) the commit SHA(s). Append a dated run line to memory `[[reference_kb_hygiene_review]]` (see its "Run 1 — 2026-06-01" entry for the shape: SHAs, file count, agent count, forced-delete count).

## Scripts

| Script | Use |
|---|---|
| `scripts/index-integrity.sh [MEMORY_DIR]` | Read-only. Axis 1 mechanics: orphans, dangling index links, broken `[[wiki-links]]`. Exit 1 if orphans/dangling. A link resolves against a filename stem or a frontmatter `name:` slug, because files use underscores and slugs use hyphens. It skips code spans and fenced blocks, and reads `name:` only inside the frontmatter delimiters. |
| `scripts/tests/test-index-integrity.sh [SCRIPT]` | Checks both link spellings, an anchored link, code-span and fenced-block links, a genuinely absent link, an orphan, and a dangling link. Takes the script under test as its first argument, so an older copy shows which checks it fails. Run it after editing the resolver. |
| `scripts/skill-sizes.sh [ROOT] [THRESH]` | Read-only. Live SKILL.md word counts; flags FAT (>THRESH, default 1000) relocate candidates. Token-efficiency lens — never hardcode counts. |
| `scripts/lossless-verify.sh OLD NEW...` | Phase-2 gate. Extracts SHAs/commands/ports/flags/filenames from OLD, confirms each survives in NEW; sweeps NEW for tag-leaks. Exit 1 on LOST/leak. |
| `scripts/tag-leak-sweep.sh [PATH...]` | Sweep for leaked subagent tool-call tags (`</content>`, `</invoke>`). Run on subagent-written files. Exit 1 if found. |
| `scripts/lint-skill-scripts.sh [ROOT]` | Axis 4 mechanics: shellcheck + shfmt + rg-as-command audit across all skill `.sh`. Exit 1 on any lint/format/rg issue. |

All `set -euo pipefail`, `shellcheck`/`shfmt` clean. grep/sed/find only — `rg` is a shell function in this env, absent from non-interactive script PATH.

## Pointers

- `prompts/axis-prompts.md` — the 8 read-only find-agent prompts (shared preamble + per-axis block; axis 8 overrides the preamble output contract).
- `reference/authoring-guidance.md` — caveman-for-files, token-efficiency lens, KEEP-BOTH heuristics, verdict→action map, the traps.
- `scripts/` — see § Scripts (index-integrity, skill-sizes, lossless-verify, tag-leak-sweep, lint-skill-scripts, tests/).
- Memory `[[reference_kb_hygiene_review]]` — run history + spec origin (run 1: 2026-06-01).
