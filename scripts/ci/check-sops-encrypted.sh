#!/usr/bin/env bash
# Asserts every credential-bearing YAML file contains a SOPS ENC[AES256_GCM marker.
# Used by .github/workflows/validate.yaml + .pre-commit-config.yaml.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

mapfile -t files < <(find . \
  -path './.git' -prune -o \
  -path './.playwright-mcp' -prune -o \
  -path './.backup' -prune -o \
  -path './.claude/worktrees' -prune -o \
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
declare -A pass1_failed=()
for f in "${files[@]}"; do
  if ! grep -q 'ENC\[AES256_GCM' "$f"; then
    echo "::error file=$f::expected SOPS marker ENC[AES256_GCM but file is plaintext"
    pass1_failed["$f"]=1
    missing=$((missing + 1))
  fi
done

# Pass 2 — by CONTENT and per DOCUMENT. Runs over EVERY yaml, including the ones
# pass 1 already accepted: pass 1's grep is file-wide, so in a multi-document file
# an encrypted document 1 would otherwise vouch for a plaintext document 2. The two
# passes report different defects (no marker at all / this document is plaintext),
# so neither is a duplicate of the other. Covers .yml too — pass 1's patterns are
# .yaml-only by repo convention. Anchored so `kind: SecretStore` doesn't match;
# quoted forms do. Known gap: a `...` document-end marker is not treated as a
# boundary — kustomize and every manifest here use `---`.
mapfile -t candidates < <(find . \
  -path './.git' -prune -o \
  -path './.playwright-mcp' -prune -o \
  -path './.backup' -prune -o \
  -path './.claude/worktrees' -prune -o \
  \( -name '*.yaml' -o -name '*.yml' \) -type f -print 2>/dev/null)

content=0
for f in "${candidates[@]}"; do
  grep -qE "^kind:[[:space:]]*['\"]?Secret['\"]?[[:space:]]*(#.*)?$" "$f" || continue
  content=$((content + 1))
  # Pass 1 already reported this file as wholly unencrypted; re-listing every
  # document in it would inflate one defect into several.
  if [ -n "${pass1_failed[$f]:-}" ]; then continue; fi
  unencrypted_docs=$(awk '
    function flush() {
      if (isSecret && !hasEnc) { print docn }
      isSecret = 0; hasEnc = 0
    }
    BEGIN { docn = 1; seenContent = 0 }
    # `--- # comment` and `--- !!map` are valid separators, so match the marker
    # plus a boundary rather than end-of-line. [[:space:]] not [ \t] so a CRLF
    # file s trailing \r still terminates the marker. A leading separator opens
    # document 1 rather than closing an empty document 0.
    /^---([[:space:]]|$)/ {
      if (seenContent) { flush(); docn++ } else { isSecret = 0; hasEnc = 0 }
      next
    }
    # Comments and blanks are preamble, not content — otherwise a `# header`
    # above the first `---` would number the first real document as 2.
    /^[[:space:]]*(#|$)/ { next }
    { seenContent = 1 }
    /^kind:[[:space:]]*['"'"'"]?Secret['"'"'"]?[[:space:]]*(#.*)?$/ { isSecret = 1 }
    /ENC\[AES256_GCM/ { hasEnc = 1 }
    END { flush() }
  ' "$f")
  while IFS= read -r doc; do
    if [ -z "$doc" ]; then continue; fi
    echo "::error file=$f::plaintext 'kind: Secret' in document $doc"
    missing=$((missing + 1))
  done <<<"$unencrypted_docs"
done

printf 'sops-check: scanned %d by name + %d by content, %d unencrypted\n' \
  "${#files[@]}" "$content" "$missing"
# Not `exit $missing` — an exit status wraps mod 256, so exactly 256 findings
# would report success.
exit $((missing > 0))
