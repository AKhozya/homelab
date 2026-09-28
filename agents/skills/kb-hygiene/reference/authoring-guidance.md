# KB Hygiene — authoring guidance (Phase 2 fix rules)

Read before editing. These are the rules for fixing what Phase 1 found without quality loss.

## Verdict → action

The finder verdicts map to these fixes. Every action preserves substance (why/SHA/date/repro/gotcha).

| Verdict | Action |
|---|---|
| KEEP-BOTH | Leave both copies; add a cross-pointer each way. Default outcome. |
| DUP-COLLAPSE | Drop the redundant copy ONLY after confirming it's verbatim and the surviving canonical copy loses nothing. |
| DRIFT | Repo/canonical doc wins. Shrink the memory copy to a pointer — but only after grepping the target holds every fact (else add the missing fact to the canonical doc, then shrink). |
| STALE | Correct the claim to current truth (keep the old value + date as history if it explains a why). |
| UNVERIFIED | Do NOT edit. Orchestrator verifies, then it becomes STALE or OK. |
| CUT | Delete — captain-obvious comment / pure restatement only. Never a why/SHA/gotcha. |
| TIGHTEN | Condense in place; keep every load-bearing fact. |
| OK | No-op. |

## KEEP-BOTH heuristics

- **KEEP-BOTH is the default.** Roles: skill = how-to (canonical), memory/gotcha = why + SHA + history, repo-doc = authoritative mechanics. Collapse only a TRUE verbatim dup where one side is canonical AND nothing is lost.
- **Shrink-to-pointer only after grepping the target.** Before replacing a memory copy with "see X", grep X and confirm it holds EVERY fact you're about to drop. A dropped fact may be memory-only (e.g. `prune_nas_file`/`prune_nas_dir` were NOT in BACKUP_STRATEGY.md) — if so, add it to the canonical doc first, then shrink.
- **Cross-pointer both ways; trim only the redundant copy.** Add skill→memory and memory→skill links. Never trim a why or a SHA — only the restated mechanics.

## caveman-for-files (principles yes, grammar no)

The chat-mode caveman compression does NOT transfer wholesale to instruction files.

- **Caveman GRAMMAR — NO** for SKILL.md / CLAUDE.md / review-invariants / any control-flow file. Dropped articles + fragments create ambiguity, and ambiguity = re-derivation on every read × cluster blast radius. Global CLAUDE.md already states it: "Caveman governs chat, not files."
- **Caveman PRINCIPLES — YES.** Anti-fluff, lean structure, tables over prose, no decorative emoji, keep substance. "Codify carefully" beats "caveman the files."
- The real savings is **structural** (relocate detail, tables, cut restatement), not grammatical. Pure-recall notes (gotchas quick-refs) tolerate telegraphic phrasing; instruction/decision files do not.

## token-efficiency lens (these files load into context repeatedly)

- **Emoji = verdict, KEEP.** In skill scripts every emoji is a parsed verdict token in echo/printf output (`GREEN ✅`, `INFRA-RED ⚙️`, `CONTENT-RED ❌`). It is load-bearing, not decoration — do not strip it. There is no decorative emoji to remove here; the corpus is already disciplined.
- **The real lever = long SKILL.md.** A SKILL.md loads in full on every fire → fat ones are where tokens hide. Run `scripts/skill-sizes.sh` for LIVE word counts (never hardcode them — they drift; the 2026-06-01 leaning pass already invalidated the old numbers). Lean shape = thin SKILL.md (when-to-fire + what-to-run + pointers) → relocate detail to `scripts/*.sh` (executed, never loaded) or `reference-*.md` / `reference/*.md` (loaded on demand).
- **Relocate, do NOT delete the how-to.** Moving detail out of SKILL.md into a reference or script is a token win with zero information loss. Cutting the how-to is loss. Know which you're doing.

## Traps (each cost real time on a real run)

| Trap | What bit | Guard |
|---|---|---|
| _shared-count false alarm | "only 2/46 .sh source _shared" measured the wrong thing — helpers run as `bash _shared/x.sh` from SKILL.md, not `.sh`-sources-`.sh` | grep SKILL.md for the invocation before asserting a gap |
| numbered-step cut | cutting `# 1. X` while `# 2.`/`# 3.` remain orphans them | check the whole numbered block's symmetry before cutting any one line |
| chezmoi-diff inversion | `chezmoi diff` shows SOURCE state; reviewer misread "source-lacks-pointer" as "this edit removes the pointer" | verify the LIVE file directly, not the diff direction |
| ls-from-wrong-tree | a worktree `git mv` moves files only in the worktree; `ls` from the main tree shows them unmoved → false "files missing" | run `ls`/`git status` from the tree you actually edited in |
| repo-root vs relative link on move | a repo-root link such as `docs/plans/X` breaks when both files move to `archive/` together (it is not a `../` relative) | fix the link inside the moved file |
| subagent Write tag-leak (2026-06-02) | a dispatched agent's tool-call closing tags (`</content>`, `</invoke>`) leak into a written file's tail; the lossless token-check is BLIND to trailing junk, so the agent's own verify passed | run `scripts/tag-leak-sweep.sh` (or `lossless-verify.sh`, which embeds it) on every subagent-written file before trusting it |
| fix-agent resurrects a refuted claim (2026-07-13, run 6) | an agent MERGING scattered copies of a rule reassembled it WITH a refuted detail (phantom `virsh --timeout` flag the corpus itself had debunked); lossless-verify checks token PRESENCE, not TRUTH, so it passed | peer static diff review against repo truth is the complementary gate (run 6 = Codex) — always run it after fix-agents; it caught what the script can't |
| retirement not propagated (2026-07-13, run 6) | a retired gate/procedure stayed live-voiced in 6 files — incl. a "do NOT fix" advice whose predicted failure had already happened AND been fixed, and a recipe for a command now forbidden | on ANY retirement event, same-day `grep -ril <name>` across memory+skills; and in each hygiene pass, grep the corpus for every retirement the repo records that month |
| retired name in a SCRIPT data table (2026-07-16, run 8) | finders swept `.md` bodies but cluster-roll.sh's tier MAP still rolled removed `trivy-operator` — a `die` on missing selector would abort every full roll; only the Codex diff-vs-repo review caught it | the retirement grep covers `*.sh` too (arrays, case arms, host lists are where scripts store facts); lint passes ≠ facts current |
| desc-trim deletes the only copy (2026-07-16, run 8) | a frontmatter description carried a gotcha (Telegram-template miss) that existed NOWHERE in the body — trimming the description would have erased it | before cutting any fact from a description, grep the skill's body+references for it; absent → move it into the body, then trim |

## MEMORY.md index compaction recipe (validated run 5, 2026-07-13: 20.7KB→16.8KB, Codex SHIP)

The index is loaded every session — soft target ≤17.1KB, hard read-limit 24.4KB. When over:
1. **Per-line fact-coverage check BEFORE trimming**: for each line >450B, write the line to a temp file and run `lossless-verify.sh <line-file> <its-topic-file>` — mechanically proves every SHA/command/port/flag already lives in the topic file. Expect false LOSTs: the self-referencing filename (a file never names itself) and formatting variants (`:56634` vs "port 56634", `custom:true` vs `custom: true`) — grep variants before calling a fact index-only.
2. A fact found NOWHERE → relocate to the topic file FIRST, then trim.
3. Trim to a recall hook (~300B): title + date + status + searchable gotcha keywords. Drop narrative + SHAs (they live in the topic file). Never drop the one keyword you'd grep for during an incident.
3a. **Count BYTES, not characters, and assert the cap inside the rewrite script.** `→`, `—`, `×`, `≠` and curly quotes are 3 bytes each in UTF-8, so a character-counted trim under-delivers — two passes on 2026-08-07 missed the target that way. Have the script `sys.exit()` when any rewritten line exceeds the cap: it then writes NOTHING and names the offenders (7 of 27 on that run), instead of silently landing over target. Pick the cap with headroom — a 300B cap landed 6 bytes under a 17,100B target, which the next entry breaks; 290B left 455B.
4. Gate: `lossless-verify.sh OLD-index NEW-index <all-topic-files>` (union coverage) + prose-fact spot-greps + peer diff review.
Bonus finding class: the same fact pinned in index + topic file + repo with 3 DIFFERENT values (claude-telegram image 1.27.8/1.27.4/1.27.13) — version pins in memory ALWAYS drift; point at the authoritative repo file instead. It recurred on 2026-08-07 (index `1.32.0` vs repo `1.32.1`), so treat a version number in memory as a finding on sight.

**A grep COUNT is not evidence. Two ways it lied on 2026-08-07:**
- **Overlap.** 9 job/autogen hits in a dedicated file "proved" two `gotchas.md` topics were duplicates. Reading both texts refuted it — one covers PSS level-change readiness, the other probe validity, sharing one sentence. Collapsing would have deleted a distinct incident record. **Compare texts, never counts, before any DUP-COLLAPSE**, and never presume the dedicated file is canonical: weigh meaning, scope, provenance and freshness.
- **Absence.** `grep -ci "2-phase prune"` returned 0 and looked like proof. A literal string cannot prove a concept is missing — search the concept (`prune: *false`, `prune: *disabled`, `disable.*prune`, `two.stage`) and the synonyms a reviewer would name (`orphan`, `re-adopt`, `inventory`). Then check the OWNING layer: all four skill trees (`~/.agents`, `~/.claude`, `~/.codex`, repo-local) plus every `~/.claude/plugins/cache/*/skills` tree. The concept was genuinely absent from skills but present in the repo's own reviewer rubric under a different trigger — which changed the finding, not confirmed it.

## Gates recap (mandatory — also in SKILL.md)

- Dual peer-review: the CHANGES (losslessness) AND the PLAN; fold both.
- Lossless gate after any relocate / shrink-to-pointer / leaning edit: `scripts/lossless-verify.sh OLD NEW...` — extracts SHAs/commands/ports/flags/filenames from OLD, confirms each survives in NEW, and sweeps NEW for tag-leaks. Don't trust an agent's self-check (this session theirs missed `</content>` leaks; the script caught them).
- Peer static pre-commit review on the diff, then VERIFY its findings (run 1 the reviewer produced 2 false CRITICALs via the chezmoi-diff and ls traps above).
- chezmoi: memory dir is tracked; `re-add` explicit files only, confirm source `git status` is only your files, `forget --force` deleted ones. Route through `/chezmoi-sync`.
