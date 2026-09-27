#!/usr/bin/env bash
# Pod health snapshot. All modes classify with the SAME jq filter, so --count's
# unhealthy=N always matches N detail rows.
#
# Flags:
#   --count   "total=N running=R unhealthy=U stale=S"
#   --json    unhealthy pods [{namespace, name, phase, ready, reason}]
#   (default) unhealthy pods table
# Fetch failure prints "unavailable" / "(fetch failed)" — never rendered as clean.

set -euo pipefail
fmt="${1:-text}"

# Classify on container-READINESS, not phase alone. Two reasons a phase-only filter lies:
#   - a CrashLoopBackOff pod is phase=Running but Ready=False → a phase!=Running filter MISSES it.
#   - Failed/Evicted pods are terminal leftovers (GC-able), not an active fault → a phase!=Running
#     filter COUNTS them as unhealthy, so deleting stale junk falsely "improves" health.
# Split them: unhealthy = actively broken (running-but-not-ready, Pending, Unknown); stale = terminal.
DEFS='
  def is_ready: any((.status.conditions // [])[]; .type == "Ready" and .status == "True");
  def is_stale: (.status.phase != "Succeeded")
    and ((.status.phase == "Failed") or ((.status.reason // "") == "Evicted"));
  def is_unhealthy: (.status.phase != "Succeeded") and (is_stale | not)
    and ((.status.phase == "Running" and is_ready) | not);
'

case "$fmt" in
--count)
  kubectl get pods -A -o json 2>/dev/null | jq -r "$DEFS"'
    .items
    | "total=\(length)"
      + " running=\(map(select(.status.phase == "Running" and is_ready)) | length)"
      + " unhealthy=\(map(select(is_unhealthy)) | length)"
      + " stale=\(map(select(is_stale)) | length)"' || echo "unavailable"
  ;;
--json)
  kubectl get pods -A -o json 2>/dev/null | jq "$DEFS"'
    [.items[] | select(is_unhealthy) |
      {namespace: .metadata.namespace, name: .metadata.name,
       phase: .status.phase, ready: is_ready,
       reason: ((.status.containerStatuses // [])[0].state.waiting.reason // .status.reason // "")}]' ||
    echo "unavailable"
  ;;
*)
  kubectl get pods -A -o json 2>/dev/null | jq -r "$DEFS"'
    (["NAMESPACE", "NAME", "PHASE", "READY", "REASON"] | @tsv),
    (.items[] | select(is_unhealthy) |
      [.metadata.namespace, .metadata.name, (.status.phase // "?"),
       "\([(.status.containerStatuses // [])[] | select(.ready)] | length)/\((.status.containerStatuses // []) | length)",
       ((.status.containerStatuses // [])[0].state.waiting.reason // .status.reason // "-")]
      | @tsv)' | column -t || echo "(fetch failed)"
  ;;
esac
