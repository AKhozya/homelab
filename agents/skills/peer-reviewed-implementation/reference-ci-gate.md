# Peer-Reviewed Implementation — CI gate run details

Read this when step 6 has you run a CI gate's step body outside CI.

## Command GitHub runs for each resolved shell

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

## Where the extracted body differs from CI

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
