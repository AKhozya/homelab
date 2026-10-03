---
name: comment-sweep
description: "Use before committing a batch, opening a PR, or when asked to clean up comments in any repo/language. Applies the CLAUDE.md comment bar — a comment earns its place only by naming a coupling, constraint, gotcha, or rejected alternative. Cuts restatements, stale narration, JSDoc that repeats the function name, and internal-skill jargon. Protects commented-out code and section banners. Verifies every claim it writes."
user-invocable: true
---

# Comment sweep

Judgement work, not pattern matching. Read the code, then decide per comment.
If you need the reason a regex cannot do this, read reference-gotchas.md § "Why a regex cannot judge a comment".

## The bar

A comment earns its place **only** by naming what the code cannot show:

| Earns its place | Cut it |
|---|---|
| A coupling (`lastContent caches RAW markdown; the edit path re-converts`) | Restates the line (`// Create abort controller`) |
| A constraint (`xhigh + thinking disabled 400s the API`) | Explains a standard API (`// Escape HTML special characters` on `escapeHtml`) |
| A gotcha (`HTML tags inflate past the limit — shrink until it fits`) | Defends a choice nobody would question |
| An alternative tried and rejected (`NO break — Claude continues generating`) | Numbered step narration (`// 3. Rate limit check`) |
| A probe result, with its date | Changelog narration (`transcription was removed with the OpenAI dep`) |
| An intentionally-empty `catch` marker | A duplicate of a comment 10 lines up |

Length follows the constraint, not the change. One-line coupling → one line.

## Never cut

- **Commented-out code.** Not in a sweep, not while "actioning findings", not when it
  looks obviously dead. Surface it as an optional list instead.
- **Correct section banners** (`// ============== Rate Limiter ==============`).
  A numbered scheme that has gone stale (starts at 2, or repeats a number) is narration,
  not a banner — that one goes.
- **The why, the gotcha, the repro command, dates, commit SHAs.** Cutting substance to
  look terse is the opposite failure.

## Also fix while you are in there

- **Internal-skill jargon in committed files** (`ponytail:`, `caveman`, skill names).
  Other devs and AI reviewers do not know them. Use `Trade-off:`, `Note:`, or plain prose.
  The skill *behaviours* still apply — only the labels are banned.
- **Misplaced doc comments.** A JSDoc describing function B sitting above function A is a
  real defect, not a style nit. Move it.
- **Comments that are now false.** A stale claim is worse than no claim.

## Anything you WRITE must be verified first

The failure mode of this sweep is replacing a harmless restatement with a confident
wrong claim. Before writing a comment that asserts a fact:

Before you write such a comment, read reference-claim-sources.md to find the check for that kind of claim.
A string found in a compiled binary does not show control flow, so do not claim "never thrown" from it.
Check a deployment or infra coupling against the sibling repo checkout, never against memory.

If you cannot verify it in under a minute, write the weaker true statement.

## Procedure

1. Scope it: files in the diff, or the whole tree if asked. `rg -c '^\s*(//|/\*|\*)'`
   per file to see where the density is.
2. Read each file fully. Density that tracks complexity is fine — a security parser
   *should* be comment-heavy; a handler that is mostly API plumbing should not.
3. Edit. Prefer many small exact-match edits over a rewrite.
4. Run the check that would catch what you touched — typecheck and tests. Comments do not
   change behaviour, so a red result means you cut into code. A config repo has neither:
   there, render the tree before and after and diff it with comments ignored —
   `_shared/kustomize-render-diff.sh semantic <old-path> <new-path>` for Kustomize. It must
   report SEMANTICALLY IDENTICAL on every root you did not deliberately correct. Run it per
   root, from a worktree at the pre-sweep commit.
5. Re-scan for what you missed: `rg -n '^\s*// (Create|Build|Send|Get|Set|Check|Update|Delete|Clean|Start|Save|Load|Parse|Handle|Process|Add|Remove|Mark|Show|Skip|Extract|Format|Convert|Return|Store|Wait)\b'`.
   Survivors should each have a reason.
6. **Hold your own additions to the same bar, before you commit.** This is not optional and
   it is not the reviewer's job. Extract every line you added — `git diff | grep '^+'` —
   and re-read it as if someone else wrote it: does each earn its place, does any restate
   itself, does any sentence carry more than one idea, does any assert what step 4 did not check.
   Do not enforce a word cap. If a sentence exceeds 40 words, check whether it holds more than one idea.
   A sweep that exempts its own output is not a sweep.
7. **Never write a command into a doc without running it.** Docs written during a sweep are
   where unrun commands get in.
8. Report kept/cut counts per file, and list anything you deliberately left for the owner
   to decide.

## Gotchas

If the safe-bash hook refuses a patch script, or a comment sits inside a quoted `awk` or `sed` program, read reference-gotchas.md, section "Hook and quoting traps".
If a comment sits inside a single-quoted `awk` or `sed` program, do not add an apostrophe to it: rephrase instead of escaping.

**A comment in a pod template rolls the workload.** In Kubernetes, an `initContainer`
`command: |` script is part of the pod template, so editing a comment inside it changes the
template hash and the Deployment restarts on the next reconcile. Say so before the sweep lands — free in git is not free in the
cluster.

**Do not hand-roll the alert check afterwards.** `_shared/check-alerts.sh` already queries
VMAlert *and* Alertmanager and flags a failed fetch instead of returning a clean empty list.

If you need the incidents behind the procedure and these gotchas, or which templates cost nothing to edit, read reference-gotchas.md § "Incidents and measurements".
