---
name: peer-reviewed-implementation
description: Use for non-trivial feature implementation, bug fixes, refactors, or workflow/tooling changes. Enforces worktree isolation, plan-first execution, explicit assumptions and cut corners, research/spikes for unknowns, opposite-agent peer review before and after coding, receiving-code-review handling, focused verification, and commit/push only after review is addressed.
---

# Peer-Reviewed Implementation

Use this for substantive implementation work. Skip for tiny one-line edits,
pure read-only review, or when the user explicitly requests a different
workflow.

## Workflow

1. **Isolate**
   - If touching a git repo, use an existing isolated workspace or create a
     worktree.
   - Do not disturb unrelated dirty changes.

2. **Plan**
   - Write a concise plan.
   - Include assumptions, known cut corners, and unknowns.
   - Identify the smallest checks that would prove the change.

3. **Research and Spike**
   - Read the relevant code and docs before choosing the implementation.
   - Spike only load-bearing unknowns.
   - Update the plan when research changes scope, risk, or file targets.

4. **Pre-Implementation Review**
   - Run `scripts/reviewer-peer --current <current-family> --format json` from
     this skill.
   - Use `high` effort/reasoning for every Claude or Codex plan review. That is the
     `model_reasoning_effort` in `~/.codex/config.toml`, which `codex-review.sh` inherits.
   - Ask the returned reviewer to review the plan, unless it is `self-review`.
   - If the reviewer is unavailable, rate-limited, or explicitly waived by the
     user, do a self-review at `high` and state that substitution.
   - Load the `receiving-code-review` / `receive-review` skill when available.
   - Receive feedback through that discipline: understand, verify, evaluate,
     then act. Do not blindly implement review comments.

5. **Implement**
   - Make the smallest change that satisfies the plan.
   - Reuse existing project patterns and installed tooling.
   - Track deliberate simplifications in the plan or final note.

6. **Verify**
   - Run focused checks first.
   - Broaden checks only when the change touches shared behavior or release
     surfaces.
   - A test written for this change is a claim until a mutant dies: break the line
     it covers with `mutation-testing` (`_shared/mutate.sh`) and require the suite
     to go red.
   - If the change touches a CI gate, run the gate's own step body once per
     branch. Do not read it and reason. A secret-scanning gate passed review on
     2026-08-08 with every fallback branch exiting 0; running each branch found
     them.
     1. Extract: `yq -r '.jobs.<job>.steps[<n>].run' <workflow> > step.sh`.
        Index by job, because a step name repeats across jobs and some steps
        have no name.
     2. Run it under the command GitHub builds, not your login shell. Resolve
        the shell in this order: the step's `shell:`, then `defaults.run.shell`
        on the job, then on the workflow, then the runner default. Then use that
        shell's whole template, because the flags differ and change the exit
        code. Substitute the extracted path for `{0}`.

        | Resolved shell | Command GitHub runs |
        |---|---|
        | none, Linux or macOS runner | `bash -e {0}` |
        | `bash` named explicitly | `bash --noprofile --norc -eo pipefail {0}` |
        | `sh` | `sh -e {0}` |
        | none, Windows runner, or `pwsh` | `pwsh -command ". '{0}'"` |
        | `cmd` | `%ComSpec% /D /E:ON /V:OFF /S /C "CALL "{0}""` |
        | `python` | `python {0}` |

        A named `bash` adds `-o pipefail`, which the default does not. A gate
        whose body pipes can pass one way and fail the other.
     3. Supply the step's `env:` values, once per branch.
     4. Assert the exit code. Do not assert the message.
   - This substitutes extracted text for the program CI runs. Check each row
     before trusting the result.

     | If the step has | then | remedy |
     |---|---|---|
     | `${{ }}` inside `run:` | GitHub substitutes before the shell sees it | move the value into `env:` |
     | `working-directory`, on the step or inherited from `defaults.run` | the body runs elsewhere | `cd` there first |
     | a `shell:` key | the interpreter and flags differ | invoke that shell |
     | a matrix value | one body becomes many programs | drive each combination |
     | job or workflow `env:` | those values are absent | add them to the branch env |
     | `$GITHUB_PATH` or `$GITHUB_ENV` from an earlier step | inherited state is absent | reproduce it, or verify in CI |
     | a step or job `if:` | the step may never run | check the condition separately |
     | `continue-on-error` | the exit code still shows the command outcome, but this step's failure does not fail the job | if this step must gate the job, drop the flag |

7. **Code Review**
   - Re-run `scripts/reviewer-peer --current <current-family> --format json`.
   - Use `high` effort/reasoning for every Claude or Codex code review.
   - Ask the returned reviewer to review the actual diff before commit/push,
     unless it is `self-review`.
   - For Codex diff reviews, dispatch through
     `_shared/codex-review.sh --diff <file> --prompt <file>`. Write the prompt
     and pre-build the diff. The script guarantees:

     | Guarantee | If it is missing |
     |---|---|
     | sweeps stale brokers first | the turn dies silently after minutes |
     | closes stdin | the run hangs, because the harness pipe never ends |
     | `--sandbox read-only` | an unexpected command can mutate the checkout |
     | supplies the one permitted `cat` | Codex may refuse, calling a verdict fabrication |
     | deadline, then a hard kill | a stuck run blocks the turn |
     | keeps the transcript | a dead run and a slow run look the same |
     | exit 3 if no verdict | a failed review reads as a clean one |

     Its exit code reports whether the review ran, never what it concluded.
     If you edit the script, run `_shared/codex-review-selfcheck.sh`.
   - Process findings through `receiving-code-review` / `receive-review`.
   - Severity decides whether you may commit. The round count decides when to escalate. The full
     table is in the repo's `AGENTS.md` or `~/.claude/CLAUDE.md` § Code review:

     | Round returns | Rounds 1-5 | Round 6 |
     |---|---|---|
     | CRITICAL, HIGH or MEDIUM | fix, then re-review | do not commit; give the open findings to the user |
     | only LOW or NIT, first in a row | fix, then re-review | fix, then commit |
     | only LOW or NIT, second in a row | fix, then commit | fix, then commit |
     | nothing | commit | commit |

     Document any accepted residual risk.

8. **Commit and Push**
   - Commit only after verification and review findings are addressed.
   - Push only when the user asked for push or the repo workflow requires it.

## Agent-Neutral Reading

Older skills may say `Claude`, `Claude Code`, or `Codex` even when the current
agent is different. Treat those as adapter names unless the instruction depends
on a specific CLI, backend, transcript source, auth path, or file location.

For peer review, independence matters. Resolve it with
`scripts/reviewer-peer`; use the returned `effort` value. If it returns
`self-review`, state that fallback.

## No-Drift Rule

Put reusable workflows in shared skills, preferably `~/.agents/skills`. Do not
maintain separate Claude and Codex copies. If duplication is unavoidable, mark
one source of truth and add a mechanical drift check.
