#!/usr/bin/env bash
# Rotate CNPG managed-role passwords in SOPS, in every copy at once.
#
# Copies are found by VALUE: each role's current password (from its CNPG passwordSecret file) is
# searched in the stringData of every SOPS file under apps/ infrastructure/ monitoring/, as a bare
# key or inside a DSN (linkwarden DATABASE_URL, blocky config.yml). A table of file names goes
# stale; the value does not.
# No live change: CNPG sets the role password when Flux syncs the CNPG file, so every app using
# that role fails auth from the sync until its pods are cycled.
#
# Usage (from the repo root or a worktree):
#   rotate-pg-roles.sh --list <role>...   # print each role's copies (file [key]); no change
#   rotate-pg-roles.sh <role>...          # rewrite every copy; prints file [key] only
#
# Discovery covers every role before any write, and fails on a file it cannot decrypt, a role
# with a password under 16 chars (a short value could match unrelated text), or fewer than 2
# copies (postgres-admin has 1: its readers mount the CNPG Secret itself). If any write fails,
# every file this run touched is restored from its pre-run bytes.
# Never prints a password; values travel through stdin, env and a private temp dir, not argv.
set -euo pipefail

list=0
if [ "${1:-}" = "--list" ]; then
  list=1
  shift
fi
if [ "$#" -eq 0 ]; then
  echo "usage: $0 [--list] <role>..." >&2
  exit 2
fi
pg=infrastructure/configs/databases/postgres
if [ ! -f "$pg/cluster.yaml" ]; then
  echo "run from the homelab repo root (no $pg/cluster.yaml here)" >&2
  exit 2
fi

tmp="$(mktemp -d)"
chmod 700 "$tmp"
keep_bak=0
cleanup() {
  if [ "$keep_bak" = 1 ]; then
    # If a restore failed, keep the encrypted backups for a manual restore. Delete the plaintext.
    rm -rf "$tmp/dec" "$tmp"/old.* "$tmp"/new.*
    echo "encrypted originals kept in $tmp/bak (path with / replaced by _)" >&2
  else
    rm -rf "$tmp"
  fi
}
trap cleanup EXIT
mkdir "$tmp/dec" "$tmp/bak"

# Phase 1: decrypt every SOPS file once; any failure stops before a write.
mapfile -t sopsfiles < <(grep -rl --include='*.yaml' '^sops:' apps infrastructure monitoring | sort)
for f in "${sopsfiles[@]}"; do
  if ! sops -d --output-type json "$f" >"$tmp/dec/$(printf '%s' "$f" | tr / _)" 2>/dev/null; then
    echo "cannot decrypt $f; stopping before any change" >&2
    exit 1
  fi
done

# Phase 2: build the plan (role, file, key) for every role; still no write.
: >"$tmp/plan"
for role in "$@"; do
  sec="$(yq ".spec.managed.roles[] | select(.name==\"$role\") | .passwordSecret.name" "$pg/cluster.yaml")"
  if [ -z "$sec" ] || [ "$sec" = null ]; then
    echo "$role: not a managed role in $pg/cluster.yaml" >&2
    exit 1
  fi
  # cluster.yaml names the secret too, so keep only encrypted files.
  src="$(grep -l -E "^[[:space:]]+name: ${sec}\$" "$pg"/*.yaml | xargs grep -l '^sops:' | head -1 || true)"
  if [ -z "$src" ]; then
    echo "$role: no SOPS file in $pg defines secret $sec" >&2
    exit 1
  fi
  jq -j '.stringData.password' <"$tmp/dec/$(printf '%s' "$src" | tr / _)" >"$tmp/old.$role"
  if [ "$(wc -c <"$tmp/old.$role")" -lt 16 ]; then
    echo "$role: current password shorter than 16 chars; refusing a substring replace" >&2
    exit 1
  fi
  n=0
  for f in "${sopsfiles[@]}"; do
    while IFS= read -r key; do
      if [ -z "$key" ]; then continue; fi
      printf '%s\t%s\t%s\n' "$role" "$f" "$key" >>"$tmp/plan"
      n=$((n + 1))
    done < <(OLD="$(cat "$tmp/old.$role")" jq -r '.stringData // {} | to_entries[] | select(.value | tostring | contains(env.OLD)) | .key' <"$tmp/dec/$(printf '%s' "$f" | tr / _)")
  done
  if [ "$n" -lt 2 ]; then
    echo "$role: found $n copies; expected at least the CNPG file and the app file" >&2
    exit 1
  fi
done

if [ "$list" = 1 ]; then
  awk -F'\t' '$1 != r { r = $1; print "== " r } { print "   " $2 " [" $3 "]" }' "$tmp/plan"
  exit 0
fi

# Phase 3: write. Back up each file once; on any failure restore them all.
cut -f2 "$tmp/plan" | sort -u >"$tmp/files"
while IFS= read -r f; do
  cp -p "$f" "$tmp/bak/$(printf '%s' "$f" | tr / _)"
done <"$tmp/files"
restore() {
  trap - ERR
  local f bad=0
  while IFS= read -r f; do
    if ! cp -pf "$tmp/bak/$(printf '%s' "$f" | tr / _)" "$f"; then
      echo "RESTORE FAILED: $f" >&2
      bad=1
    fi
  done <"$tmp/files"
  if [ "$bad" = 1 ]; then
    keep_bak=1
  else
    echo "a write failed; restored every file this run touched" >&2
  fi
}
trap restore ERR

for role in "$@"; do
  openssl rand -hex 32 | tr -d '\n' >"$tmp/new.$role"
done
while IFS=$'\t' read -r role f key; do
  sops -d --output-type json "$f" | jq -c --arg k "$key" '.stringData[$k]' |
    OLD="$(cat "$tmp/old.$role")" NEW="$(cat "$tmp/new.$role")" jq -c 'split(env.OLD) | join(env.NEW)' |
    sops set --value-stdin "$f" "[\"stringData\"][\"$key\"]"
  echo "$role: $f [$key]"
done <"$tmp/plan"
trap - ERR
