#!/usr/bin/env bash
# Validate one or more K8s YAML files through the ladder:
#   yamllint -> kubeconform -> kubectl client dry-run -> kubectl server dry-run
#
# Stops at first failure. Emit pass/fail per step.
#
# Usage:
#   validate.sh <file.yaml> [<file2.yaml> ...]
#   validate.sh --kustomize <path>         # build + grep workflow
#   validate.sh --flux <name> <path>       # flux build kustomization

set -euo pipefail

mode="${1:-}"
if [ -z "$mode" ]; then
  cat >&2 <<EOF
usage: $0 <file.yaml> [<file2.yaml> ...]
       $0 --kustomize <path>
       $0 --flux <name> <path>
EOF
  exit 2
fi

case "$mode" in
--kustomize)
  shift
  KPATH="${1:?--kustomize requires <path>}"
  TMP="$(mktemp)"
  trap 'rm -f "$TMP"' EXIT
  if kubectl kustomize "$KPATH" >"$TMP" 2>&1; then
    echo "[PASS] kustomize build ($KPATH)"
    echo "       output: $TMP"
    echo "       hint: grep for stale refs, then re-run script on $TMP as file"
  else
    echo "[FAIL] kustomize build ($KPATH):"
    cat "$TMP"
    exit 1
  fi
  ;;
--flux)
  shift
  NAME="${1:?--flux requires <name>}"
  KPATH="${2:?--flux requires <name> <path>}"
  # Kustomization name != filename for 3 of 5 (infrastructure-controllers →
  # infrastructure.yaml; monitoring-{controllers,configs} → monitoring.yaml, multi-doc).
  # flux build selects by NAME within the file, so locate the file by grep.
  CLUSTER_FILE="${CLUSTER:+clusters/${CLUSTER}.yaml}"
  if [ -z "$CLUSTER_FILE" ]; then
    # `|| true` — no-match grep rc=1 would set -e die before the friendly exit-3 below
    CLUSTER_FILE=$(grep -l "^  name: ${NAME}\$" clusters/*.yaml 2>/dev/null | head -1 || true)
  fi
  if [ -z "$CLUSTER_FILE" ] || [ ! -f "$CLUSTER_FILE" ]; then
    echo "(cd to homelab repo first; no clusters/*.yaml declares Kustomization '$NAME')" >&2
    exit 3
  fi
  flux build kustomization "$NAME" --path "$KPATH" --kustomization-file "$CLUSTER_FILE"
  ;;
*)
  for f in "$@"; do
    [ -f "$f" ] || {
      echo "[SKIP] $f (not a file)"
      continue
    }
    echo "=== $f ==="

    if yamllint -d '{extends: relaxed, rules: {line-length: disable}}' "$f" >/dev/null 2>&1; then
      echo "[PASS] yamllint"
    else
      echo "[FAIL] yamllint"
      yamllint -d '{extends: relaxed, rules: {line-length: disable}}' "$f" || true
      exit 1
    fi

    if kubeconform -strict -summary -ignore-missing-schemas "$f" >/dev/null 2>&1; then
      echo "[PASS] kubeconform (schema)"
    else
      echo "[FAIL] kubeconform:"
      kubeconform -strict -summary -ignore-missing-schemas "$f" || true
      exit 1
    fi

    if kubectl apply -f "$f" --dry-run=client >/dev/null 2>&1; then
      echo "[PASS] kubectl dry-run=client"
    else
      echo "[FAIL] kubectl dry-run=client:"
      kubectl apply -f "$f" --dry-run=client 2>&1 || true
      exit 1
    fi

    if kubectl apply -f "$f" --dry-run=server >/dev/null 2>&1; then
      echo "[PASS] kubectl dry-run=server (incl. Kyverno admission)"
    else
      out="$(kubectl apply -f "$f" --dry-run=server 2>&1 || true)"
      if echo "$out" | grep -q 'unknown field "sops"'; then
        echo "[SKIP] kubectl dry-run=server (SOPS overlay — use --kustomize or --flux mode)"
      elif echo "$out" | grep -q 'field is immutable' && grep -q 'kustomize.toolkit.fluxcd.io/force' "$f"; then
        # Existing resource + immutable field (e.g. Job spec.template) + Flux force:enabled
        # → server dry-run tries an UPDATE and fails, but Flux delete+recreates it.
        # Manifest itself is valid (lower rungs passed). False-positive — treat as PASS.
        echo "[PASS] kubectl dry-run=server (immutable field on force-managed resource — Flux recreates)"
      else
        echo "[FAIL] kubectl dry-run=server:"
        echo "$out"
        exit 1
      fi
    fi
  done
  ;;
esac
