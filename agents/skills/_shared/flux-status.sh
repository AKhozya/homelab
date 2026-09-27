#!/usr/bin/env bash
# Flux kustomization (and optionally helmrelease) readiness status.
#
# READY column split: True=ready, False=failed, Unknown=reconciling (progressing, not failed).
#
# Flags:
#   --kust       (default) kustomizations only
#   --all        kustomizations + helmreleases
#   --failed     only non-Ready
#   --count      "ready=N total=N failed=N reconciling=N"
# Flux CLI failure/empty output → "ready=? total=? failed=? reconciling=?" (--count)
# or "(flux unavailable)" (other modes), exit 2.

set -euo pipefail
mode="${1:---kust}"

get_hr() { flux get helmreleases -A --no-header 2>/dev/null; }

# `flux get kustomizations -A --no-header` columns: NAMESPACE NAME REVISION SUSPENDED READY STATUS
if ! K="$(flux get kustomizations -A --no-header 2>/dev/null)" || [ -z "$K" ]; then
  if [ "$mode" = "--count" ]; then
    echo "ready=? total=? failed=? reconciling=?"
  else
    echo "(flux unavailable)"
  fi
  exit 2
fi

case "$mode" in
--count)
  TOT=$(echo "$K" | grep -c . || true)
  READY=$(echo "$K" | awk '$5=="True"' | grep -c . || true)
  FAIL=$(echo "$K" | awk '$5=="False"' | grep -c . || true)
  REC=$(echo "$K" | awk '$5=="Unknown"' | grep -c . || true)
  echo "ready=$READY total=$TOT failed=$FAIL reconciling=$REC"
  ;;
--failed)
  echo "$K" | awk '$5!="True"'
  # Capture first: a masked `get_hr | awk || true` would silently omit ALL HelmRelease
  # failures when the hr fetch itself dies.
  if HR="$(get_hr)"; then
    echo "$HR" | awk '$5!="True"'
  else
    echo "(flux helmrelease fetch failed)"
  fi
  ;;
--all)
  echo "=== KUSTOMIZATIONS ==="
  echo "$K"
  echo "=== HELMRELEASES ==="
  get_hr || echo "(flux helmrelease fetch failed)"
  ;;
*)
  echo "$K"
  ;;
esac
