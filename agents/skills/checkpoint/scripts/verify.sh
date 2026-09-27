#!/usr/bin/env bash
# Diff current infra state against saved checkpoint.
#
# Usage: verify.sh <name>
#
# Emits side-by-side comparison lines:
#   KEY|<saved>|<current>|<OK|CHANGED|DEGRADED>

set -euo pipefail
NAME="${1:-}"
if [ -z "$NAME" ]; then
  echo "usage: $0 <name>" >&2
  exit 2
fi

CHKFILE="$HOME/.claude/sessions/checkpoint-${NAME}.md"
if [ ! -f "$CHKFILE" ]; then
  echo "checkpoint not found: $CHKFILE" >&2
  exit 3
fi

SHARED="$HOME/.agents/skills/_shared"
REPO="${HOMELAB_REPO:-$HOME/source-code/homelab}"

# Extract saved values via grep/sed (file format is from collect.sh)
saved_sha="$(grep -m1 '^\*\*Git SHA\*\*:' "$CHKFILE" | sed 's/^.*: //')"
saved_pods="$(grep -m1 -E '^total=' "$CHKFILE")"
saved_flux="$(grep -m1 -E '^ready=' "$CHKFILE")"
saved_alerts="$(grep -m1 -E '^vmalert=' "$CHKFILE")"

# Fallback sentinels mirror collect.sh — a kubectl/flux outage shows '?', not silence.
cur_sha="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
cur_pods="$(bash "$SHARED/pod-health.sh" --count 2>/dev/null || echo 'total=? running=? unhealthy=? stale=?')"
# flux-status prints its own sentinel line AND exits 2 on failure — `|| echo` would
# APPEND a second sentinel line. Capture, then normalize only if truly empty.
cur_flux="$(bash "$SHARED/flux-status.sh" --count 2>/dev/null || true)"
[ -n "$cur_flux" ] || cur_flux='ready=? total=? failed=? reconciling=?'
cur_alerts="$(bash "$SHARED/check-alerts.sh" --count 2>/dev/null || echo 'vmalert=? alertmanager=?')"

status_eq() {
  if [ "$1" = "$2" ]; then
    echo OK
  else
    echo CHANGED
  fi
}

# True iff both operands are integers AND $2 > $1 (tolerates '?' / missing tokens).
num_gt() {
  [[ "$1" =~ ^[0-9]+$ ]] && [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -gt "$1" ]
}

# DEGRADED if unhealthy or failed increased; or alerts grew
degraded_check() {
  local key="$1" saved="$2" cur="$3"
  case "$key" in
  pods)
    local sU cU
    sU="$(echo "$saved" | sed -n 's/.*unhealthy=\([0-9]*\).*/\1/p')"
    cU="$(echo "$cur" | sed -n 's/.*unhealthy=\([0-9]*\).*/\1/p')"
    if num_gt "$sU" "$cU"; then
      echo DEGRADED
    else
      status_eq "$saved" "$cur"
    fi
    ;;
  flux)
    local sF cF
    sF="$(echo "$saved" | sed -n 's/.*failed=\([0-9]*\).*/\1/p')"
    cF="$(echo "$cur" | sed -n 's/.*failed=\([0-9]*\).*/\1/p')"
    if num_gt "$sF" "$cF"; then
      echo DEGRADED
    else
      status_eq "$saved" "$cur"
    fi
    ;;
  alerts)
    local sV sA cV cA
    sV="$(echo "$saved" | sed -n 's/.*vmalert=\([0-9]*\).*/\1/p')"
    sA="$(echo "$saved" | sed -n 's/.*alertmanager=\([0-9]*\).*/\1/p')"
    cV="$(echo "$cur" | sed -n 's/.*vmalert=\([0-9]*\).*/\1/p')"
    cA="$(echo "$cur" | sed -n 's/.*alertmanager=\([0-9]*\).*/\1/p')"
    if num_gt "$sV" "$cV" || num_gt "$sA" "$cA"; then
      echo DEGRADED
    else
      status_eq "$saved" "$cur"
    fi
    ;;
  *) status_eq "$saved" "$cur" ;;
  esac
}

echo "GIT_SHA|${saved_sha}|${cur_sha}|$(status_eq "$saved_sha" "$cur_sha")"
echo "PODS|${saved_pods}|${cur_pods}|$(degraded_check pods "$saved_pods" "$cur_pods")"
echo "FLUX|${saved_flux}|${cur_flux}|$(degraded_check flux "$saved_flux" "$cur_flux")"
echo "ALERTS|${saved_alerts}|${cur_alerts}|$(degraded_check alerts "$saved_alerts" "$cur_alerts")"
