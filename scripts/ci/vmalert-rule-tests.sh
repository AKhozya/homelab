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

tool="${1:?usage: $0 <vmalert-tool binary> [repo root]}"
repo_root="${2:-.}"
tool="$(cd "$(dirname "$tool")" && pwd)/$(basename "$tool")"
cd "$repo_root"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mapfile -t rule_files < <(git ls-files '*.yaml' | xargs grep -l '^kind: VMRule$')
[ "${#rule_files[@]}" -gt 0 ] || {
  echo "no VMRule file found" >&2
  exit 1
}
# shellcheck disable=SC2016 # $d is a yq variable
yq eval-all '. as $d ireduce ([]; . + ($d | select(.kind == "VMRule") | .spec.groups)) | {"groups": .}' \
  "${rule_files[@]}" >"$work/rules.yaml"
groups="$(yq '.groups | length' "$work/rules.yaml")"
dupes="$(yq '[.groups[].name] | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$work/rules.yaml")"
[ -z "$dupes" ] || {
  echo "group names repeat across VMRules, so groupname is ambiguous: $dupes" >&2
  exit 1
}
echo "rules: $groups groups from ${#rule_files[@]} VMRule files"

mapfile -t tests < <(git ls-files 'monitoring/tests/vmalert/*.yaml')
[ "${#tests[@]}" -gt 0 ] || {
  echo "no test file under monitoring/tests/vmalert/" >&2
  exit 1
}
args=()
for t in "${tests[@]}"; do
  cp "$t" "$work/"
  args+=(--files "$(basename "$t")")
done

cd "$work"
"$tool" unittest "${args[@]}"
