#!/usr/bin/env bash
# When an alert won't clear after a fix, run cascade checks in correct order.
# Composite of existing diagnostics — saves 15+ probes per incident.
#
# Order (cheap → expensive):
#   1. Firing alerts snapshot (VMAlert + Alertmanager dual)
#   2. VMAgent queue (most common cause: stuck Go DNS resolver)
#   3. Per-instance metric freshness — last-sample age via time()-timestamp(), plus
#      MISSING-series detection (a scraped-away instance vanishes from instant queries)
#   4. Rule state via vmalert /api/v1/rules (firing/pending/inactive; only with <alertname>)
#
# Usage: alert-cascade-check.sh [<alertname>]
#   If alertname given, also queries its rule state directly.

set -euo pipefail
SHARED="$HOME/.agents/skills/_shared"
ALERT="${1:-}"

header() { printf '\n=== %s ===\n' "$1"; }

header "1. Firing alerts"
bash "$SHARED/check-alerts.sh" --count
bash "$SHARED/check-alerts.sh"

header "2. VMAgent remoteWrite queue + recent errors"
bash "$SHARED/vmagent-queue-check.sh" || true

header "3. Per-instance metric freshness (node-exporter up{})"
kubectl port-forward -n monitoring svc/vmsingle-vmsingle 18429:8429 >/dev/null 2>&1 &
PF=$!
trap '[ -n "${PF:-}" ] && kill "$PF" 2>/dev/null || true' EXIT
sleep 1
# time()-timestamp() = age of the LAST SAMPLE; instant-query .value[0] is eval-time (always ~0).
FRESH="$(curl -sG --max-time 10 --data-urlencode \
  'query=time() - timestamp(up{job="kube-prometheus-stack-prometheus-node-exporter"})' \
  'http://127.0.0.1:18429/api/v1/query' 2>/dev/null || true)"
if [ -n "$FRESH" ]; then
  echo "$FRESH" | jq -r '.data.result[] | "\(.metric.instance) last-sample-age=\(.value[1] | tonumber | floor)s"' 2>/dev/null ||
    echo "(query failed — unparseable response)"
  # A stale series VANISHES from instant queries — absence, not age, is the stale signal.
  # Expected set: node-exporter is per-node hostNetwork, instance = <nodeInternalIP>:9100.
  INSTANCES="$(echo "$FRESH" | jq -r '.data.result[].metric.instance' 2>/dev/null || true)"
  NODES="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null || true)"
  if [ -n "$NODES" ]; then
    while IFS= read -r ip; do
      [ -z "$ip" ] && continue
      echo "$INSTANCES" | grep -q "^${ip}:" ||
        echo "MISSING series: node $ip absent from up{} — scraped away (check vmagent targets)"
    done <<<"$NODES"
  else
    echo "(node list unavailable — got $(echo "$INSTANCES" | grep -c .) series; an absent series = scraped-away)"
  fi
else
  echo "(query failed — vmsingle unreachable; see step 2)"
fi

if [ -n "$ALERT" ]; then
  header "4. Rule state for $ALERT"
  kubectl port-forward -n monitoring svc/vmalert-vmalert 18080:8080 >/dev/null 2>&1 &
  PF2=$!
  trap '[ -n "${PF:-}" ] && kill "$PF" 2>/dev/null || true; [ -n "${PF2:-}" ] && kill "$PF2" 2>/dev/null || true' EXIT
  sleep 1
  # /api/v1/rules not /alerts: an inactive rule still appears (state=inactive), so a dead rule
  # is distinguishable from a typo'd name. Strip control chars — vmalert leaks raw newlines
  # into JSON from multi-line exprs (same gotcha as vmalert-state.sh).
  RULES="$(curl -s --max-time 10 'http://127.0.0.1:18080/api/v1/rules' 2>/dev/null | LC_ALL=C tr -d '\000-\037' || true)"
  if [ -z "$RULES" ]; then
    echo "(vmalert unreachable)"
  else
    MATCH="$(echo "$RULES" | jq --arg n "$ALERT" \
      '[.data.groups[].rules[]? | select(.name == $n)
        | {name, state, health, lastError: (.lastError // ""),
           alerts: [.alerts[]? | {state, activeAt, value}]}]' 2>/dev/null || echo '[]')"
    if [ "$(echo "$MATCH" | jq 'length')" -eq 0 ]; then
      echo "RULE NOT FOUND: $ALERT (typo, or rule not loaded by vmalert)"
    else
      echo "$MATCH" | jq .
    fi
  fi
fi

cat <<'EOF'

=== fix order (try this BEFORE reverting upstream) ===
  step 2 shows pending > 10MB + DNS errors → ~/.agents/skills/_shared/restart-workload.sh monitoring app.kubernetes.io/name=vmagent
  step 3 shows last-sample-age > 120s or a MISSING series → scrape broken for that instance, check vmagent targets / textfile dir
  step 4 shows state=firing/pending with a stale value → wait 1-2 rule cycles (60s each) + for: window; state=inactive → alert cleared, AM just lagging
EOF
