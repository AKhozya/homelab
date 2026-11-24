#!/usr/bin/env bash
#   md-sections.sh count <file>           prints the number of "## " headings outside fences
#   md-sections.sh find <file> <needle>   prints each line that holds <needle> (fixed text, not a
#                                         pattern) as "<its section's ## heading>: <line>"
# A fence opens with 3 or more ` or ~ after up to 3 spaces. A line of the same character, at least
# as long, with only spaces or tabs after it, closes the fence. If a heading occurs inside a fence,
# it does not count and does not start a section. find still prints matching lines inside a fence.
# If a fence never closes, it runs to the end of the file: the command warns on stderr and exits 0.
# Both commands ignore one trailing carriage return.
# Exit: 0 done; 2 usage error, a path that is not a readable regular file, or a failed read.
set -euo pipefail

usage() {
  echo "usage: md-sections.sh count <file> | md-sections.sh find <file> <needle>" >&2
  exit 2
}
[ $# -ge 2 ] || usage
cmd=$1
f=$2
case "$cmd" in
count) [ $# -eq 2 ] || usage ;;
find) [ $# -eq 3 ] && [ -n "$3" ] || usage ;;
*) usage ;;
esac
if [ ! -f "$f" ] || ! { exec 3<"$f"; } 2>/dev/null; then
  echo "md-sections: cannot read $f" >&2
  exit 2
fi

# The needle and the name go through the environment: awk -v would expand backslashes in them.
# The file comes on fd 3: awk reads an operand like a=b.md as an assignment and - as stdin.
# If the file disappears after the check, the open fails here and the script exits 2.
MD_CMD=$cmd MD_NEEDLE=${3:-} MD_NAME=$f awk '
BEGIN { cmd = ENVIRON["MD_CMD"]; needle = ENVIRON["MD_NEEDLE"]; name = ENVIRON["MD_NAME"]
  n = 0; sec = "(before the first heading)"; fch = ""; flen = 0 }
{
  line = $0
  sub(/\r$/, "", line)
  if (fch == "") {
    if (match(line, /^ ? ? ?(```+|~~~+)/)) {
      s = substr(line, RSTART, RLENGTH); sub(/^ +/, "", s)
      fch = substr(s, 1, 1); flen = length(s); fline = NR
    } else if (line ~ /^## /) { n++; sec = line }
  } else {
    t = line; sub(/^ ? ? ?/, "", t)
    k = 0; while (substr(t, k + 1, 1) == fch) k++
    if (k >= flen && substr(t, k + 1) ~ /^[ \t]*$/) fch = ""
  }
  if (cmd == "find" && index(line, needle) > 0) print sec ": " line
}
END {
  if (fch != "") printf "md-sections: %s: the fence opened at line %d runs to the end of the file\n", name, fline > "/dev/stderr"
  if (cmd == "count") print n
}' <&3 || {
  echo "md-sections: cannot read $f" >&2
  exit 2
}
