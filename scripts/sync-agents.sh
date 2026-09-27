#!/usr/bin/env bash
#
# Keeps agents/ a read-only copy of the operator's published skills, helpers and
# Codex rules. The authoritative copy lives in dotfiles (~/.agents/skills); no
# tool loads agents/.
#
#   --check    report drift between the sources and agents/, write nothing
#   --update   copy the allowlisted sources into agents/skills/ and
#              agents/rules/AGENTS.global.md; write nothing if any phase fails
#
# Exit: 0 clean, 1 drift or list finding, 2 inputs or host, 3 forbidden entry,
# 4 publication scan, 5 shellcheck, 70 internal error. If several phases fail,
# the exit code is the first failing phase's.
#
# README.md, sync/ and rules/CLAUDE.global.md are hand-written: --update never
# touches them. CLAUDE.global.md line 1 records the sha256 of the ~/.claude/CLAUDE.md
# it was edited from, so --check can tell when the export needs another hand edit.

set -Eeuo pipefail

die() {
  echo "sync-agents: internal error: $*" >&2
  exit 70
}
trap 'die "line $LINENO: $BASH_COMMAND"' ERR

usage() {
  sed -n '3,17s/^# \{0,1\}//p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

[ $# -eq 1 ] || usage
case $1 in
  --check) MODE=check ;;
  --update) MODE=update ;;
  *) usage ;;
esac

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname "$SCRIPT_DIR")
AGENTS_SRC=${AGENTS_SRC:-$HOME/.agents/skills}
RULES_SRC_CLAUDE=${RULES_SRC_CLAUDE:-$HOME/.claude/CLAUDE.md}
RULES_SRC_CODEX=${RULES_SRC_CODEX:-$HOME/.codex/AGENTS.md}
PRIVATE_TERMS=${PRIVATE_TERMS:-$HOME/.config/sync-agents/private-terms.txt}
DENYLIST=${DENYLIST:-$HOME/.config/sync-agents/denylist.txt}
AGENTS_DST=${AGENTS_DST:-$REPO_ROOT/agents}
# openrsync, measured for this script. Its -E copies AppleDouble ._ files, so no -E.
RSYNC=${RSYNC:-/usr/bin/rsync}
ALLOWLIST=$AGENTS_DST/sync/allowlist.txt
GITLEAKS_CONFIG=$REPO_ROOT/.gitleaks.toml

rc=0
fail() { # fail <exit code> <finding>; the first failing phase sets the exit code
  printf 'sync-agents: %s\n' "$2" >&2
  if [ "$rc" -eq 0 ]; then rc=$1; fi
}

# grep exits 1 for no match and 2 for an error; only the error is internal.
grep_ok() {
  grep "$@" || [ $? -eq 1 ]
}

# --- phase 1: host. The bot pod holds older copies and would always report drift.
host=$(uname)
if [ "$host" != Darwin ]; then
  echo "sync-agents: host is $host; run this on the Mac that holds the dotfiles checkout" >&2
  exit 2
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STAGE=$WORK/staging
DSTSCAN=$WORK/target

# Findings name the source or target path, never a staging path. awk index()
# replaces literally; sed would read & and | in a path as syntax.
unstage() {
  S1=$STAGE/skills/ R1=$AGENTS_SRC/ S2=$STAGE/rules/AGENTS.global.md R2=$RULES_SRC_CODEX \
    S3=$DSTSCAN/ R3=$AGENTS_DST/ awk '
    function rep(line, s, r,   out, i) {
      out = ""
      while ((i = index(line, s)) > 0) {
        out = out substr(line, 1, i - 1) r
        line = substr(line, i + length(s))
      }
      return out line
    }
    { print rep(rep(rep($0, ENVIRON["S1"], ENVIRON["R1"]), ENVIRON["S2"], ENVIRON["R2"]), ENVIRON["S3"], ENVIRON["R3"]) }'
}

# --- phase 2: inputs
list_ok() { # list_ok <file> <label>
  if [ ! -f "$1" ]; then
    fail 2 "$2 missing: $1"
  elif ! grep -q '[^[:space:]]' "$1"; then
    fail 2 "$2 has no entry: $1"
  elif grep -q '^[[:space:]]*$' "$1"; then
    # A blank line in a grep -F -f pattern file matches every line.
    fail 2 "$2 has a blank line: $1:$(grep -n '^[[:space:]]*$' "$1" | head -1 | cut -d: -f1)"
  else
    return 0
  fi
  return 1
}

: >"$WORK/allow"
: >"$WORK/deny"
: >"$WORK/present" # allowlisted entries whose source exists
if [ ! -d "$AGENTS_SRC" ]; then fail 2 "AGENTS_SRC missing: $AGENTS_SRC"; fi
# awk 1 ends the last line with a newline, so read loops cannot skip it.
if list_ok "$ALLOWLIST" allowlist; then awk 1 "$ALLOWLIST" >"$WORK/allow"; fi
if list_ok "$DENYLIST" denylist; then cut -f1 "$DENYLIST" >"$WORK/deny"; fi
list_ok "$PRIVATE_TERMS" "private-terms file" || true
for f in "$RULES_SRC_CLAUDE" "$RULES_SRC_CODEX"; do
  if [ ! -f "$f" ]; then fail 2 "rule source missing: $f"; fi
done
while IFS= read -r e; do
  case $e in
    _shared/*) if [ -f "$AGENTS_SRC/$e" ]; then echo "$e" >>"$WORK/present"; else fail 2 "allowlisted source missing: $AGENTS_SRC/$e"; fi ;;
    *) if [ -d "$AGENTS_SRC/$e" ]; then echo "$e" >>"$WORK/present"; else fail 2 "allowlisted source missing: $AGENTS_SRC/$e"; fi ;;
  esac
done <"$WORK/allow"

# --- phase 3: forbidden entries. A later tool version may load more paths, so no
# CLAUDE.md, AGENTS.md or dot entry goes into the repo; symlinks would leak whatever
# they point at.
forbidden() { # forbidden <path>: print each forbidden entry at or under <path>
  find "$1" \( -type l -o -name CLAUDE.md -o -name AGENTS.md -o \( -name '.*' ! -name .DS_Store \) \) -print
}
: >"$WORK/forbidden"
while IFS= read -r e; do
  forbidden "$AGENTS_SRC/$e" >>"$WORK/forbidden"
done <"$WORK/present"
if [ -d "$AGENTS_DST" ]; then
  forbidden "$AGENTS_DST" >>"$WORK/forbidden"
  # .gitignore keeps an untracked .DS_Store out of git add, not a tracked one.
  # git's own exit code decides; a git error is an internal error, not a pass.
  git -C "$AGENTS_DST" ls-files -z -- . >"$WORK/tracked" || die "git ls-files failed in $AGENTS_DST"
  tr '\0' '\n' <"$WORK/tracked" >"$WORK/tracked.lines"
  grep_ok -E '(^|/)\.DS_Store$' "$WORK/tracked.lines" >"$WORK/tracked.ds"
  while IFS= read -r p; do echo "$AGENTS_DST/$p (tracked by git)"; done <"$WORK/tracked.ds" >>"$WORK/forbidden"
fi
while IFS= read -r p; do fail 3 "forbidden entry: $p"; done <"$WORK/forbidden"

# --- phase 4: lists. Every producer writes a file before a loop reads it, so a
# failing producer trips the ERR trap instead of vanishing in a subshell.
sort -u "$WORK/allow" >"$WORK/allow.s"
sort -u "$WORK/deny" >"$WORK/deny.s"
sort -u "$WORK/allow.s" "$WORK/deny.s" >"$WORK/listed"
comm -12 "$WORK/allow.s" "$WORK/deny.s" >"$WORK/both"
while IFS= read -r e; do fail 1 "in both allowlist and denylist: $e"; done <"$WORK/both"
if [ -d "$AGENTS_SRC" ]; then
  find "$AGENTS_SRC" -mindepth 1 -maxdepth 1 ! -name _shared ! -name .DS_Store -exec basename {} \; >"$WORK/entries.raw"
  if [ -d "$AGENTS_SRC/_shared" ]; then
    find "$AGENTS_SRC/_shared" -mindepth 1 -maxdepth 1 ! -name .DS_Store -exec basename {} \; >"$WORK/shared.raw"
    while IFS= read -r e; do echo "_shared/$e"; done <"$WORK/shared.raw" >>"$WORK/entries.raw"
  fi
  sort "$WORK/entries.raw" >"$WORK/entries"
  comm -23 "$WORK/entries" "$WORK/listed" >"$WORK/unlisted"
  while IFS= read -r e; do fail 1 "in neither allowlist nor denylist: $AGENTS_SRC/$e"; done <"$WORK/unlisted"
  comm -13 "$WORK/entries" "$WORK/deny.s" >"$WORK/gone"
  while IFS= read -r e; do fail 1 "denylisted entry no longer exists: $AGENTS_SRC/$e"; done <"$WORK/gone"
fi
present_paths=()
while IFS= read -r e; do present_paths+=("$AGENTS_SRC/$e"); done <"$WORK/present"
if [ ${#present_paths[@]} -gt 0 ]; then
  # A helper that an allowlisted file calls must ship too. Trailing dots are
  # sentence ends, not part of the file name. A mention of a file that does not
  # exist is a placeholder in an example (_shared/x.sh), not a call.
  grep_ok -rHoE --exclude=.DS_Store '_shared/[A-Za-z0-9._-]+' "${present_paths[@]}" >"$WORK/mentions.raw"
  sed 's/\.*$//' "$WORK/mentions.raw" | sort -u >"$WORK/mentions"
  while IFS= read -r hit; do
    ref=${hit##*:}
    if [ -e "$AGENTS_SRC/$ref" ] && ! grep -qxF "$ref" "$WORK/allow.s"; then
      fail 1 "${hit%:*} mentions $ref, which is not allowlisted"
    fi
  done <"$WORK/mentions"
  # A denylisted helper can also be reached without the _shared/ prefix, for
  # example through $(dirname "$0").
  grep_ok '^_shared/' "$WORK/deny.s" >"$WORK/deny.helpers"
  while IFS= read -r e; do
    name=${e#_shared/}
    grep_ok -rlFw --exclude=.DS_Store -- "$name" "${present_paths[@]}" >"$WORK/callers"
    while IFS= read -r file; do fail 1 "$file mentions denylisted helper $name"; done <"$WORK/callers"
  done <"$WORK/deny.helpers"
fi

if [ "$rc" -ne 0 ]; then exit "$rc"; fi

# --- staging: both modes scan and compare the same copy
mkdir -p "$STAGE/skills" "$STAGE/rules"
while IFS= read -r e; do
  case $e in
    _shared/*)
      mkdir -p "$STAGE/skills/_shared"
      "$RSYNC" -r -p --no-links --exclude=.DS_Store "$AGENTS_SRC/$e" "$STAGE/skills/_shared/" || die "rsync failed staging $e"
      ;;
    *) "$RSYNC" -r -p --no-links --exclude=.DS_Store "$AGENTS_SRC/$e/" "$STAGE/skills/$e/" || die "rsync failed staging $e" ;;
  esac
done <"$WORK/allow"
cp "$RULES_SRC_CODEX" "$STAGE/rules/AGENTS.global.md"

# The target files that --update will not overwrite; --check scans all of agents/.
mkdir -p "$DSTSCAN"
if [ "$MODE" = update ]; then
  "$RSYNC" -r --no-links --exclude=.DS_Store --exclude=/skills/ --exclude=/rules/AGENTS.global.md \
    "$AGENTS_DST/" "$DSTSCAN/" || die "rsync failed copying $AGENTS_DST for the scan"
else
  "$RSYNC" -r --no-links --exclude=.DS_Store "$AGENTS_DST/" "$DSTSCAN/" || die "rsync failed copying $AGENTS_DST for the scan"
fi

# --- phase 5: publication scan. Reports path and line only: the matched text may
# be the secret or the private term itself.
for dir in "$STAGE" "$DSTSCAN"; do
  report=$WORK/gitleaks-$(basename "$dir").json
  if gitleaks dir --no-banner --redact --config "$GITLEAKS_CONFIG" \
    --report-format json --report-path "$report" "$dir" >/dev/null 2>"$WORK/gitleaks.err"; then
    :
  elif [ -s "$report" ] && [ "$(jq length "$report")" -gt 0 ]; then
    jq -r '.[] | "\(.File):\(.StartLine) (\(.RuleID))"' "$report" | unstage >"$WORK/leaks"
    while IFS= read -r hit; do fail 4 "gitleaks: $hit"; done <"$WORK/leaks"
  else
    die "gitleaks failed on $dir: $(cat "$WORK/gitleaks.err")"
  fi
done
grep_ok -rinF --exclude=.DS_Store -f "$PRIVATE_TERMS" "$STAGE" "$DSTSCAN" >"$WORK/terms.raw"
cut -d: -f1,2 "$WORK/terms.raw" | unstage >"$WORK/terms.hits"
while IFS= read -r hit; do fail 4 "private term at $hit"; done <"$WORK/terms.hits"

# --- phase 6: shellcheck, on name or shebang, so extension-less scripts count
is_shell() {
  local first words interp w skip=0
  case $1 in *.sh | *.bash) return 0 ;; esac
  IFS= read -r first <"$1" || [ -n "$first" ] || return 1
  case $first in '#!'*) ;; *) return 1 ;; esac
  read -r -a words <<<"${first#\#!}"
  interp=${words[0]:-}
  if [ "${interp##*/}" = env ]; then
    # env options, the operands of -u/-P/-C, and NAME=value settings come
    # before the command: #!/usr/bin/env -S FOO=bar bash
    interp=
    for w in "${words[@]:1}"; do
      if [ "$skip" -eq 1 ]; then
        skip=0
        continue
      fi
      case $w in
        -u | -P | -C) skip=1 ;;
        -* | *=*) ;;
        *) interp=$w && break ;;
      esac
    done
  fi
  interp=${interp##*/}
  [ "$interp" = sh ] || [ "$interp" = bash ]
}
if [ "$MODE" = update ]; then
  find "$STAGE" -type f -print0 >"$WORK/staged"
  scripts=()
  while IFS= read -r -d '' f; do
    if is_shell "$f"; then scripts+=("$f"); fi
  done <"$WORK/staged"
  if [ ${#scripts[@]} -gt 0 ]; then
    if shellcheck -S warning "${scripts[@]}" >"$WORK/shellcheck.out" 2>&1; then
      :
    elif [ $? -eq 1 ]; then
      unstage <"$WORK/shellcheck.out" >&2
      fail 5 "shellcheck reported warnings (above)"
    else
      die "shellcheck failed: $(cat "$WORK/shellcheck.out")"
    fi
  fi
fi

# --- phase 7: drift
claude_export_state() { # prints why CLAUDE.global.md needs a hand edit, or nothing
  local f=$AGENTS_DST/rules/CLAUDE.global.md want have
  if [ ! -f "$f" ]; then
    echo "$f missing: hand-edit it from $RULES_SRC_CLAUDE"
    return
  fi
  want=$(shasum -a 256 "$RULES_SRC_CLAUDE" | cut -d' ' -f1)
  have=$(sed -n '1s/^<!-- Source-sha256: \([0-9a-f]\{64\}\) -->$/\1/p' "$f")
  if [ "$have" != "$want" ]; then
    echo "$f records source sha256 ${have:-none}, but $RULES_SRC_CLAUDE is now $want: hand-edit the export"
  fi
}
exec_files() { # sorted relative paths of files with the owner exec bit set
  (cd "$1" && find . -type f ! -name .DS_Store -perm -0100) | sort
}
if [ "$MODE" = check ]; then
  if [ -d "$AGENTS_DST/skills" ]; then
    # -c compares bytes. openrsync still itemizes a file whose only change is its
    # mtime, with a line that starts with "." (nothing to transfer); git ignores
    # mtime, so those lines are not drift.
    "$RSYNC" -r -c -n -i --delete --no-links --exclude=.DS_Store "$STAGE/skills/" "$AGENTS_DST/skills/" >"$WORK/drift" ||
      die "rsync failed comparing $AGENTS_DST/skills"
    while IFS= read -r line; do
      case $line in .*) ;; *) fail 1 "drift in $AGENTS_DST/skills: $line" ;; esac
    done <"$WORK/drift"
    # rsync -c misses a lost exec bit.
    exec_files "$STAGE/skills" >"$WORK/exec.stage"
    exec_files "$AGENTS_DST/skills" >"$WORK/exec.target"
    diff "$WORK/exec.stage" "$WORK/exec.target" >"$WORK/exec.diff" || [ $? -eq 1 ]
    sed -n 's/^[<>] \.\///p' "$WORK/exec.diff" >"$WORK/exec.lines"
    while IFS= read -r line; do fail 1 "exec bit differs in $AGENTS_DST/skills: $line"; done <"$WORK/exec.lines"
  else
    fail 1 "missing: $AGENTS_DST/skills"
  fi
  if [ ! -f "$AGENTS_DST/rules/AGENTS.global.md" ]; then
    fail 1 "missing: $AGENTS_DST/rules/AGENTS.global.md"
  elif ! cmp -s "$RULES_SRC_CODEX" "$AGENTS_DST/rules/AGENTS.global.md"; then
    fail 1 "$AGENTS_DST/rules/AGENTS.global.md differs from $RULES_SRC_CODEX"
  fi
  state=$(claude_export_state)
  if [ -n "$state" ]; then fail 1 "$state"; fi
  exit "$rc"
fi

# --- --update writes only after every phase passed
if [ "$rc" -ne 0 ]; then exit "$rc"; fi
mkdir -p "$AGENTS_DST/skills" "$AGENTS_DST/rules"
# -p with -c restores a lost exec bit on a file whose bytes already match.
"$RSYNC" -r -p -c --delete --no-links --exclude=.DS_Store "$STAGE/skills/" "$AGENTS_DST/skills/" ||
  die "rsync failed writing $AGENTS_DST/skills"
cp "$STAGE/rules/AGENTS.global.md" "$AGENTS_DST/rules/AGENTS.global.md"
state=$(claude_export_state)
if [ -n "$state" ]; then echo "sync-agents: note: $state; --check exits 1 until then" >&2; fi
exit 0
