#!/bin/bash
# NetworkPolicy Health Check Script
# Run periodically over 24h to monitor for issues after NetworkPolicy deployment
# Usage: ./check-networkpolicy-health.sh

set -euo pipefail

echo "=========================================="
echo "NetworkPolicy Health Check - $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "=========================================="

# 1. Check firing alerts (excluding Watchdog/InfoInhibitor)
echo ""
echo "=== FIRING ALERTS ==="
ALERTS=$(kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  promtool query instant http://localhost:9090 'ALERTS{alertstate="firing"}' 2>/dev/null | \
  grep -v "Watchdog" | grep -v "InfoInhibitor" || true)

if [ -z "$ALERTS" ]; then
  echo "✅ No critical alerts firing"
else
  echo "⚠️  Alerts detected:"
  echo "$ALERTS"
fi

# 2. Check NetworkPolicy-affected namespaces
echo ""
echo "=== NETWORKPOLICY NAMESPACE STATUS ==="
for ns in cloudflare-tunnel loki traefik csp-reporter obsidian popeye; do
  STATUS=$(kubectl get pods -n $ns --no-headers 2>/dev/null | awk '{print $3}' | sort | uniq -c | tr '\n' ' ' || echo "N/A")
  FAILED=$(kubectl get pods -n $ns --no-headers 2>/dev/null | grep -cvE 'Running|Completed' 2>/dev/null || echo "0")
  FAILED=$(echo "$FAILED" | tr -d '[:space:]')
  if [ -z "$FAILED" ]; then FAILED=0; fi
  if [ "$FAILED" -gt 0 ] 2>/dev/null; then
    echo "⚠️  $ns: $STATUS"
  else
    echo "✅ $ns: $STATUS"
  fi
done

# 3. Check for connection errors in logs
echo ""
echo "=== RECENT CONNECTION ERRORS ==="
echo "--- Traefik (last 5 connection errors) ---"
kubectl logs -n traefik deploy/traefik --since=1h 2>/dev/null | grep -iE 'connection refused|timeout|unreachable' | tail -5 || echo "None"

echo "--- Loki Gateway (last 5 errors) ---"
kubectl logs -n loki deploy/loki-gateway --since=1h 2>/dev/null | grep -iE '502|503|504|error' | tail -5 || echo "None"

echo "--- CSP Reporter (last 5 errors) ---"
kubectl logs -n csp-reporter deploy/csp-reporter --since=1h 2>/dev/null | grep -iE 'error|failed' | tail -5 || echo "None"

# 4. Check for NetworkPolicy-related events
echo ""
echo "=== NETWORKPOLICY-RELATED EVENTS (last hour) ==="
kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' 2>/dev/null | \
  grep -iE 'network|connection|timeout|refused' | tail -5 || echo "None"

# 5. Quick connectivity tests
echo ""
echo "=== CONNECTIVITY TESTS ==="

# Test CSP reporter from Traefik (404 = connection works, just no GET handler)
CSP_TEST=$(kubectl exec -n traefik deploy/traefik -- wget -qO- --timeout=5 'http://csp-reporter.csp-reporter.svc.cluster.local:80/' 2>&1 || true)
if echo "$CSP_TEST" | grep -q "404"; then
  echo "✅ Traefik → CSP Reporter: OK (404 expected)"
elif echo "$CSP_TEST" | grep -qi "refused\|timeout"; then
  echo "⚠️  Traefik → CSP Reporter: FAILED - $CSP_TEST"
else
  echo "✅ Traefik → CSP Reporter: OK"
fi

# Test Loki gateway accessibility
if kubectl logs -n loki deploy/loki-gateway --tail=1 2>/dev/null | grep -qE "200|204"; then
  echo "✅ Loki Gateway: Receiving requests"
else
  echo "⚠️  Loki Gateway: Check logs"
fi

# Test promtail pushing logs
PROMTAIL_PUSH=$(kubectl logs -n loki deploy/loki-gateway --since=5m 2>/dev/null | grep -c "promtail" || echo "0")
if [ "$PROMTAIL_PUSH" -gt 0 ]; then
  echo "✅ Promtail → Loki: $PROMTAIL_PUSH pushes in last 5min"
else
  echo "⚠️  Promtail → Loki: No pushes detected"
fi

echo ""
echo "=========================================="
echo "Check complete. Run again in 1-4 hours."
echo "=========================================="
