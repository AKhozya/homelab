---
name: mutation-testing
description: "Use before claiming a test covers a behaviour, and after fixing a review finding that came with a new test. Runs _shared/mutate.sh to break the code on purpose and require the suite to go red. Returns VOID rather than a verdict when the mutant never applied, did not compile, the suite was already red, or the restore failed. Covers picking mutants that still compile, keeping anchors unique, and looping over several anchors."
user-invocable: false
---

# Mutation testing

A green test proves the test runs. It does not prove the test would notice the
code being wrong. Delete or invert the line the test claims to cover; if the
suite stays green, the test is decorative.

Apply this when:

- a test is written for a bug fix or a review finding — the fix is a hypothesis
  until a mutant dies
- a whole feature lands and its handler tests all pass on the first run
- a reviewer asks whether coverage is real

## The command

```bash
~/.agents/skills/_shared/mutate.sh \
  --file src/config.ts \
  --anchor 'value >= 0' \
  --replace 'value > 0' \
  --test  'bun test src/transcribe.test.ts' \
  --check 'bun run typecheck'
```

Verdict on stdout, detail on stderr. `--check` is mandatory; pass `--no-check`
only for a language with no build step.

| Exit | Verdict | Means |
|---|---|---|
| 0 | KILLED | suite went red — the anchor is covered |
| 1 | SURVIVED | suite stayed green — coverage gap, write the test |
| 2 | VOID | the run proved nothing; do not report a verdict |

Multi-line anchors go through `--anchor-file` / `--replace-file`, which read raw
bytes and never cross a shell boundary.

## Pick a mutant that still compiles

The mutant has to be *wrong*, not *broken*. `if (false)` and deleting a whole
block usually fail to typecheck, and a mutant that fails `--check` is VOID — it
tells you nothing about the test.

| Instead of | Mutate to |
|---|---|
| deleting a guard | flip its comparison: `>=` becomes `<` |
| `x === undefined` | `x !== undefined` |
| deleting a call | keep the call, drop its argument or swap two arguments |
| a constant `-76` | a neighbouring value the test should reject |

Mutating an off-by-one boundary is the strongest form: it fails only if the test
asserts the boundary rather than the happy path.

## Loop over several anchors

Run one mutant per invocation and let the shell drive the list. Reuse
`--no-baseline` after the first call so the clean-tree suite run happens once.

```bash
M=~/.agents/skills/_shared/mutate.sh
T='bun test src/transcribe.test.ts'; C='bun run typecheck'
"$M" --file src/config.ts --anchor 'value >= 0' --replace 'value > 0' --test "$T" --check "$C"
"$M" --file src/config.ts --anchor 'raw.trim() === ""' --replace 'raw.trim() !== ""' \
     --test "$T" --check "$C" --no-baseline
```

Each run restores the file before exiting, so a mutant never reaches a commit.

## Why VOID exists

Every guard below fired for real and turned a believable verdict into a lie.
A VOID result is not a failure of the run — it is the run refusing to lie.

| VOID reason | The lie it prevents |
|---|---|
| `anchor not found` | the edit never applied; "0 failures" reads as SURVIVED |
| `anchor matches N places` | the first match was a comment, so the code was untouched |
| `file unchanged after mutation` | anchor and replacement were the same text |
| `mutant fails check` | the suite failed to compile, not to assert — reads as KILLED |
| `baseline red` | the suite was already failing, so every mutant "kills" |
| `the test command rewrote <file>` | a formatter or generator in the suite moved the target — checked before the mutation and again after the suite, so a suite that repairs what it tests cannot read as SURVIVED |
| `the check command rewrote <file>` | the mutant was undone before the suite ran, so green means nothing |
| `restore failed` | a mutant is still in the working tree |

## What it does not check

The test and check commands must not write to the file under test. The file is compared
against the mutant before and after the suite, which catches a formatter or generator
that moves it, but a command that rewrites the file and puts it back within the same run
defeats any before/after comparison. Point `--test` at a suite, not at a script that
edits its own input.

## Reading a result honestly

- SURVIVED on a test you just wrote for a review finding means the fix is
  unproven. Fix the test, not the verdict.
- KILLED only proves the *mutated* line is covered. It says nothing about the
  lines beside it.
- **Running the test against the pre-fix code is not a substitute for mutants.** That
  baseline can only fail on bugs the old code had. It cannot fail on a bug your own fix
  introduced, so those stay invisible. On 2026-08-07 a fixed script passed 15 assertions and
  the pre-fix copy failed 8 — yet two of the six mutants targeted defects the fix itself had
  added, and the baseline passed both cleanly. Run both: the baseline shows the
  test catches the original class, the mutants show it catches regressions in the new code.
- A test that passes because of a language quirk — `NaN` comparing false
  against everything, a truthy empty object — is testing the quirk. Mutate the
  quirk itself and see whether anything notices.
