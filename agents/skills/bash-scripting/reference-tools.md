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

Interactive-only tools (`bat`/`eza`/`delta`/`difft`/`dust`/`duf`/`viddy`/`procs` — prettier `cat`/`ls`/`diff -u`/`du -sh`/`df`/`watch`/`ps` replacements): see the `~/.claude/CLAUDE.md` tool list.

Full local list: `~/.Brewfile` + `command -v <tool>`.
