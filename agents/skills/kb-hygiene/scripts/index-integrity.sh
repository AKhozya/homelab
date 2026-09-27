#!/usr/bin/env bash
# kb-hygiene Axis 1 — deterministic MEMORY.md index integrity.
# Replaces the agent's manual orphan/dangling/broken-link sweep with a precise check.
# Uses grep/sed (NOT rg — rg is a shell function in this env, absent from non-interactive script PATH).
# Usage: index-integrity.sh [MEMORY_DIR]
# Exit: 0 clean | 1 orphans/dangling found | 2 bad args / missing index
set -euo pipefail

DIR="${1:-$HOME/.claude/projects/-Users-akhozya-source-code-homelab/memory}"
INDEX="$DIR/MEMORY.md"

[[ -d "$DIR" ]] || {
  echo "no such dir: $DIR" >&2
  exit 2
}
[[ -f "$INDEX" ]] || {
  echo "no MEMORY.md in: $DIR" >&2
  exit 2
}

orphans=0
dangling=0
broken=0

# Drop fenced blocks and inline code spans so documented `[[syntax]]` is not read as a link.
# Only a run of exactly the opener's length closes a span, per CommonMark: without that,
# a single backtick closes against the first tick of a longer run and eats the text between,
# which hides a real broken link. An unterminated opener leaves the rest of the line intact
# for the same reason — over-warning is recoverable, a missed warning is not.
strip_code() {
  awk '
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    {
      out = ""; s = $0
      while (match(s, /`+/)) {
        n = RLENGTH
        out = out substr(s, 1, RSTART - 1)
        rest = substr(s, RSTART + RLENGTH)
        p = rest
        closed = 0
        while (match(p, /`+/)) {
          if (RLENGTH == n) {
            s = substr(p, RSTART + RLENGTH)
            closed = 1
            break
          }
          p = substr(p, RSTART + RLENGTH)
        }
        if (!closed) {
          out = out rest
          s = ""
          break
        }
      }
      print out s
    }
  ' "$@"
}

echo "== orphans (memory file on disk, absent from MEMORY.md) =="
for f in "$DIR"/*.md; do
  base="$(basename "$f")"
  if [[ "$base" == "MEMORY.md" ]]; then continue; fi
  # Match the link form, not a bare substring: `nas.md` occurs inside `reference_nas.md`,
  # so a plain search calls a genuinely orphaned file indexed and hides it.
  if ! grep -qF -- "]($base)" "$INDEX"; then
    echo "  ORPHAN: $base"
    orphans=$((orphans + 1))
  fi
done
if [[ "$orphans" -eq 0 ]]; then echo "  none"; fi

echo "== dangling index links (in MEMORY.md, target file missing) =="
while IFS= read -r tgt; do
  if [[ -z "$tgt" ]]; then continue; fi
  if [[ ! -e "$DIR/$tgt" ]]; then
    echo "  DANGLING: $tgt"
    dangling=$((dangling + 1))
  fi
done < <(grep -oE '\]\([^)#]+\.md' "$INDEX" | sed 's/^](//' | sort -u || true)
if [[ "$dangling" -eq 0 ]]; then echo "  none"; fi

echo "== broken [[wiki-links]] (WARN only — a link to a not-yet-written file is intentional) =="
# A link resolves against a filename stem or a frontmatter `name:` slug. The two spellings
# differ: files use underscores, slugs use hyphens. Read `name:` only inside the frontmatter
# delimiters — a body line starting with `name:` would otherwise resolve a link to nothing.
resolvable="$(
  for f in "$DIR"/*.md; do
    basename "$f" .md
    awk '
      NR == 1 { if ($0 != "---") exit; next }
      $0 == "---" { exit }
      /^name:[ \t]*/ { sub(/^name:[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit }
    ' "$f"
  done | sort -u
)"
while IFS= read -r slug; do
  if [[ -z "$slug" ]]; then continue; fi
  slug="${slug%%#*}" # strip #anchor
  # A slug opening with `-` is read as a grep option, so the call ends its flags with `--`.
  # The here-string replaces a pipe, where a short `printf` can take SIGPIPE and invert the
  # result under pipefail.
  if ! grep -qxF -- "$slug" <<<"$resolvable"; then
    echo "  WARN broken-link: [[$slug]]"
    broken=$((broken + 1))
  fi
done < <(strip_code "$DIR"/*.md | grep -oE '\[\[[A-Za-z0-9_.-]+\]\]' | sed 's/\[\[//; s/\]\]//' | sort -u || true)
if [[ "$broken" -eq 0 ]]; then echo "  none"; fi

echo
echo "summary: orphans=$orphans dangling=$dangling broken-links=$broken (count drift = semantic, left to agent)"
if [[ "$orphans" -gt 0 || "$dangling" -gt 0 ]]; then exit 1; fi
exit 0
