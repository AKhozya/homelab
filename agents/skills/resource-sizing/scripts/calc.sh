#!/usr/bin/env bash
# Compute request/limit from observed value.
#   request = observed * 1.2
#   limit   = observed * 1.5
#
# Usage:
#   calc.sh <observed_mb>          # memory -> MiB
#   calc.sh <observed_millicpu> m  # cpu (milli)
#
# Examples:
#   calc.sh 512      -> request=615Mi limit=768Mi
#   calc.sh 250 m    -> request=300m limit=375m

set -euo pipefail
OBS="${1:-}"
UNIT="${2:-mi}"

if [ -z "$OBS" ]; then
  echo "usage: $0 <observed> [m|mi]" >&2
  exit 2
fi

# Reject fractional input BEFORE the strip — tr would silently turn 1.5 into 15.
case "$OBS" in
*.*)
  echo "non-integer input '$OBS' — pass whole units (e.g. 1536 not 1.5Gi)" >&2
  exit 2
  ;;
esac

# Strip non-numeric tail (Mi, m, etc)
N="$(printf '%s' "$OBS" | tr -dc '0-9')"
if [ -z "$N" ]; then
  echo "no numeric value in '$OBS'" >&2
  exit 2
fi

# ceil to int (awk has no ceil)
REQ="$(awk -v n="$N" 'BEGIN{r=n*1.2; printf "%d", (r==int(r))?r:int(r)+1}')"
LIM="$(awk -v n="$N" 'BEGIN{l=n*1.5; printf "%d", (l==int(l))?l:int(l)+1}')"

case "$UNIT" in
m | M)
  echo "request=${REQ}m limit=${LIM}m"
  ;;
*)
  echo "request=${REQ}Mi limit=${LIM}Mi"
  ;;
esac
