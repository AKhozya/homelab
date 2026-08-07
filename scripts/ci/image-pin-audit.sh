#!/usr/bin/env bash
# Audit authored manifests for images NOT pinned to major.minor.patch[-variant].
#
# The gap this closes: Kyverno's image-pin policy + CI only reject `:latest` or a missing
# tag. A major-only (`:8`) or major.minor (`:1.0`, `:1.22`) tag is a real silent-drift hole —
# `repo:1.0` floats across every 1.0.x rebuild. CLAUDE.md invariant: "Pin all images
# major.minor.patch-variant." This script enforces that invariant offline, repo-wide.
# Surfaced 2026-05-29: `seleniumbase-scrapper:v1.0` + `claude-telegram:1.22`.
#
# Scope: container/init/ephemeral `image:` refs in authored workloads, plus image tags
# mirrored into HelmRelease `spec.values`. The values pass was added after two escapes that
# the container pass could not see: the loki gateway tag drifted a patch behind the same
# image elsewhere in the repo, and redis-operator's `imageTag` froze the operator on v0.24.0
# while its chart moved to 0.25.0. Chart-default images (no tag in values) are pinned by the
# pinned chart version and are correctly invisible here.
# SOPS-encrypted files are skipped (no image fields, and decryption is out of band).
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
#   seleniumbase-scrapper → upstream publishes only `:latest` + `:v1.0`, no patch tags;
#     digest-pin declined, so major.minor is the deepest available.
twocomp_ok_re='(^|/)(postgres|postgresql|seleniumbase-scrapper)$'
twocomp_re='^v?[0-9]+\.[0-9]+(\.[0-9]+)?([-.+].*)?$'

found=0

# Validate one tag against the pin rules.
# Args: <file> <ref-for-display> <repo-without-tag> <tag>
check_tag() {
  local file="$1" ref="$2" repo="${3,,}" tag="$4"

  if [[ "$tag" == "latest" ]]; then
    echo "FAIL: $file  $ref  (:latest)"
    found=1
  elif [[ "$repo" =~ $twocomp_ok_re ]]; then
    # Upstream uses native 2-component versioning — accept major.minor[.patch].
    if [[ ! "$tag" =~ $twocomp_re ]]; then
      echo "FAIL: $file  $ref  (not a pinned version)"
      found=1
    fi
  elif [[ ! "$tag" =~ $semver_re ]]; then
    echo "FAIL: $file  $ref  (not major.minor.patch)"
    found=1
  fi
}

# Every YAML file under $root. The per-doc kind filters below split HelmRelease values
# from workloads.
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

    check_tag "$file" "$img" "$name_no_tag" "$tag"
  done < <(yq ea 'select(.kind != "HelmRelease") | .. | select(tag == "!!map" and has("image")) | .image' "$file" 2>/dev/null || true)

  # HelmRelease values pass. An image override is a map carrying `tag` that either sits
  # under a key ending in `image` (`image`, `initImage`) or carries `repository`, or any
  # map carrying `imageTag`. Both halves are needed: the parent-name test catches a bare
  # tag with no repository (the renovate-blind case this pass exists for), and the
  # repository test catches image maps parked under some other key. Together they leave
  # unrelated keys such as `podLabels.tag` alone.
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == "---" ]] && continue
    # NONE sentinels, not empty fields: tab is IFS *whitespace*, so a leading empty
    # column collapses and shifts every value one position left.
    IFS=$'\t' read -r vrepo vtag vdigest <<<"$line"
    [[ -z "$vtag" || "$vtag" == "null" ]] && continue

    # A digest outranks the tag — but only a well-formed one. `digest: latest` would
    # otherwise wave the ref through unchecked.
    if [[ "$vdigest" != "NONE" && -n "$vdigest" && "$vdigest" != "null" ]]; then
      if [[ "$vdigest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        continue
      fi
      echo "FAIL: $file  values digest '$vdigest'  (not a sha256 digest)"
      found=1
      continue
    fi

    if [[ "$vrepo" == "NONE" || -z "$vrepo" || "$vrepo" == "null" ]]; then
      echo "FAIL: $file  values tag '$vtag'  (no repository — Renovate cannot resolve a bare tag)"
      found=1
      continue
    fi

    check_tag "$file" "$vrepo:$vtag" "$vrepo" "$vtag"
  done < <(yq ea 'select(.kind == "HelmRelease") | .spec.values | .. | select(tag == "!!map") | select((has("tag") and (((path[-1] | tostring | downcase) | test("image$")) or has("repository"))) or has("imageTag")) | [(.repository // "NONE"), (.tag // .imageTag), (.digest // "NONE")] | @tsv' "$file" 2>/dev/null || true)
done < <(find "$root" \( -name '*.yaml' -o -name '*.yml' \) -type f -print0)

exit "$found"
