#!/usr/bin/env bash
# The "Row 16 cases" table in the progressive-disclosure plan defines the first seven cases.
set -uo pipefail
exec </dev/null

here="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ms="$here/md-sections.sh"
[[ -x "$ms" ]] || {
  echo "no executable md-sections.sh next to this script" >&2
  exit 2
}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/md-sections-selfcheck.XXXXXX") || exit 2
tmp=$(CDPATH='' cd -- "$tmp" && pwd -P) || exit 2
trap 'chmod -R u+r "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
pass=0 fail=0 skip=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1"
}
# expect <name> <want exit> <want stderr> <args...>; the wanted stdout is in $tmp/want.
expect() {
  local name=$1 wantrc=$2 wanterr=$3 rc=0
  shift 3
  "$ms" "$@" >"$tmp/out" 2>"$tmp/err" || rc=$?
  printf '%s' "$wanterr" >"$tmp/wanterr"
  if cmp -s "$tmp/out" "$tmp/want" && cmp -s "$tmp/err" "$tmp/wanterr" && [[ $rc -eq $wantrc ]]; then
    ok "$name"
  else
    bad "$name: rc=$rc"
    printf '     stdout: %s\n     stderr: %s\n' "$(od -c "$tmp/out" | head -5)" "$(cat "$tmp/err")"
  fi
}
want() { printf '%s\n' "$@" >"$tmp/want"; }
none() { : >"$tmp/want"; }
F='```'
T='~~~'

printf '%s\n' '## A' "$F" '## fake' 'needle' "$F" 'needle' >"$tmp/backtick.md"
want 1
expect "backtick fence: count" 0 '' count "$tmp/backtick.md"
want '## A: needle' '## A: needle'
expect "backtick fence: find" 0 '' find "$tmp/backtick.md" needle

printf '%s\n' '## A' "$T" '## fake' 'needle' "$T" 'needle' >"$tmp/tilde.md"
want 1
expect "tilde fence: count" 0 '' count "$tmp/tilde.md"
want '## A: needle' '## A: needle'
expect "tilde fence: find" 0 '' find "$tmp/tilde.md" needle

printf '%s\n' '## A' "$F$F" "$F" '## fake' "$F$F" '## B' >"$tmp/long.md"
want 2
expect "a short fence line does not close a longer fence" 0 '' count "$tmp/long.md"

printf '%s\n' '## A' "$F" '## fake' "$F" '## B' "$T" '## fake2' 'needle' >"$tmp/two-fences.md"
w2="md-sections: $tmp/two-fences.md: the fence opened at line 6 runs to the end of the file
"
want 2
expect "a second fence opens after the first closes: count" 0 "$w2" count "$tmp/two-fences.md"
want '## B: needle'
expect "a second fence opens after the first closes: find" 0 "$w2" find "$tmp/two-fences.md" needle

printf '%s\n' '## A' "$F" '## fake' 'needle' >"$tmp/open.md"
w="md-sections: $tmp/open.md: the fence opened at line 2 runs to the end of the file
"
want 1
expect "unclosed fence: count" 0 "$w" count "$tmp/open.md"
want '## A: needle'
expect "unclosed fence: find" 0 "$w" find "$tmp/open.md" needle

printf '%s\n' 'intro needle' '## A' 'a.b' 'axb' '## B needle' 'needle under B' >"$tmp/plain.md"
want '(before the first heading): intro needle' '## B needle: ## B needle' '## B needle: needle under B'
expect "find: a match before the first heading, on a heading, and under a later heading" 0 '' find "$tmp/plain.md" needle
want '## A: a.b'
expect "find: the needle is fixed text, not a pattern" 0 '' find "$tmp/plain.md" 'a.b'

# A fixture that ends with "## B" checks whether the parser is outside a fence there.
printf '%s\n' '## A' "$F" '## fake' "$F$F" '## B' >"$tmp/longer.md"
want 2
expect "a longer closing line closes the fence" 0 '' count "$tmp/longer.md"
printf '%s\n' '## A' "   $F" '## fake' "$F" '## B' >"$tmp/indent3.md"
want 2
expect "a fence indented 3 spaces opens and closes" 0 '' count "$tmp/indent3.md"
for sp in ' ' '  '; do
  printf '%s\n' '## A' "$sp$F" '## fake' "$F" '## B' >"$tmp/open-indent.md"
  want 2
  expect "a fence opened after ${#sp} space(s) closes at column one" 0 '' count "$tmp/open-indent.md"
  printf '%s\n' '## A' "$F" '## fake' "$sp$F" '## B' >"$tmp/close-indent.md"
  want 2
  expect "a closing line indented ${#sp} space(s) closes the fence" 0 '' count "$tmp/close-indent.md"
done
printf '%s\n' '## A' "$F" '## fake' "   $F" '## B' >"$tmp/close-indent3.md"
want 2
expect "a closing line indented 3 spaces closes the fence" 0 '' count "$tmp/close-indent3.md"
printf '%s\n' '## A' "${F}sh" '## fake' "$F" '## B' >"$tmp/lang.md"
want 2
expect "an opening line with a language name opens a fence" 0 '' count "$tmp/lang.md"
printf '%s\n' '## A' '``' '## B' >"$tmp/two.md"
want 2
expect "two backticks do not open a fence" 0 '' count "$tmp/two.md"
printf '%s\n' '## A' '~~' '## B' >"$tmp/two-tilde.md"
want 2
expect "two tildes do not open a fence" 0 '' count "$tmp/two-tilde.md"
: >"$tmp/empty.md"
want 0
expect "count prints 0 for a file with no heading" 0 '' count "$tmp/empty.md"
none
expect "find with no match prints nothing and exits 0" 0 '' find "$tmp/empty.md" needle
printf '%s\n' '## A' 'a\nb' 'a' >"$tmp/backslash.md"
want '## A: a\nb'
expect "a needle with a backslash is fixed text" 0 '' find "$tmp/backslash.md" 'a\nb'
printf '%s\n' '## A' "$F" >"$tmp/name\n.md"
want 1
expect "the warning names a file with a backslash in its name as given" 0 "md-sections: $tmp/name\n.md: the fence opened at line 2 runs to the end of the file
" count "$tmp/name\n.md"
printf '%s\n' '## A' "$F" '## fake' "    $F" '## fake2' "$F" '## B' >"$tmp/close-indent4.md"
want 2
expect "a closing line indented 4 spaces does not close the fence" 0 '' count "$tmp/close-indent4.md"
printf '%s\n' '## A' '### sub' '##tight' 'needle' >"$tmp/levels.md"
want 1
expect "count takes only lines that start with ## and a space" 0 '' count "$tmp/levels.md"
want '## A: needle'
expect "### and ## without a space do not start a section" 0 '' find "$tmp/levels.md" needle
printf '%s\n' '## A' "${F}sh" 'x' "$F" >"$tmp/delims.md"
want "## A: ${F}sh" "## A: $F"
expect "find prints the opening and closing lines of a fence" 0 '' find "$tmp/delims.md" "$F"
printf '## A\n\t%s\n## B\n' "$F" >"$tmp/tab-open.md"
want 2
expect "a tab before the opening line does not open a fence" 0 '' count "$tmp/tab-open.md"
printf '## A\n%s\n## fake\n\t%s\n## fake2\n%s\n## B\n' "$F" "$F" "$F" >"$tmp/tab-close.md"
want 2
expect "a tab before the closing line does not close the fence" 0 '' count "$tmp/tab-close.md"
printf '%s\n' '## A' "    $F" '## B' >"$tmp/indent4.md"
want 2
expect "a line indented 4 spaces does not open a fence" 0 '' count "$tmp/indent4.md"
printf '## A\n%s\n## fake\n%s \t\n## B\n' "$F" "$F" >"$tmp/trail.md"
want 2
expect "spaces and a tab after the closing line still close the fence" 0 '' count "$tmp/trail.md"
printf '%s\n' '## A' "$F" '## fake' "${F}x" '## fake2' "$F" '## B' >"$tmp/info.md"
want 2
expect "a fence line with text after it does not close the fence" 0 '' count "$tmp/info.md"
printf '%s\n' '## A' "$F" '## fake' "$T" '## fake2' "$F" '## B' >"$tmp/wrongchar.md"
want 2
expect "a closing line of the other character does not close the fence" 0 '' count "$tmp/wrongchar.md"
printf '## A\r\n%s\r\n## fake\r\n%s\r\n## B\r\nneedle\r\n' "$F" "$F" >"$tmp/crlf.md"
want 2
expect "CRLF file: count" 0 '' count "$tmp/crlf.md"
want '## B: needle'
expect "CRLF file: find" 0 '' find "$tmp/crlf.md" needle

printf '%s\n' '## A' '## B' >"$tmp/a=b.md"
printf '%s\n' '## A' '## B' >"$tmp/-"
want 2
# Bare names, so cd into the scratch dir; the counters must stay in this shell.
cd "$tmp" || exit 2
expect "count reads the file named a=b.md" 0 '' count 'a=b.md'
expect "count reads the file named -" 0 '' count '-'
cd - >/dev/null || exit 2

none
expect "usage: no arguments" 2 'usage: md-sections.sh count <file> | md-sections.sh find <file> <needle>
'
expect "usage: unknown command" 2 'usage: md-sections.sh count <file> | md-sections.sh find <file> <needle>
' list "$tmp/plain.md"
expect "usage: find without a needle" 2 'usage: md-sections.sh count <file> | md-sections.sh find <file> <needle>
' find "$tmp/plain.md"
expect "usage: empty needle" 2 'usage: md-sections.sh count <file> | md-sections.sh find <file> <needle>
' find "$tmp/plain.md" ''
expect "usage: count with an extra argument" 2 'usage: md-sections.sh count <file> | md-sections.sh find <file> <needle>
' count "$tmp/plain.md" extra
expect "usage: find with an extra argument" 2 'usage: md-sections.sh count <file> | md-sections.sh find <file> <needle>
' find "$tmp/plain.md" needle extra
# A read that fails after the open: an awk on PATH that exits 7 stands in for it.
mkdir "$tmp/fakebin" || exit 2
printf '#!/bin/sh\nexit 7\n' >"$tmp/fakebin/awk" && chmod 755 "$tmp/fakebin/awk" || exit 2
printf '%s\n' '## A' >"$tmp/ok.md"
none
PATH="$tmp/fakebin:$PATH" expect "a failed read exits 2" 2 "md-sections: cannot read $tmp/ok.md
" count "$tmp/ok.md"
mkdir "$tmp/dir.md" || exit 2
expect "a directory" 2 "md-sections: cannot read $tmp/dir.md
" count "$tmp/dir.md"
expect "missing file" 2 "md-sections: cannot read $tmp/missing.md
" count "$tmp/missing.md"
printf '%s\n' '## A' >"$tmp/noread.md"
chmod 000 "$tmp/noread.md" || {
  echo "setup: chmod 000 failed" >&2
  exit 2
}
if [[ -r "$tmp/noread.md" ]]; then
  skip=$((skip + 1))
  echo "skip unreadable file: this account can read a mode-000 file"
else
  expect "unreadable file" 2 "md-sections: cannot read $tmp/noread.md
" count "$tmp/noread.md"
fi

printf '%s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skip"
[[ $fail -eq 0 ]]
