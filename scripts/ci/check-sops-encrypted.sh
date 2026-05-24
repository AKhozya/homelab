#!/usr/bin/env bash
# Asserts every credential-bearing YAML file contains a SOPS ENC[AES256_GCM marker.
# Used by .github/workflows/validate.yaml + .pre-commit-config.yaml.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

mapfile -t files < <(find . \
  -path './.git' -prune -o \
  -path './.playwright-mcp' -prune -o \
  -path './.backup' -prune -o \
  \( -name '*secret*.yaml' \
  -o -name '*credentials*.yaml' \
  -o -name '*-db-user.yaml' \
  -o -name 'postgres-admin-user.yaml' \
  -o -name 'cluster-secrets.yaml' \
  -o -name 'tunnel-credentials.yaml' \
  -o -name 'tunnel-mgmt-token.yaml' \
  -o -name '*.sops.yaml' \) \
  ! -name '.sops.yaml' \
  -type f -print 2>/dev/null)

missing=0
for f in "${files[@]}"; do
  if ! grep -q 'ENC\[AES256_GCM' "$f"; then
    echo "::error file=$f::expected SOPS marker ENC[AES256_GCM but file is plaintext"
    missing=$((missing + 1))
  fi
done

printf 'sops-check: scanned %d files, %d unencrypted\n' "${#files[@]}" "$missing"
exit "$missing"
