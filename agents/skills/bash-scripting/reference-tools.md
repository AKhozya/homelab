# Bash Scripting — installed tools to prefer

Read this before you hand-roll JSON, YAML, CLI-output or file-search parsing in a script, to pick the installed tool for the job.

## Need → tool table

| Need | Tool | Beats |
|---|---|---|
| JSON filter / transform | `jq` | `awk`/`sed` for JSON |
| JSON flatten → grep | `gron` | manual `jq` paths |
| YAML | `yq` (jq syntax) | `python -c yaml.load` |
| YAML lint | `yamllint` | eyeballing |
| CLI → JSON | `jc` — `ps aux \| jc --ps`, `df -h \| jc --df`, `lsof \| jc --lsof`, `mount \| jc --mount`, `dig X \| jc --dig` | awk/sed parsing |
| Grep | `rg` interactively; **`grep -E` in scripts** (rg is a shell fn, absent from child-script PATH — `reference-bashtool-quirks.md` §7) | `grep -r` |
| Find | `fd` | `find` (fd has sane defaults) |
| Structural code search | `sg` (ast-grep) | regex for syntax-aware refactor |
| Sed (simpler regex) | `sd` | `sed 's///'` for in-place |
| Bench | `hyperfine` | `time` loops |
| K8s schema | `kubeconform -strict` | server dry-run (offline + fast) |
| Format shell | `shfmt -i 2 -w` | manual indent |
| Lint shell | `shellcheck` | nothing |
| Secrets | `sops`, `age` | manual encryption |
| Task runner | `just` | `make` for non-build |
| Watch files | `watchexec` | `inotifywait` loops |
| K8s multi-pod logs | `stern` | `kubectl logs --tail` loops |

These tools are for interactive use only. Do not call them in a script:

| Tool | Replaces |
| --- | --- |
| `bat` | `cat` |
| `eza` | `ls` |
| `delta`, `difft` | `diff -u` |
| `dust` | `du -sh` |
| `duf` | `df` |
| `viddy` | `watch` |
| `procs` | `ps` |

Full local list: `~/.Brewfile` + `command -v <tool>`.

## Trap: yq prints a quoted string after an empty `select`

If a `select` matches nothing, yq still prints a quoted string that follows it. jq prints nothing.

| yq version | Probed |
| --- | --- |
| v4.53.3 | 2026-08-08 |
| v4.54.3 | 2026-11-21 |

Results, the same on both:

| Expression | yq prints | jq prints |
| --- | --- | --- |
| `select(false) \| "X"` | `X` | nothing |
| `select(false) \| "job \(.name) x"` | `job  x` | nothing |
| `select(false) \| .name` | nothing | nothing |

`has()` returns true and false correctly, so the fault is not in the test. A constant string gives no sign that the `select` rejected the input. If the string interpolates a field, the blank field is the only sign.

Fix: make yq emit the field (`select(...) | .key`), and format the text outside yq. `rg` can cross-check the text, but it does not read YAML structure.

## Anti-pattern: rg misses tracked files in ignored dirs

| Bad | Why | Fix |
|---|---|---|
| `rg <pat>` to sweep ALL refs of a string | `rg` honors `.gitignore` → skips git-TRACKED files inside ignored dirs (`.backup/`, `.claude/`) → silent miss | `git grep <pat>` (tracked-only, ignores `.gitignore`) or `rg --no-ignore`. Real bug 2026-06-12: `rg 'clusters/staging'` missed `.backup/` DR-runbook refs; cavecrew caught them. Stage such files with `git add -f`. |
