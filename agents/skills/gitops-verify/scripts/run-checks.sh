#!/usr/bin/env bash
# Run all 7 gitops-verify checks. Emit JSON so the agent only formats the table.
#
# Checks: git, yaml-dry-run (recent), flux, pods, events, alerts, kyverno.
#
# Flags:
#   --json    (default) one JSON object
#   --text    human-readable summary
#
# Repo path can be overridden:
#   HOMELAB_REPO=~/source-code/homelab (default)

set -euo pipefail
fmt="${1:---json}"
REPO="${HOMELAB_REPO:-$HOME/source-code/homelab}"
SHARED="$HOME/.agents/skills/_shared"

# --- Check 1: git status ---
GIT_DIRTY="$(git -C "$REPO" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"

# --- Check 2: yaml dry-run on recently changed files ---
YAML_PASS=0
YAML_FAIL=0
YAML_SKIP=0
YAML_FILES="$(git -C "$REPO" diff --name-only HEAD~1 -- '*.yaml' 2>/dev/null | awk 'NR<=5')"
if [ -z "$YAML_FILES" ]; then
  YAML_SKIP=1
else
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ ! -f "$REPO/$f" ] && continue
    if out="$(kubectl apply -f "$REPO/$f" --dry-run=server 2>&1)"; then
      YAML_PASS=$((YAML_PASS + 1))
    elif echo "$out" | grep -q 'unknown field "sops"'; then
      # SOPS overlay — server rejects the sops field, not the manifest (see validate.sh)
      YAML_SKIP=$((YAML_SKIP + 1))
    else
      YAML_FAIL=$((YAML_FAIL + 1))
    fi
  done <<<"$YAML_FILES"
fi

# Checks 3-7: fetch failure emits a sentinel ('unavailable' / '?'), never a
# fake-healthy zero. _shared scripts may themselves emit '?' tokens.

# --- Check 3: flux ---
# flux-status prints its own sentinel line AND exits 2 on failure — `|| echo` would
# append a second line. Capture, then normalize only if truly empty.
FLUX_COUNT="$(bash "$SHARED/flux-status.sh" --count 2>/dev/null || true)"
[ -n "$FLUX_COUNT" ] || FLUX_COUNT='unavailable'

# --- Check 4: pods ---
POD_COUNT="$(bash "$SHARED/pod-health.sh" --count 2>/dev/null || echo 'unavailable')"

# --- Check 5: events (Warning, last 5 min) ---
EVENTS_N="$(kubectl get events -A --field-selector=type=Warning -o json 2>/dev/null |
  jq '[.items[] | select(((.lastTimestamp // .eventTime // empty) | fromdateiso8601? // 0) > (now - 300))] | length' 2>/dev/null || echo '?')"

# --- Check 6: alerts ---
ALERTS_COUNT="$(bash "$SHARED/check-alerts.sh" --count 2>/dev/null || echo 'unavailable')"

# --- Check 7: kyverno violations ---
KYV_N="$(kubectl get policyreport -A -o json 2>/dev/null | jq '[.items[].results[]? | select(.result=="fail")] | length' 2>/dev/null || echo '?')"

case "$fmt" in
--text)
  echo "git_dirty=$GIT_DIRTY"
  echo "yaml: pass=$YAML_PASS fail=$YAML_FAIL skip=$YAML_SKIP"
  echo "flux: $FLUX_COUNT"
  echo "pods: $POD_COUNT"
  echo "events_warn_recent=$EVENTS_N"
  echo "alerts: $ALERTS_COUNT"
  echo "kyverno_violations=$KYV_N"
  ;;
*)
  jq -n \
    --arg git_dirty "$GIT_DIRTY" \
    --arg yp "$YAML_PASS" --arg yf "$YAML_FAIL" --arg ys "$YAML_SKIP" \
    --arg flux "$FLUX_COUNT" \
    --arg pods "$POD_COUNT" \
    --arg events "$EVENTS_N" \
    --arg alerts "$ALERTS_COUNT" \
    --arg kyv "$KYV_N" \
    '{
        git: {dirty_files: ($git_dirty|tonumber)},
        yaml: {pass: ($yp|tonumber), fail: ($yf|tonumber), skipped: ($ys|tonumber)},
        flux: $flux,
        pods: $pods,
        events_warn_recent: ($events | tonumber? // $events),
        alerts: $alerts,
        kyverno_violations: ($kyv | tonumber? // $kyv)
      }'
  ;;
esac
