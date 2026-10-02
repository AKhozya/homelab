#!/usr/bin/env bash
# Mutation-test one anchor: break the code on purpose, prove a test catches it.
#
# Usage
#   mutate.sh --file <path> --anchor <text> --replace <text> \
#             --test <cmd> (--check <cmd> | --no-check) [options]
#
#   --anchor-file <path> / --replace-file <path>
#                    read the text from a file instead of the command line.
#                    Use this for anything multi-line: the text never passes
#                    through the shell, so quoting cannot eat it.
#   --label <name>   name shown in the verdict line (default: file + first anchor line)
#   --no-baseline    skip the pre-flight suite run on the clean tree
#
# Verdict goes to stdout, everything else to stderr, so `mutate.sh ... | tail -1`
# is safe.
#
# Exit 0 KILLED   — suite went red, the anchor is covered
#      1 SURVIVED — suite stayed green, the anchor is a coverage gap
#      2 VOID     — the run proved nothing, ignore any verdict you inferred
#
# VOID is the point of this script. Each guard below fired for real and turned a
# believable verdict into a lie: an anchor that also matched a comment, a mutant
# that did not compile so the suite failed for the wrong reason, a heredoc
# quoting slip that never applied the edit, an interactive `cp` alias that
# skipped the restore, and a SIGPIPE from `| head` that stranded a mutant in the
# working tree.
#
# Precondition, not enforced: the test and check commands must not write to the file
# under test. It is compared against the mutant before and after the suite, which catches
# a formatter or generator that moves it, but a command that rewrites the file and puts
# it back mid-run defeats any before/after comparison. Point --test at a suite, not at a
# script that edits its own input.

set -uo pipefail

FILE=""
TEST_CMD=""
CHECK_CMD=""
LABEL=""
NO_CHECK=0
BASELINE=1
ANCHOR_SET=0
REPLACE_SET=0
BACKUP=""

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mutate.XXXXXX")" || exit 2
ANCHOR_F="$TMP/anchor"
REPLACE_F="$TMP/replace"
LOG="$TMP/log"

log() { printf '%s\n' "$*" >&2; }

# shellcheck disable=SC2329  # invoked by trap
cleanup() {
  local rc=$?
  # Ignored, not cleared: a second Ctrl-C landing inside the restore below would
  # otherwise kill the script with the mutant half written back.
  trap '' INT TERM PIPE
  trap - EXIT
  if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
    command cp -f "$BACKUP" "$FILE"
    if cmp -s "$BACKUP" "$FILE"; then
      rm -rf "$TMP"
    else
      log "MUTANT LEFT IN TREE: could not restore $FILE"
      log "  backup kept at: $BACKUP"
      log "  recover with:   command cp -f $BACKUP $FILE"
      printf 'VOID  restore failed\n'
      exit 2
    fi
  else
    rm -rf "$TMP"
  fi
  exit "$rc"
}
# PIPE is trapped so a closed stdout (`| head`) unwinds through the restore
# instead of killing the script with the mutant still applied.
trap cleanup EXIT INT TERM PIPE

void() {
  log "VOID: $*"
  printf 'VOID  %s  (%s)\n' "$LABEL" "$*"
  exit 2
}

usage() {
  sed -n '2,20p' "$0" >&2
  exit 2
}

# `shift 2` on a lone trailing flag fails without consuming anything, and with
# errexit off that spins the parser forever.
need_val() {
  [ "$1" -ge 2 ] || {
    log "$2 needs a value"
    exit 2
  }
}

while [ $# -gt 0 ]; do
  case "$1" in
  --file)
    need_val $# "$1"
    FILE="$2"
    shift 2
    ;;
  --anchor)
    need_val $# "$1"
    printf '%s' "$2" >"$ANCHOR_F"
    ANCHOR_SET=1
    shift 2
    ;;
  --anchor-file)
    need_val $# "$1"
    command cp -f "$2" "$ANCHOR_F" || exit 2
    ANCHOR_SET=1
    shift 2
    ;;
  --replace)
    need_val $# "$1"
    printf '%s' "$2" >"$REPLACE_F"
    REPLACE_SET=1
    shift 2
    ;;
  --replace-file)
    need_val $# "$1"
    command cp -f "$2" "$REPLACE_F" || exit 2
    REPLACE_SET=1
    shift 2
    ;;
  --test)
    need_val $# "$1"
    TEST_CMD="$2"
    shift 2
    ;;
  --check)
    need_val $# "$1"
    CHECK_CMD="$2"
    shift 2
    ;;
  --no-check)
    NO_CHECK=1
    shift
    ;;
  --no-baseline)
    BASELINE=0
    shift
    ;;
  --label)
    need_val $# "$1"
    LABEL="$2"
    shift 2
    ;;
  -h | --help) usage ;;
  *)
    log "unknown argument: $1"
    usage
    ;;
  esac
done

[ -n "$FILE" ] || usage
[ "$ANCHOR_SET" = 1 ] || usage
[ "$REPLACE_SET" = 1 ] || usage
[ -n "$TEST_CMD" ] || usage
[ -f "$FILE" ] || {
  log "no such file: $FILE"
  exit 2
}
command -v python3 >/dev/null || {
  log "python3 required"
  exit 2
}

# Requiring the decision rather than defaulting it: without a compile/lint gate a
# mutant that does not build reports KILLED while proving nothing.
if [ -z "$CHECK_CMD" ] && [ "$NO_CHECK" = 0 ]; then
  log "--check <cmd> is required (or pass --no-check for a language with no build step)"
  exit 2
fi

if [ -z "$LABEL" ]; then
  LABEL="$FILE: $(head -1 "$ANCHOR_F" | cut -c1-60)"
fi

if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  git diff --quiet -- "$FILE" 2>/dev/null ||
    log "note: $FILE has uncommitted changes; git checkout is not a recovery path here"
fi

# The backup is taken before anything else runs, and BACKUP stays empty until it is
# proven good. A half-written backup that cleanup restored would destroy the source,
# and a baseline suite that rewrites the file (a formatter, a generator) would leave
# the "original" already modified.
PROVISIONAL="$TMP/backup"
command cp -f "$FILE" "$PROVISIONAL" || void "backup copy failed"
cmp -s "$FILE" "$PROVISIONAL" || void "backup does not match source"
BACKUP="$PROVISIONAL"

# A suite that is already red marks every mutant KILLED.
if [ "$BASELINE" = 1 ]; then
  if ! sh -c "$TEST_CMD" >"$LOG" 2>&1; then
    log "baseline suite is RED before any mutation:"
    tail -20 "$LOG" >&2
    void "baseline red"
  fi
  cmp -s "$FILE" "$BACKUP" || void "the test command rewrote $FILE"
fi

# Byte-exact literal replace in python, so the anchor never crosses a shell or
# regex boundary. Exit 3 means the anchor count was not 1.
COUNT="$(
  python3 - "$FILE" "$ANCHOR_F" "$REPLACE_F" <<'PY'
import pathlib, sys
target = pathlib.Path(sys.argv[1])
anchor = pathlib.Path(sys.argv[2]).read_bytes()
repl = pathlib.Path(sys.argv[3]).read_bytes()
src = target.read_bytes()
n = src.count(anchor)
print(n)
if n != 1:
    sys.exit(3)
target.write_bytes(src.replace(anchor, repl, 1))
PY
)"
rc=$?
if [ "$rc" = 3 ]; then
  if [ "$COUNT" = 0 ]; then
    void "anchor not found"
  else
    void "anchor matches $COUNT places, extend it until it is unique"
  fi
fi
[ "$rc" = 0 ] || void "mutation failed (python exit $rc)"

# Catches the case where anchor and replacement are the same text.
if cmp -s "$FILE" "$BACKUP"; then
  void "file unchanged after mutation"
fi
MUTANT="$TMP/mutant"
command cp -f "$FILE" "$MUTANT"

if [ "$NO_CHECK" = 0 ]; then
  if ! sh -c "$CHECK_CMD" >"$LOG" 2>&1; then
    log "mutant does not pass --check, so the suite result means nothing:"
    tail -20 "$LOG" >&2
    void "mutant fails check"
  fi
fi

# A check or generator step that rewrites the file would run the suite against
# something other than the mutant, and a green suite would read as SURVIVED.
cmp -s "$FILE" "$MUTANT" || void "the check command rewrote $FILE; the mutant is gone"

sh -c "$TEST_CMD" >"$LOG" 2>&1
suite=$?

# Checked after the run as well as before it: a suite that repairs the file it is testing
# passes for the wrong reason, and green would read as SURVIVED.
cmp -s "$FILE" "$MUTANT" || void "the test command rewrote $FILE; the suite did not finish against the mutant"

if [ "$suite" = 0 ]; then
  printf 'SURVIVED  %s\n' "$LABEL"
  exit 1
fi

printf 'KILLED  %s\n' "$LABEL"
exit 0
