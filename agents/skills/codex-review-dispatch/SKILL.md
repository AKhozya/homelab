---
name: codex-review-dispatch
description: Use before you ask Codex to review a diff, a plan or a doc through codex-review.sh, and before you edit codex-review.sh. Covers the one review file to build, the facts and writing rules to inline in the prompt, what the script guarantees, and why exit 0 means only that a valid verdict arrived.
---

# Dispatch a Codex review

Dispatch every Codex review through one script:

```bash
~/.agents/skills/_shared/codex-review.sh --diff <file> --prompt <file>
```

Its exit code reports whether the review produced a valid verdict, never what the verdict says. The round table in `~/.codex/AGENTS.md` (heading "Round table") decides whether the round permits a commit.

| Exit | Means | Then |
| --- | --- | --- |
| 0 | the reply opens with a known `VERDICT:` line | read the verdict and apply the round table |
| 2 | usage or environment error; the script stops before dispatch | fix the call |
| 3 | Codex failed, refused, or replied off-format | apply the no-verdict rules that follow the round table in `~/.codex/AGENTS.md` |
| 124 | the deadline expired, or the hard kill fired (the script maps 137 to 124) | as for exit 3 |

## What the script guarantees

| Guarantee | If it is missing |
| --- | --- |
| sweeps stale brokers first | the turn ends after minutes without a verdict or an error |
| closes stdin | the run hangs, because the harness pipe never ends |
| `--sandbox read-only` | an unexpected command can change the checkout |
| supplies the one permitted `cat` | Codex may refuse, and call a verdict a fabrication |
| a deadline, then a hard kill | a stuck run blocks the turn |
| keeps the transcript | a dead run and a slow run look the same |
| exit 3 if a completed run's reply lacks a valid verdict | a failed review reads as a clean one |

The comment next to each guarantee's code in the script gives its reason. If you edit the script, run `~/.agents/skills/_shared/codex-review-selfcheck.sh` afterwards.

The script appends the read contract to your prompt: one permitted `cat` of the review file, and the `VERDICT:` line with its allowed values. If your own prompt forbids every command, it also forbids that `cat`, and Codex may refuse.

## What the script cannot decide

1. **Build one review file.**

   | If the change is | Put in the file |
   | --- | --- |
   | committed | `git diff <base>...<head>` (three dots: from the merge base, so later commits on the base do not show as removals), the commit list (`git log --oneline <base>..<head>`) and the stat (`git diff --stat <base>...<head>`) |
   | not yet committed | follow the steps below the table |
   | a plan or a doc | the document, or its diff |

   If you have not committed the change, build the review file in a private index, so the shared index, and anything another session stages in it, stays as it is:

   1. Read `git diff HEAD -- <your paths>` and each untracked file in your paths (`git status --short --untracked-files=all -- <your paths>` lists each with `??`). If a command fails, or shows a change that is not yours (a hunk, a mode change, a rename or a binary file), stop and ask.
   2. Build the file in one shell call: `(export GIT_INDEX_FILE=<scratch dir>/review.index; git read-tree HEAD && git add -- <your paths> && git diff --cached --patch-with-stat -- <your paths> > <review file>)`. The subshell keeps the setting out of your shell and returns the status of the chain. If it exits non-zero, or the repository has no commit yet, stop and ask.
   3. Read the review file. If it shows a change that is not yours, stop and ask. If one of your changes is missing, add its path to `<your paths>` and restart at step 1. If it shows all your changes and only yours, dispatch it.

   Keep every review to that one file. If Codex explores beyond it, its process can exit partway through the run. Ask Codex to name, in its first finding, each part of the file it did not receive. A long file can reach Codex with part of the middle missing.

   | If | Then |
   | --- | --- |
   | the change is too long to read in one pass | split it and dispatch each part as its own one-file review |
   | Codex reports an incomplete file | dispatch each part it did not receive as its own review. If Codex cannot name every missing part, split the whole file and review each part |
   | a review has several parts | collect every part's verdict, then apply the round table once, to the combined findings |
2. **Inline the verified facts** in the prompt, such as gate results and probe outcomes, so Codex re-derives nothing. Say which gates already passed.
3. **If the review covers a plan or a change of meaning**, inline the list of readers from the plan's change-of-meaning section. Codex sees only the file you give it.
4. **Inline the writing lens** from `~/.codex/AGENTS.md` (heading "Writing lens for reviews") and ask Codex to flag each violation as a finding. The lens in that file addresses an author, so the prompt must ask the reviewer to apply the lens. Do not run a separate writing pass instead: you can forget that step. Do not ask for a per-sentence word cap: the sentence-length rule in `~/.codex/AGENTS.md` forbids one.
5. **Scope each re-review** to the change since the last round. Include each open finding with its disposition and the current text of the lines it cites.
