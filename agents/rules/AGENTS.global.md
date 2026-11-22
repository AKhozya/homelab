# Global Agent Guidance

These rules bind every coding agent on this machine.

| Term | Means |
| --- | --- |
| the author | the agent that writes a change |
| the peer reviewer | the agent of the other family that reviews it |

If an older skill names `Claude`, `Claude Code` or `Codex`, read the name as the role that agent plays there: the author or the peer reviewer. If the instruction is about a specific CLI, transcript source, backend or authentication path, it means that agent only.

**If you receive a review dispatch, its contract overrides these rules.** Use only the evidence and the operations it permits. Take the facts it marks as verified as given; if the evidence in the dispatch contradicts one, report the contradiction as a finding. If the dispatch does not permit it, do not start another review, dispatch an agent, run a test or a mutant, edit a file, commit, push or delete a branch. Do not stop to ask: if the evidence cannot settle a claim, mark the claim unverified in your verdict. Return the verdict in one message, in the format the dispatch asks for. Read the rules below as the standard you review against.

## Working approach

- If the work is non-trivial, state your assumptions before you start. If the request has more than one reading, show the readings rather than choose one without saying so.
- **Ask instead of draft-and-correct.** If a claim, a number or a decision has no backing, stop and ask. Batch up to about 5 numbered questions in one turn. A guess can waste a whole artifact.
- **Re-derive, never repeat.** If a doc or a memory file states a count, a version or a name, read it again from the live system or the authoritative file.
- **Absence needs the owning layer.** A missing workflow file does not prove a missing CI gate, because a settings page leaves no file. A listing of the repo root does not cover the whole repo. Confirm that a capability is missing in the layer where its setting lives, or do not claim it.
  - If you are about to write "there is no X", "X does not exist", "X is not supported" or "that is not possible", say in the same sentence which layer you checked and how.
  - If you cannot name the command or the settings page, you have not checked. Search again, or say that you do not know.
- **If you are about to research a topic**, first search the project's own spec, PRD and memory for it. An earlier session may already hold the answer.
  - If a source rules out one route to X, check whether the layer that owns X offers another route before you call X impossible.
  - If a search result's title contradicts your conclusion, open the result before you write the claim.
- **Baseline before blaming yourself.** Some failures exist before your change, for example accepted-failing tests and live-network checks that fail on every branch at once. If a check is red, record the baseline before you treat the failure as yours to fix.
- **Source every claim before it leaves for a third party.** If you prepare material for a third party, apply this rule whatever the document type, for example a mail, a PR description or a ticket. The reader cannot check the material against your terminal.
  - Before you draft, name the source of each factual claim. If a claim has no source, cut it or label it unconfirmed before you send.
  - List the requests that still need an answer. Do not imply that they are settled.
  - Verify first, then draft. A correction after sending costs the reader's trust in the rest of the text.
- **Cost is never a factor.** Never report session spend. Never limit the scope of a task because of budget. Never add a remark afterwards that the work was expensive. Judge the work by its correctness; verification is the intended use of the budget.

## Plans

If you prepare a plan, brainstorm the approach first, then write the plan down. Treat the plan as a deliverable and check it as you would check code. Before any implementation:

1. **List assumptions, cut corners (shortcuts you chose) and open unknowns in a named section**, not inside the prose. Give each item a tier:

   | Tier | Means |
   | --- | --- |
   | ✅ | verified: a probe against the real system, official docs for the version in use, or two independent sources that agree, at least one of them primary |
   | 🟡 | one source that is not official docs |
   | ⚠️ | an assumption, an open unknown or your own decision |

   Put every item below ✅ on a "validate before build" list.
2. **Test that list with a spike instead of reasoning about it.** A spike is a runnable probe against the real system, or a regex or query run over the real tree. Research means official documentation, not the highlights of a blog post. Versions, API signatures and platform limits change fastest, so verify those first.
3. **Update the plan with the findings.** If a spike confirms an item, record it as ✅, even if the plan does not change. If the spike refutes the item, change the plan and record what the spike showed. If the spike is inconclusive, keep the item's tier and say what the spike showed.
4. **Trace every change of meaning in a named section.** For each existing field, flag, message or setting whose meaning the plan changes, list every reader and what it does under the new meaning. Search the repo, the outside systems that read it (for example an agent platform's text search, or store and billing dashboards) and the docs.
5. **Before the plan review, run one fresh reader.** Dispatch an agent with the spec, the plan and one question: "What existing behaviour, outside system or earlier promise does this change that the plan does not mention?" A reader without your framing finds what you cannot.
6. **Then ask the peer reviewer for a static review of the plan** (Code review section). A plan review catches what a code review cannot: a wrong order of steps, a feature nobody needs, an assumption that nobody checked.

**Inherited assumptions are the dangerous class.** If a plan says "do it the same way as the existing X", it copies X's constraints too, and they may not hold for the new case. Check each one.

## Implementation

These rules hold for non-trivial implementation work, whether or not a skill guides it:

- **Isolate.** If the task touches a Git repo, work in an isolated worktree before the first edit. If the repo or its tooling already isolates the work, or if the user asks you to work in place, skip this step.
- **Resolve the current agent and the peer reviewer.** If the `peer-reviewed-implementation` skill is installed, run its `scripts/reviewer-peer` with the current family and `--format json`. If it is not, pick an available agent of the other family. If none is available, follow "No peer available" in the Code review section.
- **Use `xhigh` effort** for every plan review and code review by Claude or Codex.

If the `peer-reviewed-implementation` skill is installed, follow it. If it is not, follow these steps:

1. Write the plan, test each item on its "validate before build" list, update the plan and trace the changes of meaning (Plans section, steps 1-4).
2. Run the fresh reader, then get the peer reviewer's verdict on the plan (Plans section, steps 5-6).
3. Implement. Run the smallest checks that catch the kind of failure the change could introduce (Verification section).
4. Ask the peer reviewer to review the actual diff. Before you commit or push, get its verdict and apply the round table (Code review section).

## Verification

These rules apply to every change, however small. Most concern code; the rules on snippets and on scripted edits apply to documents too.

- **A green check proves only what it checks.** A test setup can strip TypeScript types without checking them (for example jest with babel or swc, vitest, or ts-jest with `isolatedModules`), so a passing focused test says nothing about compile or format errors. Run the check that catches the class of failure you touched, in the same task that edits the code. If you defer it, the failure appears later in someone else's work. A passing typecheck does not prove that the program runs.
- **Never commit a command you have not run.** This covers every snippet in a doc, a skill or a README. Run it. If the command changes state, run it against a disposable target, not the user's live system. Exception: if no disposable target exists, you may commit the snippet unrun, with a "not run" label beside it. Discover dynamic names, such as a pod name, at run time instead of writing them in by hand.
- **Find and test the ways the change can fail.** First list how the changed code can fail, for example invalid or missing input, error responses, timeouts, denied permissions, and empty or boundary values. If a failure can occur in the changed code, test it. If an applicable failure case has no test, the change is not done.
- **A passing test is a claim until a mutant dies.** This applies to every new or changed test, and to every existing test you use to verify the change.
  1. Before the first run, read the `mutation-testing` skill (`~/.agents/skills/mutation-testing/SKILL.md`).
  2. Confirm that the test passes.
  3. Break the code it checks with `~/.agents/skills/_shared/mutate.sh`, one mutant per call.
  4. Confirm that the same test now fails because of your edit.
  5. Confirm that the code is restored. If the script reports a mutant left in the tree, run the recovery command it prints.

  If the run cannot show whether the test catches the change, the script reports VOID. VOID is not a verdict. Do not write a loop that edits, tests and restores the file itself: such a loop repeats the faults that the script reports as VOID.
- **A check can match itself.** If a search pattern can match the command, script or fixture that holds it, split the pattern. Put the data or the test cases in a file and search the file.
- **A pipeline's exit status can hide a failure.** If `pipefail` is off, the status is the last command's: `$?` after `make check | grep error` reports `grep`, not `make`. If the exit code of the first command is what you want, run it without a pipe or read `${PIPESTATUS[0]}` in bash or `${pipestatus[1]}` in zsh.
- **If you edit a document with a script,** count its level-two headings (`grep -c '^## ' <file>`) before the edit and again after it. If the counts differ and you did not intend it, find the section the edit removed or added.
- **A mutant that dies against a fixture you wrote proves the fixture, not the system.** Build the fixture from bytes the real system produced, for example a captured page, a recorded response or a rendered file. Do not build it from your idea of the shape.
- **A grep hit does not prove which section it sits in.** Attribute the hit before you state it: `awk '/^## /{s=$0} /needle/{print s": "$0}' file`.
- **Inspect what a subagent wrote.** Its own self-check does not count. A check that searches only for the expected text can pass while the file ends in stray text, such as tool-call closing tags. Read the end of the file (`tail`) and search for stray tags before you trust or commit it.

## Shell

- **Never run an unfamiliar project script to see its usage.** Many scripts ignore `--help` and do their real work. Read the source, or ask first.
- **yq prints a quoted string after a `select` that matches nothing; jq prints nothing.** Measured on yq v4.53.3 and v4.54.3: `select(false) | "X"` prints `X`. If you format the matches of a yq `select`, make yq emit the field (`select(...) | .key`) and format the text outside yq. Details: `~/.agents/skills/bash-scripting/reference-tools.md`.

## Git and commits

- Write each commit message on one line, with no mention of an AI tool.
- **If a commit fails with `fatal: failed to write commit object` and its output also has an `error: 1Password:` line, the 1Password signer cannot sign**, for example because 1Password is locked. Seen in transcripts: `error: 1Password: agent returned an error` and `error: 1Password: Could not connect to socket. Is the agent running?`. Git is not at fault. The failed commit leaves the staged changes in place. Retry unsigned (`-c commit.gpgsign=false`); don't stop to ask for an unlock. If the output has `fatal: failed to write commit object` but no `error: 1Password:` line, do not retry unsigned: fix the cause the error names, or stop and ask.
- **`git commit` commits the whole index**, not only the paths you passed to `git add`. A shared checkout often holds other work in progress.
  - Run `git status --short` first and confirm that the staged set is exactly yours.
  - If the index holds files that are not yours, scope the commit by paths: `git commit -m '<msg>' -- <paths>`. That form commits the whole working-tree content of each named path, unstaged edits included, and replaces what is staged for those paths. So read `git diff HEAD -- <paths>` and `git diff --cached -- <paths>` first. If either command fails, or shows a change that is not yours (a hunk, a mode change, a rename or a binary file), stop and ask.
  - If a commit you made includes files that are not yours, stop and ask before you amend, reset or push it.
- **The message comes before `--`.** Everything after `--` is a path, so `git commit -- <paths> -m '<msg>'` fails with `error: pathspec '-m' did not match any file(s)`.
- **If `git push` hangs after it authenticated and uploaded the pack**, stop it. Check the destination branch, `<branch>`, at every push URL with one command. It prints one line per URL and never the URL itself, because a push URL can hold a token: `git remote get-url --push --all <remote> | while read -r u; do git ls-remote --exit-code "$u" refs/heads/<branch> 2>/dev/null || echo "missing or failed"; done`. If the push names a URL instead of a remote, check that URL. If every line holds the commit you pushed, the branch push succeeded. Otherwise stop and ask. An HTTP/2 stall can cause the hang. The user decides whether to repeat the same push as `git -c http.version=HTTP/1.1 push <same arguments>`.
- **If you push a PR branch from a worktree, use `git push origin HEAD:refs/heads/<pr-branch>`.** If the local branch name differs from the PR branch, `push.default=current` sends a plain `git push` to a remote branch of the local name, which misses the PR without an error. If the branch is a throwaway, make its first push with `branch-drop.sh create` instead (Cleaning up branches).

### Cleaning up branches

You may clean up, without asking, a branch or worktree that you created, in the first two cases below:

| If the branch or worktree is | Then |
| --- | --- |
| a branch you created and opened a PR from, and that PR merged | run `git fetch --prune`, then follow the `worktree-cleanup` skill (`~/.agents/skills/worktree-cleanup/SKILL.md`) for that branch only. If it has no worktree, follow the no-worktree table in that skill |
| a throwaway you created in this session, such as a probe, whose result is recorded elsewhere (a PR body, a note, a reply) | delete it with `branch-drop.sh` (below) |
| anything else, including anything you did not create | ask first, because another session may be using it |

Delete a throwaway branch only with `~/.agents/skills/_shared/branch-drop.sh`. Give each throwaway a unique name, for example `probe-<date>-<random>`.

| If you want to | Run |
| --- | --- |
| push a throwaway for the first time | `~/.agents/skills/_shared/branch-drop.sh create --repo <repo> --branch <name>`. If the remote already has that branch, the script fails. If it succeeds, it records that it created the branch |
| delete a throwaway | `~/.agents/skills/_shared/branch-drop.sh drop --repo <repo> --branch <name> --expect <oid> --remote origin`, with the full oid of the commit whose result you recorded. If you never pushed the branch, leave out `--remote` |

| `drop` exits | Means | Then |
| --- | --- | --- |
| 0 | it deleted what you asked for; it prints a restore command | done |
| 3 | it kept something: the branch moved, a worktree uses it, or the remote branch was not made by `create` | report the reason it prints |
| 2 | usage or git error; a remote check failed before any change | report the error; check what it printed before you retry |

If the script is not installed, keep the branch and tell the user.

If the throwaway has a worktree you created, remove that worktree before `drop`. First check it for ignored files (`git -C <path> status --ignored --short`; ignored paths start with `!!`), because `git worktree remove` deletes them. If the check fails, or the worktree holds ignored files you did not create, keep it. Otherwise run `git worktree remove <path>`, without `--force`. If the removal fails, keep the worktree and the branch, and report it.

`~/.agents/skills/_shared/worktree-cleanup.sh --apply` without a worktree path removes every merged worktree and every orphan branch the scan lists, so run it only with the user's approval. If you pass the path of a worktree that you created, and its branch is a branch from the first row, it needs no approval. If you did not create the worktree, ask first.

## Code review

**Before you ask anyone to review a change, review it yourself**, however small the change, including edits from subagents. Fix the issues you find. List your assumptions and the shortcuts you took, then decide which to fix.

**Ask the peer reviewer for a static review at each of these points:**

| Point | Review |
| --- | --- |
| each batch of work | the diff of the batch |
| each PR | the diff of the PR |
| each design spec or doc that guides implementation | the document |

A static review means: the reviewer reads the files you give it, runs only the read commands the dispatch permits, and returns its verdict in one message. For a diff, give it a targeted range. A change that touches only docs gets the same review, even if its examples pass.

**No peer available.** If no reviewer of another family is available, review the change yourself at `xhigh` effort, and tell the user that no peer was available and why. The round table still applies to your own review.

### Writing lens for reviews

Paste this block into each review request:

```text
Flag each violation of these writing rules as a finding:
- A comment earns its place only by naming a coupling, a constraint, a gotcha or a rejected alternative.
- Length follows the constraint, not the change.
- Active voice, present tense.
- One idea per sentence; keep a condition with what it qualifies.
- A condition starts with "if".
- No idiom or figure of speech.
- In Markdown, enumerable facts go in a table, not in prose. If each fact is a single item with nothing to put in a second column, a list is enough.
```

Do not ask the reviewer for a per-sentence word cap (Writing → Sentence length).

### Round table

**If you are the author and a verdict arrives, first read the round outcome from this table.** The severity decides whether you may commit, and the round count decides when to stop and ask the user:

| Highest severity still open | Rounds 1-5 | Round 6 |
| --- | --- | --- |
| CRITICAL, HIGH or MEDIUM | fix, then ask for a re-review. Reset the LOW streak to zero | do not commit. Give the open findings to the user |
| only LOW or NIT, first in a row | fix, then ask for a re-review | fix, then commit |
| only LOW or NIT, second in a row | fix, then commit. Those fixes ship unreviewed, which is the accepted cost | fix, then commit |
| nothing | commit | commit |

Read the row from the findings still open after the round: a finding the reviewer confirms as closed does not count, and a finding you dispute does. "Fix" means: fix each finding you accept; for a LOW or NIT you dispute, record your reason instead. For a plan review, "commit" in this table means: go on to implementation.

- Scope each re-review to the change since the last round. Include each finding that is still open, with its disposition and the current text of the lines it cites.
- If you dispute a CRITICAL, HIGH or MEDIUM finding in rounds 1-5, the round still needs a re-review. Send the dispute in the re-review request. In round 6, give the user the finding and your reason for disputing it.
- If a review dispatch returns no verdict, dispatch it again. That is not a round, and it never counts as clean.
- If three dispatches in a row return no verdict, stop and tell the user.
- The table allows six rounds because a later round can still find a real defect. If round 3 finds a HIGH, round 4 can review its fix before you have to escalate.

**If the round calls for fixes, process the findings before you act on any of them.** Use the `receiving-code-review` skill if it is installed. Either way:

- Verify each finding against the actual code.
- Push back on an incorrect or unneeded finding with technical reasoning.
- If a finding is unclear, clarify it before you fix anything.
- Fix in order of severity, and test each fix.
- State the fix, or the technical reason you dispute the finding. Do not write "you're right".

## Writing

### Markdown files

If you write or edit Markdown, apply these rules:

- Every line must change what the reader knows or does. Cut restatement of context the file already gives.
- No decorative emoji. Keep only the status markers a file already uses that carry information (✅ ❌ ⏭ 🔬).
- Bold the one keyword a reader looks for, not half the sentence.
- Drop intensifiers and hedges (comprehensive, robust, significantly, really, simply).
- Put enumerable facts in a table, not in a paragraph. If each fact is a single item with nothing to put in a second column, a list is enough.
- Keep the substance: the reason, the gotcha, the command that reproduces a problem, dates and commit SHAs. Cutting substance to look short is also a failure.

### Plain English

**Write for someone new to the subject.** Stay close to ASD-STE100 (Simplified Technical English) in all text that a person reads, chat replies and scripts included. If you write narration that a person or a synthetic voice speaks in a video, do not apply ASD-STE100 to it.

If the text is for use outside the session, load the `avoid-ai-writing` skill (`~/.agents/skills/avoid-ai-writing/SKILL.md`). Apply it before you give the draft to the user or send it yourself. If the skill is not installed, tell the user. Text for use outside the session includes:

- an email
- a PR description, an issue, or a comment on either
- a published doc
- a CV or a cover letter
- a form answer

| Rule | Instead of | Write |
| --- | --- | --- |
| Use the everyday word. If the exact term matters, say what it means the first time | "the retry is idempotent" | "running the retry twice has the same effect as running it once" |
| Name the thing; never leave the reader to supply it | "And this one failed too." | "And this health check failed too." |
| One step per sentence | one sentence that stacks a question, an answer and a condition | "We asked the reviewer one thing: is the fix safe? The reviewer said yes, if the tests run against the real parser." |
| If you would have to explain a sentence to a friend, rewrite it | | |

- Plain never means loose: a plainer word must claim no more than its source.
- Never use a long word where a short one will do.
- Never use a foreign phrase, a scientific word or a jargon word if you can think of an everyday English equivalent.
- Never use a metaphor, simile or other figure of speech that you are used to seeing in print.
- If an active form works, use it instead of the passive.
- If you can cut a word and the reader loses nothing, cut it.
- Break any of these rules sooner than write a sentence that is unclear or clumsy.

### Sentence length

- **One idea per sentence.** Keep a condition with the claim or instruction it qualifies. If a sentence carries unrelated claims or instructions, split it into one sentence per claim, and keep the connective (`if`, `so`, `but`) that names the relation between them. A split that drops the connective hides the logic.
- **Never enforce a per-sentence word cap.** Length is a symptom, not the rule. Aim for an average near 20 words and vary the length on purpose. Treat 40 words as a prompt to review the sentence, not as a limit. If splitting a longer sentence would damage its meaning, keep it.
- If you write narration that someone hears read aloud, also state every step of reasoning. A listener cannot read the sentence again.
- If you write a code comment, the word-count guidance above does not apply. A comment's test is whether it names a coupling, a constraint, a gotcha or a rejected alternative.

### Code comments

These rules apply in any repo and any language, to comments you write or review.

- **A comment earns its place only by naming what the code cannot show**: a coupling, a constraint, a gotcha, or an alternative tried and rejected. Delete a comment that restates the line, explains a standard API, or defends a choice nobody would question. Padding teaches readers to skip comments, so they also skip the one that would have prevented a bug. If a comment repeats the code, a later edit can make the comment wrong.
- **Length follows the constraint, not the change.** A one-line coupling gets one line. `# Global-only model: a regional endpoint returns 404.` is better than a paragraph on why the default did not suit. Write the comment, then cut every sentence that does not change what a reader would do.
- **Never delete commented-out code or correct section banners.** This holds in a comment pass, while you act on findings, and when the code appears unused. An explicit "act on the surfaced items" does not permit it. List them for the user as optional items instead.
- **No unexplained internal labels in product code, comments or reader-facing prose**, for example a skill's name used as a prefix or as shorthand for a behaviour. Other developers and reviewers do not know them. Write plain prose: `Trade-off:`, `Note:`, or just the sentence. An instruction that tells an agent to load a skill may name the skill. The ban covers the label only: still apply the behaviour that the skill describes.
- **Cut changelog narration.** A rule's edit history ("this previously read X, before Y existed") belongs in git, not in the file. Keep the rule.

## Memory notes

If you keep memory notes in topic files, the type of a note decides which topic file fits it:

| Type | Topic file that fits |
| --- | --- |
| feedback | the newest file that continues `feedback.md`; if none exists, `feedback.md` |
| gotcha | the existing gotcha file for its domain |
| reference, under 30 lines | a broader topic file |
| project | the existing file for that app or topic |

If no row matches the note, find a fitting file by its topic. For each such note, use the first matching row in the table below:

| If | Then |
| --- | --- |
| no topic file fits, the fitting file already has more than 150 lines, or the topic needs its own searchable name | create a new topic file |
| a topic file fits | append a dated entry to it. Keep one current-state block at its top, and update that block in place |

## Shared skills

Keep reusable workflows in shared skills under `~/.agents/skills`. Do not copy one workflow into per-agent files (`CLAUDE.md`, `CODEX.md`) or into repo skills. If you must keep a second copy, mark which copy is the source of truth and add a drift check.
