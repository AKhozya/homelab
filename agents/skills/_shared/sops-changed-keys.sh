#!/usr/bin/env bash
# For each SOPS file that differs from HEAD (staged or not), print which stringData keys changed
# and whether everything outside stringData is identical. Names only, never values.
# A secret diff is ciphertext, so a reviewer cannot read it; this is the check that replaces
# reading it. Exit 1 if any file changed outside stringData.
# Decrypted values go to a private temp dir and reach jq through --slurpfile, not argv.
#
# Usage (repo root or worktree):  sops-changed-keys.sh [<path>...]   # default: every *.yaml != HEAD
set -euo pipefail

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  mapfile -t files < <(git diff --name-only HEAD -- '*.yaml')
fi
tmp="$(mktemp -d)"
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT
rc=0
for f in "${files[@]}"; do
  if ! grep -q '^sops:' "$f"; then continue; fi
  git show "HEAD:$f" | sops -d --input-type yaml --output-type json /dev/stdin >"$tmp/old.json"
  sops -d --output-type json "$f" >"$tmp/new.json"
  changed="$(jq -n -r --slurpfile a "$tmp/old.json" --slurpfile b "$tmp/new.json" '($a[0].stringData // {}) as $o | ($b[0].stringData // {}) as $n | ([$o, $n] | map(keys) | add | unique)[] | select($o[.] != $n[.])' | paste -sd, -)"
  rest="$(jq -n --slurpfile a "$tmp/old.json" --slurpfile b "$tmp/new.json" '($a[0] | del(.stringData, .sops)) == ($b[0] | del(.stringData, .sops))')"
  echo "$f changed=[$changed] rest-identical=$rest"
  if [ "$rest" != true ]; then rc=1; fi
done
exit "$rc"
