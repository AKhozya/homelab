---
name: comment-sweep
description: "Use before committing a batch, opening a PR, or when asked to clean up comments in any repo/language. Applies the CLAUDE.md comment bar — a comment earns its place only by naming a coupling, constraint, gotcha, or rejected alternative. Cuts restatements, stale narration, JSDoc that repeats the function name, and internal-skill jargon. Protects commented-out code and section banners. Verifies every claim it writes."
user-invocable: true
---

# Comment sweep

Judgement work, not pattern matching. A regex cannot tell `// Rate limit on first item only`
(a policy statement — keep) from `// Create streaming state` (noise — cut); both overlap
their next line's identifiers. Read the code, then decide per comment.

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

- "this is the only writer of X" → `rg` for every writer.
- "callers always pass converted HTML" → read every call site.
- "50MB is Telegram's ceiling" → check. (It is not; the Bot API download limit is 20MB.
  This exact claim was caught mid-sweep on 2026-07-29.)
- "entries before vX had no field" → `git log -S` for when the field landed, or drop the
  version and state the guard's purpose.

If you cannot verify it in under a minute, write the weaker true statement.

### Where to check, by claim type

Nearly every claim has an authority on this machine. Reach for it before weakening the
statement — a whole sweep's worth of "unverifiable" items resolved this way on 2026-08-07.

| Claim | Authority |
|---|---|
| A platform or API limit | the installed types' docstrings, not the vendor's website — `@grammyjs/types` carries the Bot API's own wording, and a test can gate the constant against it |
| An SDK symbol or behaviour | `sdk.d.ts` for the surface **and** `sdk.mjs` for use. A table the SDK exports but never reads means the choice belongs to the consumer — that finding rewrote a comment that had asserted CLI behaviour |
| Strings a compiled CLI prints | `grep` the shipped binary. It shows which messages are terminal and which are notices; it does **not** show control flow, so do not upgrade the claim to "never thrown" |
| A cited `node_modules` line | open it. All four in one repo were still exact, so these earn their keep |
| A commit SHA in a comment | `git cat-file -t`, then read the subject and confirm it matches the claim it supports |
| An in-repo `file.ts:NN` | assume it has rotted. A reformat moved one call three lines and no test noticed |
| A deployment or infra coupling | the sibling repo checkout (deployment manifests, the chezmoi source), never memory |
| A vendored pin (tag, revision, checksum) | the vendor's API. A tag can move; a published checksum settles it |

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
   itself, is any sentence over 25 words, does any assert what step 4 did not check. Three
   separate passes were needed on 2026-08-07 (code comments, then Markdown, then sentence
   length), each finding breaches of the bar the sweep had just applied to everyone else.
   A sweep that exempts its own output is not a sweep.
7. **Never write a command into a doc without running it.** Docs written during a sweep are
   where unrun commands get in. One `tokei` invocation shipped next to a line count it did
   not produce — the flags were close enough to look right and off by a whole directory.
8. Report kept/cut counts per file, and list anything you deliberately left for the owner
   to decide.

## Gotchas

A `python3 - <<'PY'` heredoc containing the word "Truncate" trips the safe-bash hook's
SQL `TRUNCATE` rule. Use the Edit tool for those files.

**Punctuation inside a quoted program.** A comment living inside a single-quoted `awk` or
`sed` program is shell text, not comment text. Adding an apostrophe to it terminates the
quote and breaks the script — `file's` did exactly that to `check-sops-encrypted.sh` on
2026-08-07, and only the CI gate caught it. Rephrase to avoid the apostrophe rather than
escaping it.

**A comment in a pod template rolls the workload.** In Kubernetes, an `initContainer`
`command: |` script is part of the pod template, so editing a comment inside it changes the
template hash and the Deployment restarts on the next reconcile. Five apps rolled off one
comment sweep on 2026-08-07. Say so before the sweep lands — free in git is not free in the
cluster. Comments in a ConfigMap payload or a CronJob template cost nothing; they apply on
the next run.

**Do not hand-roll the alert check afterwards.** `_shared/check-alerts.sh` already queries
VMAlert *and* Alertmanager and flags a failed fetch instead of returning a clean empty list.
A one-off `wget` inside the VMSingle pod returns nothing when it fails, `jq` exits 0 on the
empty input, and the sweep looks like it fired no alerts. Measured 2026-08-07: the one-off
reported clean while four alerts were firing.
