#!/usr/bin/env bash
# Asserts what index-integrity.sh must and must not report. Pass the script under test as
# the first argument to run an older copy and watch which assertions it fails.
# Usage: test-index-integrity.sh [SCRIPT_UNDER_TEST]
# Exit: 0 every assertion holds | 1 any assertion failed
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${1:-$HERE/../index-integrity.sh}"
[[ -f "$SUT" ]] || {
  echo "no such script: $SUT" >&2
  exit 1
}

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
fails=0

fail() {
  printf 'FAIL  %s\n' "$1"
  fails=$((fails + 1))
}
ok() { printf 'ok    %s\n' "$1"; }

mem() { # mem <filename> <name-slug|-> <body>
  {
    [[ "$2" == "-" ]] || printf -- '---\nname: %s\ndescription: d\nmetadata:\n  type: reference\n---\n' "$2"
    printf '%s\n' "$3"
  } >"$FIX/$1"
}

# Filenames use underscores, frontmatter slugs use hyphens, so a link may arrive in either
# spelling and both must resolve.
mem under_scored_topic.md under-scored-topic 'body'
mem plain_topic.md plain-topic 'body'

# No frontmatter, but a body line looks like one. A resolver reading `name:` anywhere in the
# file resolves [[phantom]] and hides a broken link.
mem no_frontmatter.md - 'prose
name: phantom'

mem linker.md linker "$(
  cat <<'BODY'
Filename stem: [[plain_topic]].
Frontmatter slug: [[under-scored-topic]].
Anchored: [[plain_topic#somewhere]].
Single-tick span: `[[span-single]]`.
Double-tick span: ``[[span-double]]``.
Opener never closes, so this link is real: `text [[unterminated]] `` tail
Real link beside a span: `code` [[beside-span]].
Hyphen-leading slug: [[-dash-slug]].
Absent: [[no-such-memory]].
Body-line name: [[phantom]].
```
[[inside-fence]]
```
BODY
)"
mem beside_span.md beside-span 'body'
# A slug opening with a hyphen is read as a grep option unless the call ends its flags.
mem dash_slug_topic.md -dash-slug 'body'

cat >"$FIX/MEMORY.md" <<'IDX'
# Index
- [Under](under_scored_topic.md) — hook
- [Plain](plain_topic.md) — hook
- [NoFm](no_frontmatter.md) — hook
- [Linker](linker.md) — hook
- [Beside](beside_span.md) — hook
- [Dash](dash_slug_topic.md) — hook
IDX

set +e
out="$("$SUT" "$FIX" 2>&1)"
rc=$?
set -e

printf -- '--- %s on fixture (exit %s) ---\n' "$(basename "$SUT")" "$rc"

# Must resolve: both spellings, an anchor, and a link sitting next to a code span.
for name in "[[plain_topic]]" "[[plain_topic#somewhere]]" "[[under-scored-topic]]" "[[beside-span]]" "[[-dash-slug]]"; do
  if printf '%s' "$out" | grep -qF "broken-link: $name"; then
    fail "script reports a resolvable link as broken: $name"
  else
    ok "resolves: $name"
  fi
done

# Must ignore: documented syntax inside code spans and fenced blocks.
for name in "[[span-single]]" "[[span-double]]" "[[inside-fence]]"; do
  if printf '%s' "$out" | grep -qF "broken-link: $name"; then
    fail "script reads documented syntax as a link: $name"
  else
    ok "ignores code: $name"
  fi
done

# Must still warn. Each of these hid behind a resolver bug.
for name in "[[no-such-memory]]" "[[phantom]]" "[[unterminated]]"; do
  if printf '%s' "$out" | grep -qF "broken-link: $name"; then
    ok "warns: $name"
  else
    fail "script missed a broken link: $name"
  fi
done

if [[ "$rc" -ne 0 ]]; then
  fail "expected exit 0 on a fixture with no orphans and no dangling links, got $rc"
else
  ok "exit 0 while only wiki-links warn"
fi

# A file whose name is a substring of an indexed one. A bare substring search finds
# `scored_topic.md` inside `under_scored_topic.md` and calls this file indexed.
mem scored_topic.md scored-topic 'body'
set +e
out4="$("$SUT" "$FIX" 2>&1)"
rc4=$?
set -e
if printf '%s' "$out4" | grep -qF "ORPHAN: scored_topic.md" && [[ "$rc4" -eq 1 ]]; then
  ok "reports orphan whose name is a substring of an indexed file"
else
  fail "script missed the substring orphan or returned the wrong code (rc=$rc4)"
fi
rm -f "$FIX/scored_topic.md"

# A file on disk that the index never names.
mem orphan_topic.md orphan-topic 'body'
set +e
out2="$("$SUT" "$FIX" 2>&1)"
rc2=$?
set -e
if printf '%s' "$out2" | grep -qF "ORPHAN: orphan_topic.md" && [[ "$rc2" -eq 1 ]]; then
  ok "reports orphan, exits 1"
else
  fail "script missed the orphan or returned the wrong code (rc=$rc2)"
fi
rm -f "$FIX/orphan_topic.md"

# The index points at a file that does not exist.
echo '- [Ghost](ghost_topic.md) — hook' >>"$FIX/MEMORY.md"
set +e
out3="$("$SUT" "$FIX" 2>&1)"
rc3=$?
set -e
if printf '%s' "$out3" | grep -qF "DANGLING: ghost_topic.md" && [[ "$rc3" -eq 1 ]]; then
  ok "reports dangling link, exits 1"
else
  fail "script missed the dangling link or returned the wrong code (rc=$rc3)"
fi

echo
if [[ "$fails" -eq 0 ]]; then
  echo "PASS — every assertion held"
  exit 0
fi
echo "FAILED — $fails assertion(s)"
exit 1
