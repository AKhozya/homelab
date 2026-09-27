#!/usr/bin/env bash
# Restart a workload WITHOUT `kubectl rollout restart`.
#
# Why this exists: the claude-telegram bot lost workload `patch` on 2026-08-06 (RBAC cannot express
# "only the restartedAt annotation", so the grant meant rewriting the whole pod template). It keeps
# `pods delete` cluster-wide, which restarts a Deployment-managed pod just as well — the ReplicaSet
# recreates it from the spec in git.
#
# Three traps this wraps. A naive `delete pod -l ... && rollout status` walks into all of them:
#
#   1. `delete pod -l <selector>` deletes EVERY matching replica at once. This deletes one pod at a
#      time and will not touch the next until the workload is back to its baseline Ready count.
#   2. "wait for a pod whose UID differs from the one I deleted" is NOT a sufficient gate on a
#      multi-replica workload: a sibling replica already satisfies it, so the wait returns instantly
#      and the loop shreds every replica back to back. The gate here is BOTH — the deleted UID is
#      gone AND the Ready count is back to baseline.
#   3. `rollout status` is not a gate after a direct delete at all: deleting a pod does not bump the
#      Deployment's generation, so it reports the PREVIOUS rollout complete and returns 0 while the
#      replacement is still pending.
#
# Direct deletion also bypasses PodDisruptionBudgets — only the Eviction API honours them, and the
# bot has no `pods/eviction` grant. So this refuses up front when a PDB covering the workload
# reports disruptionsAllowed=0, rather than quietly breaking the budget.
#
# NOT for databases. AGENTS.md forbids force-deleting DB pods, and CNPG/Percona expect restarts
# through their CRDs. Postgres, MySQL, CouchDB and Redis restarts are workstation-only.
#
# Usage:  restart-workload.sh <namespace> <label-selector> [timeout-seconds]
# Example: restart-workload.sh monitoring app.kubernetes.io/name=vmagent
#
# Operators on a workstation can still use `kubectl rollout restart`; only the bot cannot.
set -euo pipefail

NS="${1:?usage: restart-workload.sh <namespace> <label-selector> [timeout]}"
SEL="${2:?usage: restart-workload.sh <namespace> <label-selector> [timeout]}"
TIMEOUT="${3:-90}"

# EVERY kubectl JSON payload in this script goes through this gate. `jq` exits 0 on EMPTY input and
# prints nothing, so a kubectl that exits 0 with an empty body yields empty results that read as
# "no pods" / "no budgets" / "not covered" — every one of which is the permissive answer. Anything
# that is not an object with an `.items` array is refused. A legitimate `.items: []` passes: that is
# "none", which is an answer, unlike "".
json_list_ok() { printf '%s' "$1" | jq -e 'type == "object" and (.items | type) == "array"' >/dev/null 2>&1; }

# Returns non-zero rather than calling `exit`: this is invoked inside command substitutions, where
# an `exit` would only kill the subshell and leave the caller running on an empty string.
pods_json() {
  local out
  if ! out="$(kubectl -n "$NS" get pods -l "$SEL" -o json 2>&1)"; then
    echo "restart-workload: FAILED — could not list pods in $NS -l $SEL: $out" >&2
    return 1
  fi
  if ! json_list_ok "$out"; then
    echo "restart-workload: FAILED — pod list for -l $SEL was empty or not a list" >&2
    return 1
  fi
  printf '%s' "$out"
}

# Ready = Ready condition True and not terminating.
ready_count() {
  printf '%s' "$1" | jq '[ .items[]
    | select(.metadata.deletionTimestamp == null)
    | select([.status.conditions[]? | select(.type=="Ready" and .status=="True")] | length > 0)
  ] | length'
}
uid_present() { printf '%s' "$1" | jq -r --arg u "$2" '[.items[] | select(.metadata.uid == $u)] | length'; }

if ! SNAP="$(pods_json)"; then exit 1; fi
mapfile -t UIDS < <(printf '%s' "$SNAP" | jq -r '.items[].metadata.uid')
if [ "${#UIDS[@]}" -eq 0 ]; then
  echo "restart-workload: no pods match -l $SEL in $NS" >&2
  exit 1
fi
BASELINE="$(ready_count "$SNAP")"
if [ "$BASELINE" -eq 0 ]; then
  echo "restart-workload: no Ready pods match -l $SEL in $NS — refusing to cycle a workload that is already down" >&2
  exit 1
fi

# PDB check. A direct delete does not consult a budget — only the Eviction API does, and the bot
# has no pods/eviction grant — so honour it by hand or refuse. Fails CLOSED throughout: a PDB we
# cannot list, whose status is not populated, or whose selector we cannot evaluate, all count as
# blocking. Re-run before EVERY deletion, because a budget can reach zero mid-loop.
pdb_blocks() {
  # Returns 0 (true) when BLOCKED — inverted from usual shell style, so callers read
  # `if pdb_blocks; then exit 1; fi`.
  #
  # Every read and parse is checked EXPLICITLY. `set -e` is worthless here: bash suppresses errexit
  # for the whole body of a function invoked in a condition, and a helper that `exit`s inside a
  # command substitution only kills the subshell. Without these checks a failed read left the
  # variables empty and the predicate fell through to "not blocked" — fail-open, in the one function
  # whose entire job is to fail closed.
  local out snap mine names n pdb allowed seltype sel pods covered

  # Shape-check both payloads with `jq -e` BEFORE reading anything out of them. Plain jq exits 0 on
  # EMPTY input and prints nothing, so a kubectl that exits 0 but returns an empty body would have
  # produced an empty PDB name list, skipped the loop entirely, and returned "not blocked".
  # `jq -e` exits 4 on empty input and 1 on a false result, so both become refusals.
  # A legitimately empty `.items: []` still passes — that is "no PDBs", not "no answer".
  if ! out="$(kubectl -n "$NS" get poddisruptionbudgets -o json 2>&1)"; then
    echo "restart-workload: could not list PodDisruptionBudgets in $NS: $out — refusing" >&2
    return 0
  fi
  if ! json_list_ok "$out"; then
    echo "restart-workload: PodDisruptionBudget list from $NS was empty or not a list — refusing" >&2
    return 0
  fi
  if ! snap="$(kubectl -n "$NS" get pods -l "$SEL" -o json 2>&1)"; then
    echo "restart-workload: could not list pods while evaluating PDBs: $snap — refusing" >&2
    return 0
  fi
  if ! json_list_ok "$snap"; then
    echo "restart-workload: pod list for -l $SEL was empty or not a list — refusing" >&2
    return 0
  fi
  if ! mine="$(printf '%s' "$snap" | jq -c '[.items[].metadata.name] | sort' 2>&1)" || [ -z "$mine" ]; then
    echo "restart-workload: could not parse pod list: $mine — refusing" >&2
    return 0
  fi
  if ! names="$(printf '%s' "$out" | jq -r '.items[].metadata.name' 2>&1)"; then
    echo "restart-workload: could not parse PDB list: $names — refusing" >&2
    return 0
  fi

  for n in $names; do
    if ! pdb="$(printf '%s' "$out" | jq -c --arg n "$n" '.items[] | select(.metadata.name == $n)' 2>&1)" || [ -z "$pdb" ]; then
      echo "restart-workload: could not read PDB $n — refusing" >&2
      return 0
    fi
    if ! allowed="$(printf '%s' "$pdb" | jq -r '.status.disruptionsAllowed // "unknown"' 2>&1)" || [ -z "$allowed" ]; then
      echo "restart-workload: could not read disruptionsAllowed for PDB $n — refusing" >&2
      return 0
    fi
    # Absent status = not yet computed = unknown = blocking.
    if [ "$allowed" != "unknown" ] && [ "$allowed" -gt 0 ] 2>/dev/null; then continue; fi

    # policy/v1 selector semantics: a NULL selector selects no pods; an EMPTY selector {} selects
    # every pod in the namespace. Conflating the two over-refuses on the first and under-refuses
    # on the second.
    if ! seltype="$(printf '%s' "$pdb" | jq -r '
        if .spec.selector == null then "null"
        elif (((.spec.selector.matchLabels // {}) | length) == 0
              and ((.spec.selector.matchExpressions // []) | length) == 0) then "all"
        else "some" end' 2>&1)" || [ -z "$seltype" ]; then
      echo "restart-workload: could not read selector of PDB $n — refusing" >&2
      return 0
    fi
    case "$seltype" in
    null) continue ;;
    all)
      echo "restart-workload: PDB $n has an empty selector (every pod in $NS) and disruptionsAllowed=$allowed — refusing" >&2
      return 0
      ;;
    esac

    # matchExpressions is set-based; not evaluated here, so it counts as covering us.
    if ! covered="$(printf '%s' "$pdb" | jq -r '(.spec.selector.matchExpressions // []) | length' 2>&1)"; then
      echo "restart-workload: could not read matchExpressions of PDB $n — refusing" >&2
      return 0
    fi
    if [ "$covered" -gt 0 ] 2>/dev/null; then
      echo "restart-workload: PDB $n has disruptionsAllowed=$allowed and a matchExpressions selector this script cannot evaluate — refusing" >&2
      return 0
    fi

    if ! sel="$(printf '%s' "$pdb" | jq -r '.spec.selector.matchLabels | to_entries | map(.key+"="+.value) | join(",")' 2>&1)"; then
      echo "restart-workload: could not build selector for PDB $n — refusing" >&2
      return 0
    fi
    if ! pods="$(kubectl -n "$NS" get pods -l "$sel" -o json 2>&1)"; then
      echo "restart-workload: could not evaluate PDB $n selector ($sel): $pods — refusing" >&2
      return 0
    fi
    if ! json_list_ok "$pods"; then
      echo "restart-workload: pod list for PDB $n selector ($sel) was empty or not a list — refusing" >&2
      return 0
    fi
    if ! covered="$(printf '%s' "$pods" | jq -r --argjson mine "$mine" \
      '[.items[].metadata.name] | map(select(. as $x | $mine | index($x))) | length' 2>&1)" ||
      ! printf '%s' "$covered" | grep -qE '^[0-9]+$'; then
      echo "restart-workload: could not intersect PDB $n selector with target pods — refusing" >&2
      return 0
    fi
    if [ "$covered" -gt 0 ] 2>/dev/null; then
      echo "restart-workload: PDB $n covers these pods and reports disruptionsAllowed=$allowed." >&2
      echo "restart-workload: a direct pod delete bypasses the budget rather than respecting it — refusing." >&2
      echo "restart-workload: fix the degraded workload first, or cycle from a workstation." >&2
      return 0
    fi
  done
  return 1
}

if pdb_blocks; then exit 1; fi

echo "restart-workload: ${#UIDS[@]} pod(s), $BASELINE Ready, in $NS -l $SEL" >&2

for uid in "${UIDS[@]}"; do
  if ! cur="$(pods_json)"; then exit 1; fi
  name="$(printf '%s' "$cur" | jq -r --arg u "$uid" '.items[] | select(.metadata.uid == $u) | .metadata.name')"
  if [ -z "$name" ]; then
    echo "restart-workload: $uid already gone, skipping" >&2
    continue
  fi

  # Never start a deletion from a degraded state — that is how one-at-a-time still becomes an outage.
  if [ "$(ready_count "$cur")" -lt "$BASELINE" ]; then
    echo "restart-workload: FAILED — only $(ready_count "$cur")/$BASELINE Ready before deleting $name; stopping with the workload partially cycled" >&2
    exit 1
  fi

  if pdb_blocks; then
    echo "restart-workload: stopping with the workload partially cycled" >&2
    exit 1
  fi

  echo "restart-workload: deleting $name" >&2
  kubectl -n "$NS" delete pod "$name" --wait=false >/dev/null

  waited=0
  while [ "$waited" -lt "$TIMEOUT" ]; do
    if ! now="$(pods_json)"; then exit 1; fi
    if [ "$(uid_present "$now" "$uid")" -eq 0 ] && [ "$(ready_count "$now")" -ge "$BASELINE" ]; then
      echo "restart-workload: back to $BASELINE Ready after ${waited}s" >&2
      break
    fi
    sleep 3
    waited=$((waited + 3))
  done
  if [ "$waited" -ge "$TIMEOUT" ]; then
    echo "restart-workload: FAILED — $NS -l $SEL did not return to $BASELINE Ready within ${TIMEOUT}s" >&2
    echo "restart-workload: workload is partially cycled; no further pods deleted" >&2
    exit 1
  fi
done

echo "restart-workload: done" >&2
