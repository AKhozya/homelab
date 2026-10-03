---
name: bash-scripting
description: "Use when writing or editing any bash/shell script (.sh, .bash, executable with shebang) or proposing a multi-line bash snippet meant to persist. Also: Claude Code Bash-tool quirks (! prefix no TTY for sudo, auto-classifier blocks combined write+chmod+lint, multi-line $var loops need bash -c wrap). Enforces set -euo pipefail + quoting, prefers installed brew tools over hand-rolled parsing, gates commits on shellcheck + shfmt; catches SC2015, unquoted globs, cd-and-cmd, ls|grep, /tmp/$$, missing trap cleanup, SIGPIPE under pipefail."
user-invocable: false
---

# Bash Scripting

Standards for any shell script in this environment.

## Mandatory header

```bash
#!/usr/bin/env bash
set -euo pipefail
```

Relax only with explicit local override:
- `kubectl get x || true` — expected failure, ignore
- `set +e; ...; set -e` — bounded section needing failure passthrough
- `set -u` only — if script intentionally relies on unset-var defaults (rare)

## Quoting / structure

- Always quote expansions: `"$var"`, `"${arr[@]}"`, `"$(cmd)"`, `"${var:-default}"`
- `[[ ]]` not `[ ]` (regex, glob, no word-split surprises)
- `$()` not backticks
- `(( ))` for integer arithmetic
- `mktemp` not `/tmp/$$` (predictable, race-prone)
- Trap cleanup: `trap 'rm -rf "$TMP"' EXIT INT TERM`

## Anti-patterns (catch in review)

| Bad | Why | Fix |
|---|---|---|
| `A && B \|\| C` | C runs if B fails (SC2015 real bug) | `if A; then B; else C; fi` |
| `ls $dir` in script | unquoted, breaks on spaces | `find` / `fd` |
| `ls \| grep X` | parsing ls is fragile | `find -name '*X*'` / `fd X` |
| `cat X \| jq` | UUOC; also `cd && git` violates safe-bash allow | `jq '.' X` |
| `cd dir && cmd` | breaks safe-bash allow patterns; hangs | `git -C dir cmd` or pass `--cwd`/`-C` |
| `/tmp/$$` | predictable, race condition | `mktemp` |
| `wget X` no fallback | silent fail | `wget -qO- X \|\| { echo fail >&2; exit 1; }` |
| `if [ $? -eq 0 ]` | brittle | `if cmd; then` directly |
| `for f in $(ls)` | breaks on spaces/newlines | `for f in *.sh` or `find -print0 \| while IFS= read -r -d ''` |
| `read line < file` no `-r` | mangles backslashes | `read -r line` always |
| trap leak between iterations | cleanup runs once at EXIT | combine cleanup, set `trap '' EXIT` to disable when needed |
| `sudo -n cmd` over SSH | non-interactive sudo fails → pam_faillock counter ticks toward lockout | Output command to user with `ssh -t`; never run via Bash tool. See `/homelab-node-fix` for the SSH+TTY pattern. |
| `cmd \| head -N` under `set -o pipefail` | head exits early → SIGPIPE upstream → pipe exits non-zero → `set -e` kills script silently or captures empty `$()` | Use `awk 'NR<=N'` (reads all, prints first N — no SIGPIPE). Incident: `reference-bashtool-quirks.md` §4. |

If you sweep a repo for every reference to a string, read reference-tools.md § "Anti-pattern: rg misses tracked files in ignored dirs".

## Prefer brew-installed tools (check with `command -v`)

In a script, search with `grep -E`, not `rg`: `rg` is a shell function here and is absent from a child script's PATH.
If you need to choose a tool for JSON, YAML, CLI output, search, lint or format, read reference-tools.md. It also lists the tools that work only interactively.

## Pre-commit gate (run BOTH, both must exit 0)

```bash
shellcheck script.sh
shfmt -d script.sh    # diff against canonical; -w to fix
```

SC info-level rules are NOT cosmetic. SC2015 in particular is a real bug.

## Bash tool (Claude Code) — quirk catalog → load `reference-bashtool-quirks.md`

When a Bash-tool symptom below fires, load `reference-bashtool-quirks.md` and follow the matching section — don't improvise.
If you write a script, read reference-bashtool-quirks.md § "What each section holds" to see which sections apply there.

| Symptom | Section (`reference-bashtool-quirks.md` §) |
|---|---|
| Multi-line `for f in glob` loop leaves `$f` un-expanded (`sed: $f: No such file`) | §1 Multi-line loop `$var` un-expansion → wrap in `bash -c '...'` |
| `! ssh -t ... sudo ...` → "a terminal is required" (no TTY) | §2 `!` prefix has NO TTY → run in own terminal or `op read` inject |
| Single Bash call with Write+chmod+lint blocked ("Self-Modification") | §3 Auto-classifier → split into Write / shellcheck / chmod calls |
| `$()` captures empty / `set -e` silent kill on `cmd \| head -N` (SIGPIPE) | §4 `head -N` SIGPIPE under pipefail → use `awk 'NR<=N'` (redis-master.sh bug) |
| `B="kustomize build"; $B` → "command not found: kustomize build" | §5 zsh no word-split unquoted `$var` → array or `${=B}` |
| `git commit` Bash call blocked on a newline / `cd`-then-commit two-liner | §6 `git-commit-style.sh` blocks newline → one physical line, `git -C` |
| `rg: command not found` inside a `bash x.sh` script (yet `rg` works in direct Bash-tool calls) | §7 `rg` is a shell function → use `grep`/`grep -E` in scripts |

## Loops / parallel

- Iterate files null-safely:
  ```bash
  find ... -print0 | while IFS= read -r -d '' f; do
    process "$f"
  done
  ```
- Spawn parallel: `xargs -P N -n 1` for CPU-bound; **sequential for kubectl** (server rate-limits) and SSH (key auth handshake).

## Exit codes (document at top of script)

- `0` success
- `2` misuse / bad args
- `3` missing required resource (file, secret, cluster object)
- `≥10` domain-specific failure

## Heredocs

- `<<EOF` (interpolated) vs `<<'EOF'` (literal — preferred for code/templates).
- Use `<<-EOF` only with leading tabs (not spaces).

## Logging

```bash
log() { printf '[%s] %s\n' "$(date -u +'%FT%TZ')" "$*" >&2; }
log "starting reconcile"
```
- stderr for logs/diagnostics. stdout for data only (so piping works).

## Reference

- ShellCheck wiki: `https://www.shellcheck.net/wiki/SC<NNNN>`
- `man bash` POSIX vs bash extensions — bash extensions OK in `#!/usr/bin/env bash`, not in `#!/bin/sh`.

## When NOT bash

- >100 lines + state machines → Python/Go
- Complex JSON shaping → `jc`+`jq` pipeline; if still hard, Python
- Concurrent producers/consumers, retries with backoff, structured logging → Python/Go
- Anything called as a long-running daemon → not bash
