#!/usr/bin/env bash
# Runs the vmalert-tool unit tests in monitoring/tests/vmalert/ against the alert rules as
# they are in git. Every test file names `rule_files: [rules.yaml]`; this script builds that
# file from the groups of every VMRule in the repo, so a test fails if someone edits a rule
# it covers.
#
# Usage: vmalert-rule-tests.sh <vmalert-tool binary> [repo root]
#
# vmalert-tool starts its clock at 946684800 (2000-01-01T00:00:00Z), so time() in a test
# returns 946684800 + the eval time. Each alert_rule_test needs `groupname`, and its
# exp_annotations must match the rendered annotations exactly.
set -euo pipefail

# The arrays and `read -d ''` loops need bash 4; macOS ships 3.2 as /bin/bash.
((BASH_VERSINFO[0] >= 4)) || {
  echo "needs bash 4 or later" >&2
  exit 1
}

tool="${1:?usage: $0 <vmalert-tool binary> [repo root]}"
repo_root="${2:-.}"
tool="$(cd "$(dirname "$tool")" && pwd)/$(basename "$tool")"
cd "$repo_root"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Every tracked YAML file that mentions VMRule in any spelling, then the parsed `.kind`
# decides. A quoted `kind: "VMRule"` still counts, and a file yq cannot parse stops the run.
git ls-files -z '*.yaml' '*.yml' >"$work/all"
rule_files=()
while IFS= read -r -d '' f; do
  grep -q 'VMRule' "$f" || continue
  n="$(yq eval-all '[select(.kind == "VMRule")] | length' "$f")"
  if [ "$n" -gt 0 ]; then rule_files+=("$f"); fi
done <"$work/all"
[ "${#rule_files[@]}" -gt 0 ] || {
  echo "no VMRule found" >&2
  exit 1
}
# shellcheck disable=SC2016 # $d is a yq variable
yq eval-all '. as $d ireduce ([]; . + ($d | select(.kind == "VMRule") | .spec.groups)) | {"groups": .}' \
  "${rule_files[@]}" >"$work/rules.yaml"
dupes="$(yq '[.groups[].name] | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$work/rules.yaml")"
[ -z "$dupes" ] || {
  echo "group names repeat across VMRules, so groupname is ambiguous: $dupes" >&2
  exit 1
}
echo "rules: $(yq '.groups | length' "$work/rules.yaml") groups from: ${rule_files[*]}"

# All test files share one directory with rules.yaml, so their names must be unique.
git ls-files -z 'monitoring/tests/vmalert/*.yaml' >"$work/tests"
mkdir "$work/run"
cp "$work/rules.yaml" "$work/run/"
args=()
while IFS= read -r -d '' t; do
  b="$(basename "$t")"
  [ ! -e "$work/run/$b" ] || {
    echo "test file name $b is not unique, or is rules.yaml" >&2
    exit 1
  }
  cp "$t" "$work/run/$b"
  args+=(--files "$b")
done <"$work/tests"
[ "${#args[@]}" -gt 0 ] || {
  echo "no test file under monitoring/tests/vmalert/" >&2
  exit 1
}

cd "$work/run"
"$tool" unittest "${args[@]}"
