#!/usr/bin/env bash
# Dual firing-alerts check: VMAlert (rule eval) + Alertmanager (notification pipeline).
# Gotcha: VMAlert-only check missed broken Telegram template.
#
# Output (one per line):
#   VMALERT|<severity>|<alertname>|<namespace>|<summary>
#   AM|<severity>|<alertname>|<namespace>
#   VMALERT|(fetch failed) / AM|(fetch failed) when that source is unreachable
# Exit 0 always (treat data as info).
#
# Flags:
#   --json   emit JSON {fetch_ok:{...}, vmalert:[...]|null, alertmanager:[...]|null}
#            (array is null + fetch_ok=false when that source is unreachable)
#   --count  emit "vmalert=N alertmanager=M" only ("?" when that fetch failed)

set -euo pipefail
fmt="${1:-text}"

# Through the API server's service proxy: the claude-telegram bot's grant in monitoring is `get`
# on services/proxy, and it names both service:port pairs below. A failed fetch must surface as
# fetch-failed ("?"), never as zero alerts.
SVC=/api/v1/namespaces/monitoring/services
VM_OK=1
VM_RAW="$(kubectl get --raw "$SVC/vmalert-vmalert:8080/proxy/api/v1/alerts" 2>/dev/null)" || {
  VM_OK=0
  VM_RAW='{}'
}
AM_OK=1
AM_RAW="$(kubectl get --raw "$SVC/kube-prometheus-stack-alertmanager:9093/proxy/api/v2/alerts" 2>/dev/null)" || {
  AM_OK=0
  AM_RAW='[]'
}

case "$fmt" in
--json)
  # fetch_ok flags: a fetch failure must not render as clean empty arrays (same
  # false-clean class as --count's "?" sentinel). null = source unreachable.
  jq -n --argjson vm "$VM_RAW" --argjson am "$AM_RAW" \
    --argjson vmok "$VM_OK" --argjson amok "$AM_OK" '{
      fetch_ok: {vmalert: ($vmok == 1), alertmanager: ($amok == 1)},
      vmalert: (if $vmok == 1 then ($vm.data.alerts // [] | map(select(.state=="firing"))
        | map({severity: (.labels.severity // "unknown"), alertname: .labels.alertname,
               namespace: (.labels.namespace // "cluster"),
               summary: (.annotations.summary // .annotations.description // "")})) else null end),
      alertmanager: (if $amok == 1 then ($am // [] | map(select(.status.state=="active"))
        | map({severity: (.labels.severity // "unknown"), alertname: .labels.alertname,
               namespace: (.labels.namespace // "cluster")})) else null end)
    }'
  ;;
--count)
  if [ "$VM_OK" -eq 1 ]; then
    VM_N=$(echo "$VM_RAW" | jq '[.data.alerts[]? | select(.state=="firing")] | length' 2>/dev/null || echo '?')
  else
    VM_N='?'
  fi
  if [ "$AM_OK" -eq 1 ]; then
    AM_N=$(echo "$AM_RAW" | jq '[.[]? | select(.status.state=="active")] | length' 2>/dev/null || echo '?')
  else
    AM_N='?'
  fi
  echo "vmalert=$VM_N alertmanager=$AM_N"
  ;;
*)
  if [ "$VM_OK" -eq 1 ]; then
    echo "$VM_RAW" | jq -r '.data.alerts[]? | select(.state=="firing") |
        "VMALERT|\(.labels.severity // "unknown")|\(.labels.alertname)|\(.labels.namespace // "cluster")|\(.annotations.summary // .annotations.description // "")"' 2>/dev/null || true
  else
    echo "VMALERT|(fetch failed)"
  fi
  if [ "$AM_OK" -eq 1 ]; then
    echo "$AM_RAW" | jq -r '.[]? | select(.status.state=="active") |
        "AM|\(.labels.severity // "unknown")|\(.labels.alertname)|\(.labels.namespace // "cluster")"' 2>/dev/null || true
  else
    echo "AM|(fetch failed)"
  fi
  ;;
esac
