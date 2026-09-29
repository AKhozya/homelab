# KB Hygiene — read-only find-agent prompts

8 axes, one read-only agent each (axis 8 = memory-corpus runs). Dispatch in parallel. Each agent makes **NO edits** — it returns findings only. To run an axis: paste the **Shared preamble** then that axis's block into the agent prompt. Fill every placeholder first, with `$HOME` expanded: the agents' Read tool needs absolute paths.

| Placeholder | Value |
|---|---|
| `{REPO_ROOT}` | the repo's absolute path, e.g. `$HOME/source-code/homelab` |
| `{MEMORY_DIR}` | the repo's Claude Code memory dir, `$HOME/.claude/projects/<key>/memory`, where `<key>` is `{REPO_ROOT}` with every character other than a letter or digit replaced by `-`. Check that the directory exists before dispatch |
| `{PLANS_DIR}` | the repo's plan/spec dir: `{REPO_ROOT}/docs/plans` in homelab; the superpowers default is `docs/superpowers/` |
| `{SKILLS_ROOT}` | `$HOME/.agents/skills` |
| `{GLOBAL_CLAUDE_MD}` | `$HOME/.claude/CLAUDE.md` |

---

## Shared preamble (prepend to EVERY axis)

```
You are a READ-ONLY KB-hygiene reviewer. Make NO edits, NO writes, NO commits.
Output one markdown table, nothing else (EXCEPTION: axis 8 defines its own two-table output + RELOCATE verdict — its block overrides this preamble):

  | file:line | finding | verdict | note |

verdict ∈ { DUP-COLLAPSE, KEEP-BOTH, STALE, UNVERIFIED, DRIFT, CUT, TIGHTEN, OK }

Rules:
- Bias KEEP-BOTH. Overlap is usually complementary by design: skill = how-to (canonical),
  memory/gotcha = why + SHA + history, repo-doc = authoritative mechanics. Flag DUP-COLLAPSE
  ONLY for a TRUE verbatim dup where one side is canonical AND nothing is lost by dropping the other.
- NEVER propose deleting a why, a date, a commit SHA, a repro command, or a gotcha. lean ≠ lossy.
- Cite exact file:line. Quote the overlapping span so a fixer can verify without re-reading.
- "stale" is a claim that contradicts current repo/cluster state. If you cannot confirm against a
  source you can read, mark UNVERIFIED — do not assert STALE on a guess.
- You are FINDING, not fixing. No rewrites, no patches. Verdict + one-line note per row.
```

---

## Axis 1 — within-memory dup + MEMORY.md index integrity

FIRST run `scripts/index-integrity.sh {MEMORY_DIR}` — it deterministically reports orphans, dangling index links, and broken `[[wiki-links]]`. Hand its output to the agent; do NOT redo those mechanical checks by hand.

```
Scope: every file in {MEMORY_DIR}/ plus {MEMORY_DIR}/MEMORY.md, PLUS the index-integrity.sh output.
Find (the SEMANTIC work the script can't do):
- Two memory files (or two sections) stating the same fact — flag the weaker copy KEEP-BOTH or
  DUP-COLLAPSE per the rules. Same topic split across files that should cross-link = note it.
- Count drift: index claims "14 apps" / "N agents" vs reality — verify against the repo.
- Triage the script's broken-link list: a [[link]] to a not-yet-written file is an intentional TODO,
  not a bug; a slug that SHOULD resolve to an existing file (e.g. dash-vs-underscore drift) IS a fix.
```

## Axis 2 — memory/gotchas stale (claim vs live truth)

```
Scope: {MEMORY_DIR}/*.md (especially gotchas.md and project_* files with version/SHA/count claims).
Find: each concrete claim — version pins, commit SHAs, "N apps / N policies / N NetworkPolicies",
"X is deployed / disabled / superseded" — checked against the live repo ({REPO_ROOT}) and, where you
can read it, the cluster.
Verdict STALE only when you confirmed the contradiction against a readable source; else UNVERIFIED.
Trap — feature-shipped: a memory file may say a feature is planned/blocked when it has since shipped
(CSP F-22, HA OIDC F-43 were both LIVE while a note still read "blocked"). Grep the repo for the
manifest before calling a feature-claim stale in EITHER direction.
```

## Axis 3 — memory ↔ skills (.md / .sh)

```
Scope: {MEMORY_DIR}/*.md  ×  {SKILLS_ROOT}/**/ (SKILL.md and scripts/*.sh).
Find: a skill's SKILL.md and a memory file carrying the same operational detail. Decide which is
canonical (skill = the how-to you execute; memory = why + history). KEEP-BOTH the default; flag a
missing cross-pointer (skill should `[[link]]` the memory's why; memory should name the skill).
Trap — complementary-by-design: a 2026-05-27 skill-drift fix deliberately duplicated some how-to into
SKILL.md so the skill is self-contained. Mirrored content is NOT automatically a dup — DUP-COLLAPSE
only if one side is verbatim-redundant AND loses nothing.
```

## Axis 4 — skill .sh captain-obvious comments

```
Scope: {SKILLS_ROOT}/**/*.sh and {SKILLS_ROOT}/_shared/*.sh.
Find: comments that restate the code ("# loop over files", "# set variable x"). Verdict CUT or TIGHTEN.
KEEP any comment carrying a why, a gotcha, an exit-code contract, a SIGPIPE/pipefail note, or a SHA.
Trap — numbered-step symmetry: cutting "# 1. X" while "# 2." / "# 3." remain orphans them. Check the
whole numbered block before flagging any one line.
Trap — _shared usage: do NOT conclude "_shared is unused" from "few .sh source other .sh" — helpers are
invoked from SKILL.md as `bash _shared/x.sh`, not sourced. Grep SKILL.md before asserting a gap.
```

## Axis 5 — memory/gotchas ↔ repo truth

```
Scope: {MEMORY_DIR}/*.md  ×  repo authoritative docs: {REPO_ROOT}/docs/, both CLAUDE.md
(global {GLOBAL_CLAUDE_MD} and {REPO_ROOT}/CLAUDE.md), {REPO_ROOT}/.claude/review-invariants.md.
Find: a fact maintained in BOTH a memory file and an authoritative repo doc. Repo doc wins (it is the
source of truth, version-controlled with the code); the memory copy is drift-risk. Prefer shrink the
memory copy to a pointer — BUT only if the repo doc holds every fact the memory copy holds.
Trap — memory-only facts: the memory copy may carry a detail the repo doc lacks (e.g. prune_nas_file /
prune_nas_dir not in BACKUP_STRATEGY.md). Grep the repo target for EACH dropped fact before recommending
shrink-to-pointer; if any fact is memory-only, KEEP-BOTH + add the fact to the repo doc instead.
```

## Axis 6 — skills ↔ CLAUDE.md + skill specs

```
Scope: {SKILLS_ROOT}/**/SKILL.md  ×  both CLAUDE.md (global {GLOBAL_CLAUDE_MD} + repo {REPO_ROOT}/CLAUDE.md)  ×  {PLANS_DIR} (plans+specs).
Find:
- SKILL.md that re-declares a CLAUDE.md invariant. A skill that OPERATIONALIZES an invariant (turns a
  rule into runnable steps) = KEEP. A skill that merely RE-STATES it verbatim = DUP-COLLAPSE to a pointer.
- skill design specs in {PLANS_DIR} that have shipped AND been surpassed by the live skill =
  archivable (move to docs/archive/, fix the moved file's relative links).
Trap — repo-root vs relative link on move: a repo-root link such as docs/plans/X breaks when both files move
to archive/ together (it is not a ../ relative). Flag the link to fix in the moved file.
```

## Axis 7 — gotchas ↔ skills

```
Scope: {MEMORY_DIR}/gotchas.md and gotcha_*.md  ×  {SKILLS_ROOT}/**/ (SKILL.md + scripts).
This is the most operational memory and the most echoed into skills — the user flagged it explicitly,
do NOT skip it.
Find: an operational gotcha living in both a gotcha file and a skill. Canonical = the skill if it is the
execution path; the gotcha keeps the why + SHA + incident date. KEEP-BOTH + bidirectional pointer is the
usual answer (skill body → `[[gotchas]]`; gotcha → names the skill). DUP-COLLAPSE only on verbatim echo
where the gotcha adds no why/SHA/date the skill lacks.
```

## Axis 8 — prose bloat + doesn't-belong (memory-corpus runs; validated run 6, 2026-07-13)

```
OVERRIDES the shared preamble output contract. Output TWO tables: A (per-file): | file | bytes | prose-density verdict | est. safe savings | dominant problem |
B (findings): | file:line | finding | verdict | note | — verdict ∈ { TIGHTEN, CUT, RELOCATE, OK }
Scope: ALL of {MEMORY_DIR}/*.md; read the largest files IN FULL.
- Savings come ONLY from: session-journal narrative ("then I tried X..."), restated context, duplicated
  in-file summaries, discarded-plan detail, verbose-compressible-to-telegraphic. NEVER count a why, date,
  SHA, repro, gotcha, or decision-rationale as "prose".
- RELOCATE = doesn't belong in agent memory: (a) facts the repo records (changelog restatements vs
  HOMELAB_HISTORY — cite the anchor), (b) closed/dead work with no reusable lesson, (c) generic knowledge
  the agent has anyway (release-note summaries). Note the destination (repo doc / git history / nowhere).
- Telegraphic phrasing is fine for pure-recall notes; instruction-like decision rules stay full-grammar.
Run-6 base rate: most files verdict OK (corpus is disciplined); big wins concentrate in 1-3
session-journal project files. Expect that shape — don't force findings.
```
