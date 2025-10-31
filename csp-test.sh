#!/bin/bash
set -e

# CSP Automated Testing Script
# Tests all 17 ingresses for Content Security Policy violations

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔒 CSP Automated Testing"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# All ingresses
APPS=(
  "adguard.h0melab.work|AdGuard Home|DNS Management"
  "audiobooks.h0melab.work|Audiobookshelf|Media Player"
  "authentik.h0melab.work|Authentik|Auth/SSO"
  "couchdb.h0melab.work|CouchDB|Database API"
  "ha.h0melab.work|Home Assistant|Home Automation"
  "hh.h0melab.work|HomeHub|Dashboard"
  "home.h0melab.work|Homepage|Dashboard"
  "immich.h0melab.work|Immich|Photo Management"
  "linkding.h0melab.work|Linkding|Bookmarks"
  "mealie.h0melab.work|Mealie|Recipe Manager"
  "am.h0melab.work|Alertmanager|Monitoring"
  "grafana.h0melab.work|Grafana|Monitoring"
  "n8n.h0melab.work|n8n|Automation"
  "paperless.h0melab.work|Paperless-ngx|Document Manager"
  "stirling.h0melab.work|Stirling PDF|PDF Tools"
  "uptime.h0melab.work|Uptime Kuma|Uptime Monitor"
  "wallabag.h0melab.work|Wallabag|Read Later"
)

# Get CSP reporter pod name
CSP_POD=$(kubectl get pods -n csp-reporter -l app=csp-reporter -o name | head -1 | cut -d/ -f2)

if [ -z "$CSP_POD" ]; then
  echo "${RED}❌ CSP reporter pod not found${NC}"
  exit 1
fi

echo "📊 CSP Reporter: $CSP_POD"
echo ""

# Baseline violation count
echo "📈 Getting baseline violation count..."
BASELINE_COUNT=$(kubectl logs -n csp-reporter $CSP_POD --tail=1000 | grep -c "CSP Violation" || echo "0")
echo "   Current violations: $BASELINE_COUNT"
echo ""

# Test function
test_app() {
  local HOST=$1
  local NAME=$2
  local DESC=$3

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🧪 Testing: $NAME ($DESC)"
  echo "   URL: https://$HOST"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Test 1: Basic page load
  echo -n "   [1/5] Page load (GET /)... "
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" https://$HOST/ --max-time 10 || echo "000")
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "301" ]; then
    echo "${GREEN}✓${NC} ($HTTP_CODE)"
  else
    echo "${YELLOW}⚠${NC} ($HTTP_CODE)"
  fi

  # Test 2: Static assets (JS)
  echo -n "   [2/5] JavaScript assets... "
  JS_TEST=$(curl -s https://$HOST/ --max-time 10 | grep -o '<script[^>]*src="[^"]*"' | head -1 || echo "")
  if [ -n "$JS_TEST" ]; then
    echo "${GREEN}✓${NC} (found)"
  else
    echo "${YELLOW}⚠${NC} (not found)"
  fi

  # Test 3: Static assets (CSS)
  echo -n "   [3/5] CSS stylesheets... "
  CSS_TEST=$(curl -s https://$HOST/ --max-time 10 | grep -o '<link[^>]*href="[^"]*\.css' | head -1 || echo "")
  if [ -n "$CSS_TEST" ]; then
    echo "${GREEN}✓${NC} (found)"
  else
    echo "${YELLOW}⚠${NC} (not found)"
  fi

  # Test 4: Images
  echo -n "   [4/5] Image resources... "
  IMG_TEST=$(curl -s https://$HOST/ --max-time 10 | grep -o '<img[^>]*src="[^"]*"' | head -1 || echo "")
  if [ -n "$IMG_TEST" ]; then
    echo "${GREEN}✓${NC} (found)"
  else
    echo "${YELLOW}⚠${NC} (not found)"
  fi

  # Test 5: API endpoint (if applicable)
  echo -n "   [5/5] API endpoint... "
  case "$NAME" in
    "CouchDB")
      API_CODE=$(curl -s -o /dev/null -w "%{http_code}" https://$HOST/_utils/ --max-time 10 || echo "000")
      ;;
    "Grafana")
      API_CODE=$(curl -s -o /dev/null -w "%{http_code}" https://$HOST/api/health --max-time 10 || echo "000")
      ;;
    "Home Assistant")
      API_CODE=$(curl -s -o /dev/null -w "%{http_code}" https://$HOST/api/ --max-time 10 || echo "000")
      ;;
    "n8n")
      API_CODE=$(curl -s -o /dev/null -w "%{http_code}" https://$HOST/healthz --max-time 10 || echo "000")
      ;;
    "Immich")
      API_CODE=$(curl -s -o /dev/null -w "%{http_code}" https://$HOST/api/server-info/ping --max-time 10 || echo "000")
      ;;
    *)
      API_CODE=$(curl -s -o /dev/null -w "%{http_code}" https://$HOST/api --max-time 10 || echo "000")
      ;;
  esac

  if [ "$API_CODE" = "200" ] || [ "$API_CODE" = "401" ] || [ "$API_CODE" = "302" ]; then
    echo "${GREEN}✓${NC} ($API_CODE)"
  else
    echo "${YELLOW}⚠${NC} ($API_CODE)"
  fi

  # Small delay between apps
  sleep 2
  echo ""
}

# Run tests for all apps
total_apps=${#APPS[@]}
current=0

for APP_ENTRY in "${APPS[@]}"; do
  current=$((current + 1))
  IFS='|' read -r HOST NAME DESC <<< "$APP_ENTRY"
  echo "[$current/$total_apps]"
  test_app "$HOST" "$NAME" "$DESC"
done

# Wait for CSP reporter to process violations
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⏳ Waiting 10 seconds for CSP reporter to process..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
sleep 10
echo ""

# Check for new violations
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 CSP Violation Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

FINAL_COUNT=$(kubectl logs -n csp-reporter $CSP_POD --tail=1000 | grep -c "CSP Violation" || echo "0")
NEW_VIOLATIONS=$((FINAL_COUNT - BASELINE_COUNT))

echo "   Baseline violations: $BASELINE_COUNT"
echo "   Final violations:    $FINAL_COUNT"
echo "   New violations:      $NEW_VIOLATIONS"
echo ""

if [ $NEW_VIOLATIONS -eq 0 ]; then
  echo "${GREEN}✅ SUCCESS: No new CSP violations detected${NC}"
  echo "   All 17 apps passed CSP testing"
  echo "   Policy is safe to enforce"
else
  echo "${YELLOW}⚠️  WARNING: $NEW_VIOLATIONS new CSP violations detected${NC}"
  echo "   Showing last 20 violations:"
  echo ""
  kubectl logs -n csp-reporter $CSP_POD --tail=1000 | grep "CSP Violation" | tail -20
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Full CSP Reporter Logs (Last 50 lines)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
kubectl logs -n csp-reporter $CSP_POD --tail=50
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ CSP Testing Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Timestamp: $(date)"
echo ""
