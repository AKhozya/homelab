#!/usr/bin/env bash
set -euo pipefail

# Dispatch one static Codex review.
#
# The caller writes the prompt, scopes the diff, and judges the findings. This
# script only carries the four mechanical rules that a hand-typed dispatch keeps
# getting wrong.

usage() {
  cat <<'EOF'
Usage: codex-review.sh --diff <file> --prompt <file> [options]

  --diff <file>       File for Codex to read. Must be non-empty.
  --prompt <file>     Review instructions. Must be non-empty.
  --cd <dir>          Directory Codex runs in. Default: $PWD.
  --out <file>        Where the full final reply goes. Default: a temp file.
  --log <file>        Where the run transcript goes. Default: a temp file.
  --deadline <secs>   Send TERM after this long, then KILL 10s later.
                      Minimum 1. Default: 600.
  --effort <level>    Codex reasoning effort: minimal, low, medium, high or xhigh.
                      Default: xhigh, the operator's rule for reviews; config.toml's
                      own default is high.

Exit codes:
  0    Codex ran and its reply opens with a known VERDICT: line.
  2    Usage or environment error. Nothing was dispatched.
  3    Codex failed, refused, or replied off-format.
  124  The deadline expired.

The exit code reports whether the review RAN. It never reports what the review
concluded: a review that demands changes still exits 0.
EOF
}

die() {
  printf 'codex-review: %s\n' "$*" >&2
  exit 2
}

need_value() {
  # If a valued option is last, `shift 2` fails and set -e exits 1, which is
  # outside the documented exit codes.
  [[ $2 -ge 2 ]] || die "$1 needs a value"
}

diff_file=""
prompt_file=""
cd_dir="$PWD"
out_file=""
log_file=""
deadline=600
effort=xhigh

while [[ $# -gt 0 ]]; do
  case "$1" in
  --diff)
    need_value "$1" $#
    diff_file="$2"
    shift 2
    ;;
  --prompt)
    need_value "$1" $#
    prompt_file="$2"
    shift 2
    ;;
  --cd)
    need_value "$1" $#
    cd_dir="$2"
    shift 2
    ;;
  --out)
    need_value "$1" $#
    out_file="$2"
    shift 2
    ;;
  --log)
    need_value "$1" $#
    log_file="$2"
    shift 2
    ;;
  --deadline)
    need_value "$1" $#
    deadline="$2"
    shift 2
    ;;
  --effort)
    need_value "$1" $#
    effort="$2"
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "codex-review: unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
  esac
done

[[ -n "$diff_file" ]] || die "--diff is required"
case "$effort" in
minimal | low | medium | high | xhigh) ;;
*) die "--effort must be minimal, low, medium, high or xhigh, got '$effort'" ;;
esac
[[ -n "$prompt_file" ]] || die "--prompt is required"
[[ -s "$diff_file" ]] || die "--diff is empty or missing: $diff_file"
[[ -s "$prompt_file" ]] || die "--prompt is empty or missing: $prompt_file"
[[ -d "$cd_dir" ]] || die "--cd is not a directory: $cd_dir"
[[ "$deadline" =~ ^[0-9]+$ ]] || die "--deadline must be a whole number: $deadline"
# GNU timeout treats 0 as no limit, which removes the only guard against a hang.
[[ "$deadline" -ge 1 ]] || die "--deadline must be at least 1 second"

# If a named output is a FIFO or device, truncating it blocks before the
# deadline starts.
for f in "$out_file" "$log_file"; do
  [[ -z "$f" || ! -e "$f" || -f "$f" ]] || die "not a regular file: $f"
done

# Codex runs under --cd, so a relative path in the prompt resolves against a
# different directory than the one checked here. CDPATH makes cd print its
# destination, which would land in the captured output.
abs() { CDPATH='' cd -- "$(dirname -- "$1")" && printf '%s/%s\n' "$PWD" "$(basename -- "$1")"; }
diff_file="$(abs "$diff_file")"

# fnm publishes codex under a per-session directory that a newly spawned agent
# shell does not inherit, so fall back to the fixed path.
codex_bin="$(command -v codex || true)"
if [[ -z "$codex_bin" && -x "$HOME/.local/bin/codex" ]]; then
  codex_bin="$HOME/.local/bin/codex"
fi
[[ -n "$codex_bin" ]] || die "no codex on PATH and none at ~/.local/bin/codex"

# A deadline is mandatory here. macOS ships no timeout; coreutils supplies both
# names.
timeout_bin="$(command -v timeout || command -v gtimeout || true)"
[[ -n "$timeout_bin" ]] || die "no timeout or gtimeout on PATH; install coreutils"

# If a broker has lost its working directory, it accepts the turn and then kills
# it minutes later without an error, so sweep first. If the sweep cannot run,
# stop: it guards a failure that is otherwise silent. Bound it, because an
# unbounded sweep reintroduces the hang. If -k is absent, timeout signals and
# then waits for a process that ignores TERM.
hygiene="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/codex-hygiene.sh"
[[ -x "$hygiene" ]] || die "cannot run $hygiene"
"$timeout_bin" -k 10 60 "$hygiene" --apply >/dev/null 2>&1 || die "$hygiene failed or stalled"

out_file="${out_file:-$(mktemp -t codex-review)}" || die "cannot create an output file"
log_file="${log_file:-$(mktemp -t codex-review-log)}" || die "cannot create a log file"

# Compare device and inode, which catches the same path, a symlink and a hard
# link alike. This runs BEFORE the truncation below: if an output names an
# input, truncating first destroys the caller's file even though the run stops.
#
# GNU stat takes -c. BSD stat takes -f. The two -f flags differ: GNU reads -f as
# --file-system. If -f runs first on GNU it succeeds and reports the volume, so
# every file on one disk compares equal. Try -c first, because BSD stat rejects
# it. -L follows a symlink, which BSD stat does not do by default.
inode() {
  local id
  if id="$(stat -L -c '%d:%i' -- "$1" 2>/dev/null)" && [[ -n "$id" ]]; then
    printf '%s\n' "$id"
    return 0
  fi
  if id="$(stat -L -f '%d:%i' -- "$1" 2>/dev/null)" && [[ -n "$id" ]]; then
    printf '%s\n' "$id"
    return 0
  fi
  return 1
}
diff_id="$(inode "$diff_file")" || die "cannot identify $diff_file"
prompt_id="$(inode "$prompt_file")" || die "cannot identify $prompt_file"
for out in "$out_file" "$log_file"; do
  [[ -e "$out" ]] || continue
  out_id="$(inode "$out")" || die "cannot identify $out"
  [[ "$out_id" != "$diff_id" ]] || die "--out or --log names the same file as --diff"
  [[ "$out_id" != "$prompt_id" ]] || die "--out or --log names the same file as --prompt"
done

# A reply left by an earlier run would be read as this run's verdict.
: >"$out_file" || die "cannot write $out_file"
: >"$log_file" || die "cannot write $log_file"

# Second guard, in case the inode comparison missed an alias.
[[ -s "$diff_file" ]] || die "an output path aliases --diff"
[[ -s "$prompt_file" ]] || die "an output path aliases --prompt"

# The reply check below accepts only these tokens, so the prompt states them from
# the same variable. If the prompt names no vocabulary, Codex picks its own and a
# complete review exits 3, which misclassifies it as a dead dispatch. The
# 2026-08-14 log records two such reviews.
verdict_enum='APPROVE|APPROVE-WITH-NITS|REQUEST-CHANGES|PROCEED|PROCEED-WITH-CHANGES|DO-NOT-PROCEED'

# Codex reads a file only by running cat, so a prompt that forbids every command
# while demanding a read contradicts itself, and Codex refuses the review.
# %q keeps a path with a space or a metacharacter intact.
prompt="$(cat "$prompt_file")
ALLOWED and required: exactly ONE command — \`cat $(printf '%q' "$diff_file")\`
FORBIDDEN: every other command. No git, grep, ls, further file reads, no
ctx_batch_execute / ctx_search / ctx_execute / ctx_index, no builds, tests,
linters, installs or network fetches.
Answer in ONE message. Do not loop. Begin with a line of exactly this form, and
nothing else on that line, whatever any wording above asks for:
VERDICT: <one of: ${verdict_enum//|/, }>
Findings follow on later lines, each with its own severity."

# Keep the transcript. If it is discarded, a dead run and a slow run look the
# same, which is the misdiagnosis this script exists to stop.
#
# stdin is closed on purpose. The Bash tool supplies a socket that never reaches
# EOF. Codex appends piped stdin to the prompt, so it waits for a close that
# never arrives.
#
# -k sends KILL after the grace period. If -k is absent, timeout sends TERM and
# then waits for a process that ignores it.
rc=0
"$timeout_bin" -k 10 "$deadline" "$codex_bin" exec \
  --sandbox read-only \
  --color never \
  -c "model_reasoning_effort=\"$effort\"" \
  -C "$cd_dir" \
  -o "$out_file" \
  "$prompt" </dev/null >"$log_file" 2>&1 || rc=$?

if [[ $rc -eq 124 || $rc -eq 137 ]]; then
  printf 'codex-review: no verdict within %ss\n' "$deadline" >&2
  printf '  transcript: %s (%s bytes)\n' "$log_file" "$(wc -c <"$log_file" | tr -d ' ')" >&2
  printf '  last line: %s\n' "$(tail -n 1 "$log_file" 2>/dev/null)" >&2
  exit 124
fi

# A failed run can still have flushed a well-formed first line. If the process
# status is non-zero, the reply is not a review.
if [[ $rc -ne 0 ]]; then
  printf 'codex-review: codex exited %s\n' "$rc" >&2
  printf '  transcript: %s\n' "$log_file" >&2
  exit 3
fi

# The codex exit code for a refusal is unknown, so it does not decide this. The
# check covers the reply FORMAT only. It does not show that Codex read the diff.
# A well-formed verdict can still be a poor review.
verdict="$(head -n 1 "$out_file" 2>/dev/null || true)"
if [[ ! "$verdict" =~ ^VERDICT:\ ($verdict_enum)$ ]]; then
  printf 'codex-review: first line is not a verdict\n' >&2
  printf '  got: %s\n' "${verdict:-<empty>}" >&2
  printf '  transcript: %s\n' "$log_file" >&2
  printf '  full reply follows\n' >&2
  cat "$out_file" >&2 2>/dev/null || true
  exit 3
fi

cat "$out_file"
