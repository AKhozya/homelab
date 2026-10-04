#!/usr/bin/env bash
#
# Tests scripts/sync-agents.sh against fake trees. Each case builds a fresh
# fixture under its own HOME and TMPDIR, with a uname shim first on PATH; nothing
# reads the real dotfiles or writes the repo's agents/.
# Run: bash scripts/sync-agents.test.sh

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SCRIPT=$HERE/sync-agents.sh
REPO_ROOT=$(dirname "$HERE")
ORIG_PATH=$PATH
ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$ROOT"' EXIT
case $ROOT/ in
  "$REPO_ROOT"/*)
    echo "refusing: test root $ROOT resolves inside the repo" >&2
    exit 2
    ;;
esac

n=0
passed=0
failed=0
bad() {
  failed=$((failed + 1))
  echo "FAIL: $*" >&2
}

setup() {
  n=$((n + 1))
  W=$ROOT/case$n
  DST=$W/repo/agents
  SRC=$W/src
  mkdir -p "$W/home" "$W/bin" "$W/tmp" "$SRC/_shared" "$SRC/alpha/scripts" "$SRC/beta" "$SRC/gamma" \
    "$DST/sync" "$DST/rules"
  printf '#!/bin/sh\necho "${FAKE_UNAME:-Darwin}"\n' >"$W/bin/uname"
  printf '#!/bin/sh\nexit 1\n' >"$W/bin/fail-rsync"
  chmod +x "$W/bin/uname" "$W/bin/fail-rsync"

  printf 'alpha skill\n' >"$SRC/alpha/SKILL.md"
  printf '#!/usr/bin/env bash\necho alpha\n' >"$SRC/alpha/scripts/run"
  printf 'beta skill\n' >"$SRC/beta/SKILL.md"
  printf 'gamma skill\n' >"$SRC/gamma/SKILL.md"
  printf '#!/usr/bin/env bash\necho help\n' >"$SRC/_shared/help.sh"
  printf '#!/usr/bin/env bash\necho deny\n' >"$SRC/_shared/deny.sh"
  chmod +x "$SRC/alpha/scripts/run" "$SRC/_shared/help.sh" "$SRC/_shared/deny.sh"

  printf 'alpha\nbeta\n_shared/help.sh\n' >"$DST/sync/allowlist.txt"
  printf 'readme\n' >"$DST/README.md"
  printf 'gamma\tthird-party\n_shared/deny.sh\tno caller\n' >"$W/denylist.txt"
  printf 'zqprivateterm\n' >"$W/terms.txt"
  printf 'claude rules\n' >"$W/claude.md"
  printf 'codex rules\n' >"$W/codex.md"
  git -C "$W/repo" init -q

  export HOME=$W/home PATH=$W/bin:$ORIG_PATH TMPDIR=$W/tmp AGENTS_SRC=$SRC AGENTS_DST=$DST \
    RULES_SRC_CLAUDE=$W/claude.md RULES_SRC_CODEX=$W/codex.md PRIVATE_TERMS=$W/terms.txt \
    DENYLIST=$W/denylist.txt
  unset RSYNC FAKE_UNAME
}

run() { # run <--check|--update>; sets out and code
  out=$("$SCRIPT" "$1" 2>&1)
  code=$?
}

write_export() {
  printf '<!-- Source-sha256: %s -->\nhand-edited export\n' \
    "$(shasum -a 256 "$RULES_SRC_CLAUDE" | cut -d' ' -f1)" >"$DST/rules/CLAUDE.global.md"
}

# A fixture after a clean --update and a current CLAUDE.global.md.
baseline() {
  setup
  run --update
  if [ "$code" -ne 0 ]; then bad "baseline --update: exit $code: $out"; fi
  write_export
}

sig() { # everything git or the script could care about in the target
  (cd "$DST" && find . | sort && find . -type f -exec shasum -a 256 {} + | sort && find . -type f -perm -0100 | sort)
}

expect() { # expect <label> <mode> <exit code>
  run "$2"
  if [ "$code" -eq "$3" ]; then
    passed=$((passed + 1))
  else
    bad "$1: $2 exited $code, want $3. Output: $out"
  fi
  # Also fail on an "internal error" line under any exit code but 70.
  # An internal failure that does not reach the exit code would otherwise pass.
  case $3:$out in 70:*) ;; *"internal error"*) bad "$1: $2 reported an internal error: $out" ;; esac
}

# --update exits <code> and leaves agents/ unchanged.
expect_update_refused() { # expect_update_refused <label> <exit code>
  local before
  before=$(sig)
  expect "$1" --update "$2"
  if [ "$(sig)" != "$before" ]; then bad "$1: --update changed agents/"; fi
}

rand() { # rand <charset> <length>
  head -c 4096 /dev/urandom | LC_ALL=C tr -dc "$1" | head -c "$2"
}

baseline
expect "second --update" --update 0
expect "second --update" --check 0

# A new mtime or a group-write bit is not drift: git records neither.
baseline
touch -t 202001010000 "$DST/skills/beta/SKILL.md"
chmod 664 "$DST/skills/alpha/SKILL.md"
expect "mtime and mode 664" --check 0

for c in byte exec deleted extra-file extra-folder; do
  baseline
  case $c in
    byte) printf 'x' >>"$DST/skills/alpha/SKILL.md" ;;
    exec) chmod -x "$DST/skills/alpha/scripts/run" ;;
    deleted) rm "$DST/skills/beta/SKILL.md" ;;
    extra-file) printf 'x\n' >"$DST/skills/alpha/extra.md" ;;
    extra-folder) mkdir -p "$DST/skills/stray" && printf 'x\n' >"$DST/skills/stray/f.md" ;;
  esac
  expect "drift $c" --check 1
  expect "repair $c" --update 0
  expect "after repair $c" --check 0
done

# --update never writes the hand-written files.
baseline
printf 'alpha skill, changed\n' >"$SRC/alpha/SKILL.md"
cp "$DST/README.md" "$W/readme.before"
cp "$DST/sync/allowlist.txt" "$W/allow.before"
cp "$DST/rules/CLAUDE.global.md" "$W/export.before"
expect "update with hand-written files" --update 0
for pair in "README.md readme.before" "sync/allowlist.txt allow.before" "rules/CLAUDE.global.md export.before"; do
  set -- $pair
  if ! cmp -s "$DST/$1" "$W/$2"; then bad "--update changed $1"; fi
done

# An allowlist whose last line has no newline still copies that entry.
baseline
printf 'alpha\nbeta\n_shared/help.sh' >"$DST/sync/allowlist.txt"
rm -r "$DST/skills/_shared"
expect "allowlist without a final newline" --update 0
if [ ! -f "$DST/skills/_shared/help.sh" ]; then bad "last allowlist line skipped"; fi

baseline
rm "$SRC/alpha/scripts/run"
expect "file deleted from source" --update 0
if [ -e "$DST/skills/alpha/scripts/run" ]; then bad "deleted source file still in agents/"; fi
baseline
printf 'alpha\n_shared/help.sh\n' >"$DST/sync/allowlist.txt"
printf 'beta\tmoved\n' >>"$W/denylist.txt"
expect "skill moved to the denylist" --update 0
if [ -e "$DST/skills/beta" ]; then bad "denylisted skill still in agents/"; fi

for c in new-skill new-helper both-lists missing-denied; do
  baseline
  case $c in
    new-skill) mkdir "$SRC/delta" && printf 'delta\n' >"$SRC/delta/SKILL.md" ;;
    new-helper) printf 'x\n' >"$SRC/_shared/new.sh" ;;
    both-lists) printf 'beta\tboth\n' >>"$W/denylist.txt" ;;
    missing-denied) rm -r "$SRC/gamma" ;;
  esac
  expect "list $c" --check 1
  expect_update_refused "list $c" 1
done

# Finder writes .DS_Store anywhere; it is not an entry in either tree.
baseline
for d in "$SRC" "$SRC/_shared" "$SRC/alpha" "$DST/skills" "$DST/skills/alpha"; do printf 'x' >"$d/.DS_Store"; done
expect "Finder files" --check 0

# A mention of a denylisted helper is a call; a placeholder that names no real file is not.
for c in skill helper dirname; do
  baseline
  case $c in
    skill) printf 'Run ~/.agents/skills/_shared/deny.sh first.\n' >>"$SRC/alpha/SKILL.md" ;;
    helper) printf '# see deny.sh\n' >>"$SRC/_shared/help.sh" ;;
    dirname) printf '"$(dirname "$0")/deny.sh"\n' >>"$SRC/_shared/help.sh" ;;
  esac
  expect "mention $c" --check 1
  # --update has no drift phase, so only the list finding can make it exit 1.
  expect_update_refused "mention $c" 1
done
baseline
printf 'Put a new helper in _shared/x.sh.\n' >>"$SRC/alpha/SKILL.md"
run --update
expect "placeholder mention" --check 0

# A renamed skill exits 2, and the report also names the new, unlisted entry.
baseline
mv "$SRC/alpha" "$SRC/alpha2"
expect "renamed skill" --check 2
case $out in *"$SRC/alpha2"*) ;; *) bad "renamed skill: report does not name alpha2: $out" ;; esac

for c in symlink claude agents dot-claude dotfile; do
  baseline
  case $c in
    symlink) ln -s /etc/hosts "$SRC/alpha/link" ;;
    claude) printf 'x\n' >"$SRC/alpha/CLAUDE.md" ;;
    agents) printf 'x\n' >"$SRC/beta/AGENTS.md" ;;
    dot-claude) mkdir "$SRC/alpha/.claude" && printf '{}\n' >"$SRC/alpha/.claude/settings.json" ;;
    dotfile) printf 'x\n' >"$SRC/alpha/.env" ;;
  esac
  expect "forbidden $c" --check 3
  expect_update_refused "forbidden $c" 3
done

# .gitignore does not untrack a .DS_Store that git already tracks.
baseline
printf 'x' >"$DST/skills/.DS_Store"
git -C "$W/repo" add -f agents/skills/.DS_Store
expect "tracked .DS_Store" --check 3
expect_update_refused "tracked .DS_Store" 3
rm "$DST/skills/.DS_Store"
expect "tracked .DS_Store, deleted but not unstaged" --check 3
expect_update_refused "tracked .DS_Store, deleted but not unstaged" 3
git -C "$W/repo" rm -q --cached agents/skills/.DS_Store
expect "tracked .DS_Store after git rm --cached" --check 0

baseline
printf 'zqprivateterm' >"$DST/.DS_Store"
printf 'zqprivateterm' >"$DST/skills/alpha/.DS_Store"
expect "untracked .DS_Store with a private term" --check 0

baseline
printf 'x\n' >"$DST/rules/CLAUDE.md"
expect "CLAUDE.md in the target" --check 3
expect "CLAUDE.md in the target" --update 3

for c in allowed-source claude-src codex-src terms-missing terms-empty terms-blank terms-space \
  deny-missing deny-empty deny-blank linux linux-no-tmp; do
  baseline
  case $c in
    allowed-source) rm -r "$SRC/beta" ;;
    claude-src) rm "$W/claude.md" ;;
    codex-src) rm "$W/codex.md" ;;
    terms-missing) rm "$W/terms.txt" ;;
    terms-empty) : >"$W/terms.txt" ;;
    terms-blank) printf 'zqprivateterm\n\n' >"$W/terms.txt" ;;
    terms-space) printf 'zqprivateterm\n  \n' >"$W/terms.txt" ;;
    deny-missing) rm "$W/denylist.txt" ;;
    deny-empty) : >"$W/denylist.txt" ;;
    deny-blank) printf 'gamma\tx\n\n_shared/deny.sh\tx\n' >"$W/denylist.txt" ;;
    linux) export FAKE_UNAME=Linux ;;
    # The host check runs before anything needs a temporary folder.
    linux-no-tmp) export FAKE_UNAME=Linux TMPDIR=$W/none ;;
  esac
  expect "input $c" --check 2
  expect_update_refused "input $c" 2
done

key=AKIA$(rand 'A-Z2-7' 16)
sqlvalue=$(rand 'a-z0-9' 12)
if [ ${#key} -ne 20 ] || [ ${#sqlvalue} -ne 12 ]; then bad "could not build test values"; fi
for c in term key key-in-codex-rules sql; do
  baseline
  case $c in
    term) printf 'Ask ZQPrivateTerm.\n' >>"$SRC/alpha/SKILL.md" ;;
    key) printf 'aws_access_key_id = %s\n' "$key" >>"$SRC/beta/SKILL.md" ;;
    key-in-codex-rules) printf 'aws_access_key_id = %s\n' "$key" >>"$W/codex.md" ;;
    # Assembled here so this file never holds a line the repo's rule matches.
    sql) printf '%s %s %s %s\n' "ALTER USER app" "IDENTIFIED" "BY" "'$sqlvalue';" >"$SRC/alpha/notes.sql" ;;
  esac
  expect_update_refused "publication $c" 4
  expect "publication $c" --check 4
done
# A finding names the source path even when it holds sed syntax.
baseline
mv "$SRC" "$W/s&r|c"
SRC="$W/s&r|c"
export AGENTS_SRC=$SRC
printf 'Ask zqprivateterm.\n' >>"$SRC/alpha/SKILL.md"
expect "private term under a path with & and |" --update 4
case $out in *"private term at $SRC/alpha/SKILL.md:2"*) ;; *) bad "finding does not name the source path: $out" ;; esac
baseline
printf 'Built for zqprivateterm.\n' >>"$DST/README.md"
expect "private term in README.md" --check 4
expect "private term in README.md" --update 4

# The shebang identifies a shell script that has no file extension.
for c in env bash-e env-assignment; do
  baseline
  case $c in
    env) printf '#!/usr/bin/env bash\nunused=1\n' >"$SRC/alpha/scripts/tool" ;;
    bash-e) printf '#!/bin/bash -e\nunused=1\n' >"$SRC/alpha/scripts/tool" ;;
    env-assignment) printf '#!/usr/bin/env -S FOO=bar bash\nunused=1\n' >"$SRC/alpha/scripts/tool" ;;
  esac
  expect_update_refused "shellcheck $c" 5
done
baseline
printf '#!/usr/bin/env python3\nimport os\ncd "$1"\n' >"$SRC/alpha/scripts/tool"
expect "python script is not shellchecked" --update 0

baseline
rm "$DST/rules/CLAUDE.global.md"
expect "CLAUDE.global.md missing" --check 1
baseline
printf 'changed\n' >>"$W/claude.md"
expect "CLAUDE.md source changed" --check 1
expect "CLAUDE.md source changed, --update still copies" --update 0
baseline
printf 'changed\n' >>"$W/codex.md"
expect "AGENTS.md source changed" --check 1

# An internal error leaves no staging folder.
for mode in --check --update; do
  baseline
  export RSYNC=$W/bin/fail-rsync
  expect "rsync fails" "$mode" 70
  if [ -n "$(ls -A "$TMPDIR")" ]; then bad "rsync fails $mode: left $(ls -A "$TMPDIR") in TMPDIR"; fi
done

echo "sync-agents tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
