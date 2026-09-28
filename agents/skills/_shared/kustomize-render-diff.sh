#!/usr/bin/env bash
# Render-identical gate for Kustomize structural/layout moves (F-13/F-14/monitoring collapse pattern).
#
# Proves a base/overlay flatten or Flux `spec.path` repoint produces BYTE-IDENTICAL output
# => Flux re-adopts every object by unchanged name/ns/GVK = zero churn (no restart/recreate/prune).
# This is THE proof a layout move is safe. Build the oracle on the CLEAN pre-change tree,
# then check after edits.
#
# Usage:
#   kustomize-render-diff.sh oracle   <old-path> [oracle-file]  # capture baseline + SHA (pre-change)
#   kustomize-render-diff.sh check    <new-path> [oracle-file]  # diff new build vs baseline
#   kustomize-render-diff.sh diff     <old-path> <new-path>     # one-shot when both paths still build
#   kustomize-render-diff.sh semantic <old-path> <new-path>     # same, ignoring comment lines
#
# `semantic` is for a COMMENT SWEEP, where byte-identical is the wrong bar. kustomize drops
# YAML comments, but comments inside a block scalar — an initContainer `command: |`, a
# ConfigMap payload — are real lines in the render and survive. So a correct comment-only
# edit fails `diff` and passes `semantic`. Both sides are stripped by the same rule, so a
# genuine code change still shows. Blind spots are listed at strip_comments below.
#
# Default oracle-file: kustomize-render-oracle.yaml in the current checkout's git dir. A linked
# worktree has its own git dir, so two worktrees cannot overwrite each other's baseline.
# If you run it outside a git checkout, pass the oracle-file.
# Uses `kustomize build --enable-helm` for CI parity (needs `helm` + `kustomize` in PATH).
#
# Exit: 0 identical | 1 render drift (diff shown) | 2 misuse | 3 missing oracle/build error

set -euo pipefail

gd="$(git rev-parse --absolute-git-dir 2>/dev/null)" || gd=""
ORACLE_DEFAULT="${gd:+$gd/kustomize-render-oracle.yaml}"

build() { kustomize build --enable-helm "$1"; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Normalise a render for comment-blind comparison: parse to JSON, strip comment lines from
# INSIDE every string value, re-emit canonically (sorted keys, one document per line).
#
# Parse it, do not regex it. kustomize renders an embedded script (initContainer `command: |`,
# ConfigMap payload) as a double-quoted flow scalar with \n escapes, wrapped at whatever
# column it reaches — so a comment in it is not a physical line AND the wrap can land
# mid-comment. Two regex attempts were measured against a real comment-only sweep of apps/
# and both reported false drift: \n-expansion leaves continuation fragments opening with no
# `#`, and yq `style="literal"` did not convert every node.
#
# Shebangs are kept — a changed interpreter must not hide. Three known blind spots, all
# narrow, and the counts print so a large drop prompts reading the diff rather than the verdict:
#   - A markdown heading inside a ConfigMap payload opens with `#` and is dropped.
#   - A language pragma is dropped too — `//go:build`, `//go:generate`. Those are active code,
#     so do not use this mode to check a sweep of embedded Go or C source.
#   - A TRAILING comment (`cmd  # note`) is never stripped, because the pattern anchors at the
#     start of the line. Editing one reports drift. That is a false positive, not a miss.
# Documents are compared in emission order, so a reordering with no content change also reports
# drift. Same direction: extra review, never false confidence.
#
# Needs `yq` (mikefarah) and python3 alongside kustomize + helm. python3 is stdlib-only.
strip_comments() {
  yq -o=json -I0 '.' "$1" | python3 -c '
import json, re, sys
DROP = re.compile(r"^\s*(#([^!]|$)|//)")
dropped = 0
def clean(v):
    global dropped
    if isinstance(v, dict):  return {k: clean(x) for k, x in v.items()}
    if isinstance(v, list):  return [clean(x) for x in v]
    if isinstance(v, str) and "\n" in v:
        keep = [l for l in v.split("\n") if not DROP.match(l)]
        dropped += len(v.split("\n")) - len(keep)
        return "\n".join(keep)
    return v
for line in sys.stdin:
    line = line.strip()
    if line and line != "null":
        print(json.dumps(clean(json.loads(line)), sort_keys=True))
print(f"dropped={dropped}", file=sys.stderr)
'
}

report_same() {
  printf 'BYTE-IDENTICAL ✅ (%d lines) sha=%s\n' "$(wc -l <"$1")" "$(sha "$1")"
}
report_drift() {
  echo "RENDER DRIFT ❌ — oracle(<) vs new(>):" >&2
  diff "$1" "$2" | awk 'NR<=60' || true
  exit 1
}

cmd="${1:-}"
case "$cmd" in
oracle)
  path="${2:?oracle requires <old-path>}"
  out="${3:-$ORACLE_DEFAULT}"
  [[ -n "$out" ]] || {
    echo "not in a git checkout: pass [oracle-file]" >&2
    exit 2
  }
  if ! build "$path" >"$out" 2>/dev/null; then
    echo "build failed: kustomize build --enable-helm $path" >&2
    exit 3
  fi
  printf 'oracle: %s (%d lines) sha=%s\n' "$out" "$(wc -l <"$out")" "$(sha "$out")"
  ;;
check)
  path="${2:?check requires <new-path>}"
  oracle="${3:-$ORACLE_DEFAULT}"
  [[ -n "$oracle" ]] || {
    echo "not in a git checkout: pass [oracle-file]" >&2
    exit 2
  }
  [[ -f "$oracle" ]] || {
    echo "no oracle at $oracle — run '$0 oracle <old-path>' on the clean pre-change tree first" >&2
    exit 3
  }
  new="$(mktemp)"
  trap 'rm -f "$new"' EXIT
  if ! build "$path" >"$new" 2>/dev/null; then
    echo "build failed: kustomize build --enable-helm $path" >&2
    exit 3
  fi
  if diff -q "$oracle" "$new" >/dev/null; then
    report_same "$new"
  else
    report_drift "$oracle" "$new"
  fi
  ;;
diff)
  old="${2:?diff requires <old-path> <new-path>}"
  new_path="${3:?diff requires <old-path> <new-path>}"
  a="$(mktemp)"
  b="$(mktemp)"
  trap 'rm -f "$a" "$b"' EXIT
  if ! build "$old" >"$a" 2>/dev/null || ! build "$new_path" >"$b" 2>/dev/null; then
    echo "build failed (one of: $old | $new_path)" >&2
    exit 3
  fi
  if diff -q "$a" "$b" >/dev/null; then
    report_same "$b"
  else
    report_drift "$a" "$b"
  fi
  ;;
semantic)
  old="${2:?semantic requires <old-path> <new-path>}"
  new_path="${3:?semantic requires <old-path> <new-path>}"
  a="$(mktemp)"
  b="$(mktemp)"
  as="$(mktemp)"
  bs="$(mktemp)"
  trap 'rm -f "$a" "$b" "$as" "$bs"' EXIT
  if ! build "$old" >"$a" 2>/dev/null || ! build "$new_path" >"$b" 2>/dev/null; then
    echo "build failed (one of: $old | $new_path)" >&2
    exit 3
  fi
  drop_a="$(strip_comments "$a" 2>&1 >"$as" | sed -n 's/^dropped=//p')"
  drop_b="$(strip_comments "$b" 2>&1 >"$bs" | sed -n 's/^dropped=//p')"
  printf 'comment lines dropped from string values: old=%s new=%s\n' "${drop_a:-?}" "${drop_b:-?}"
  if diff -q "$as" "$bs" >/dev/null; then
    printf 'SEMANTICALLY IDENTICAL ✅ (%d documents) sha=%s\n' "$(wc -l <"$bs")" "$(sha "$bs")"
  else
    echo "SEMANTIC DRIFT ❌ — resources whose non-comment content changed:" >&2
    diff "$as" "$bs" | grep '^[<>]' |
      python3 -c '
import json, sys
for line in sys.stdin:
    side, _, body = line.partition(" ")
    try:
        d = json.loads(body)
        m = d.get("metadata") or {}
        kind = d.get("kind", "?")
        ns = m.get("namespace", "-")
        name = m.get("name", "?")
        print(side, kind + "/" + ns + "/" + name)
    except Exception:
        print(side, "(unparsed)", body[:80].rstrip())
' | sort -u >&2
    exit 1
  fi
  ;;
*)
  cat >&2 <<'EOF'
usage: kustomize-render-diff.sh oracle   <old-path> [oracle-file]  # capture baseline (clean pre-change tree)
       kustomize-render-diff.sh check    <new-path> [oracle-file]  # diff new build vs baseline
       kustomize-render-diff.sh diff     <old-path> <new-path>     # one-shot when both paths build
       kustomize-render-diff.sh semantic <old-path> <new-path>     # one-shot, ignoring comment lines
EOF
  exit 2
  ;;
esac
