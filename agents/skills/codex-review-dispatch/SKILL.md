---
name: codex-review-dispatch
description: Use before you ask Codex to review a diff, a plan or a doc through codex-review.sh, and before you edit codex-review.sh. Covers the one review file to build, the facts and writing rules to inline in the prompt, what the script guarantees, and why exit 0 means only that a valid verdict arrived.
---

# Dispatch a Codex review

Dispatch every Codex review through one script:

```bash
~/.agents/skills/_shared/codex-review.sh --diff <file> --prompt <file>
```

Its exit code reports whether the review produced a valid verdict, never what the verdict says. Exit 0 means that the reply opens with a known `VERDICT:` line. It does not mean that the round permits a commit. The round table in `~/.codex/AGENTS.md` (heading "Round table") decides that. The rules that follow that table cover a dispatch that returns no verdict.

| Exit | Means | Then |
| --- | --- | --- |
| 0 | a valid verdict arrived | read the verdict and apply the round table |
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
   | not yet committed | before you stage, read `git diff --cached -- <your paths>`: if it holds hunks that are not yours, stop and ask. Staged files in other paths stay out of the review file. Stage your change (new files included), read the staged diff again, then build the file with `git diff --cached -- <your paths>` and `git diff --cached --stat -- <your paths>` |
   | a plan or a doc | the document, or its diff |

   Keep every review to that one file: if Codex explores widely, its process can exit in the middle of the run. Keep the file small enough to read in one pass, because a long file can reach Codex with its middle cut. If the change is too long, split it and dispatch each part as its own one-file review. Collect every part's verdict, then apply the round table once, to the combined findings. Ask Codex to say in its first finding if its read was cut short. If it was, dispatch the unread part as its own review, and combine its findings with the rest before you apply the round table.
2. **Inline the verified facts** in the prompt, such as gate results and probe outcomes, so Codex re-derives nothing. Say which gates already passed.
3. **If the review covers a plan or a change of meaning**, inline the list of readers from the plan's change-of-meaning section. Codex sees only the file you give it.
4. **Inline the writing lens** from `~/.codex/AGENTS.md` (heading "Writing lens for reviews") and ask Codex to flag each violation as a finding. The lens in that file addresses an author, so the prompt must ask the reviewer to apply the lens. Do not run a separate writing pass instead: you can forget that step. Do not ask for a per-sentence word cap: the sentence-length rule in `~/.codex/AGENTS.md` forbids one.
5. **Scope each re-review** to the change since the last round. Include each open finding with its disposition and the current text of the lines it cites.
