#!/usr/bin/env bash
# Audit authored manifests for images NOT pinned to major.minor.patch[-variant].
#
# The gap this closes: Kyverno's image-pin policy + CI only reject `:latest` or a missing
# tag. A major-only (`:8`) or major.minor (`:1.0`, `:1.22`) tag is a real silent-drift hole —
# `repo:1.0` floats across every 1.0.x rebuild. CLAUDE.md invariant: "Pin all images
# major.minor.patch-variant." This script enforces that invariant offline, repo-wide.
# Surfaced by F-24 (2026-05-29): `seleniumbase-scrapper:v1.0` + `claude-telegram:1.22`.
#
# Scope: container/init/ephemeral `image:` refs in authored workloads. HelmReleases are
# SKIPPED — their image pinning is a different mechanism (chart version / values.tag), audited
# elsewhere. SOPS-encrypted files are skipped (no image fields, and decryption is out of band).
#
# A ref PASSES if: tag matches ^v?MAJOR.MINOR.PATCH(-variant)? (e.g. 1.2.3, v1.0.46,
# 3.23.4, 1.2.3-alpine), OR it is digest-pinned (`@sha256:...`, which is stricter than a tag).
# A ref FAILS if: untagged, `:latest`, major-only, or major.minor-only.
#
# Output (one per line):  FAIL: <file>  <image>  (<reason>)
# Exit 0 if all pinned; 1 if any unpinned; 2 on misuse.

set -euo pipefail

command -v yq >/dev/null || {
  echo "yq not found" >&2
  exit 2
}

# Repo root: arg 1, else cwd.
root="${1:-.}"
[[ -d "$root" ]] || {
  echo "not a directory: $root" >&2
  exit 2
}

# major.minor.patch with optional leading v and optional -variant / .build suffix.
semver_re='^v?[0-9]+\.[0-9]+\.[0-9]+([-.+].*)?$'
# Two-component (major.minor) is also accepted for these upstreams where a deeper tag does not
# exist — either native 2-part release versioning, or the publisher only ships major.minor.
#   postgres / cloudnative-pg postgresql → `18.4`, `18.4-standard-trixie` (no patch component).
#   seleniumbase-scrapper → upstream publishes only `:latest` + `:v1.0`, no patch tags (F-23);
#     digest-pin declined, so major.minor is the deepest available.
twocomp_ok_re='(^|/)(postgres|postgresql|seleniumbase-scrapper)$'
twocomp_re='^v?[0-9]+\.[0-9]+(\.[0-9]+)?([-.+].*)?$'

found=0

# Authored manifest roots only (HelmRelease values live here too but we filter by kind below).
while IFS= read -r -d '' file; do
  # Skip SOPS-encrypted files.
  if grep -q 'ENC\[AES256_GCM' "$file" 2>/dev/null; then
    continue
  fi

  # Extract every container/init/ephemeral image from non-HelmRelease docs.
  # `..` recurses all nodes (covers containers[], initContainers[], ephemeralContainers[],
  # CronJob jobTemplate nesting, bare Pods); select keeps maps that have an `image` key.
  # Doc-level select(.kind!="HelmRelease") drops HelmRelease values.image false-positives.
  while IFS= read -r img; do
    # Skip blanks, nulls, and yq's `---` inter-document separators (emitted by `ea`
    # between matches in a multi-doc file, e.g. gotk-components.yaml).
    [[ -z "$img" || "$img" == "null" || "$img" == "---" ]] && continue

    # Digest-pinned is acceptable (stricter than a tag).
    if [[ "$img" == *"@sha256:"* ]]; then
      continue
    fi

    # Determine the tag: substring after the last ':' that follows the last '/'
    # (avoids mistaking a registry port `host:5000/repo` for a tag).
    name_no_tag="${img%:*}"
    if [[ "$img" == "$name_no_tag" ]]; then
      echo "FAIL: $file  $img  (untagged)"
      found=1
      continue
    fi
    tag="${img##*:}"
    # If the '...:...' colon was actually the registry port (no slash after it), there is no tag.
    if [[ "$tag" == *"/"* ]]; then
      echo "FAIL: $file  $img  (untagged)"
      found=1
      continue
    fi

    # Repo name without tag/digest, lowercased, for allowlist matching.
    repo="${name_no_tag,,}"

    if [[ "$tag" == "latest" ]]; then
      echo "FAIL: $file  $img  (:latest)"
      found=1
    elif [[ "$repo" =~ $twocomp_ok_re ]]; then
      # Upstream uses native 2-component versioning — accept major.minor[.patch].
      if [[ ! "$tag" =~ $twocomp_re ]]; then
        echo "FAIL: $file  $img  (not a pinned version)"
        found=1
      fi
    elif [[ ! "$tag" =~ $semver_re ]]; then
      echo "FAIL: $file  $img  (not major.minor.patch)"
      found=1
    fi
  done < <(yq ea 'select(.kind != "HelmRelease") | .. | select(tag == "!!map" and has("image")) | .image' "$file" 2>/dev/null || true)
done < <(find "$root" \( -name '*.yaml' -o -name '*.yml' \) -type f -print0)

exit "$found"
