#!/usr/bin/env bash
# Run full diagnostic sweep. Calls _shared scripts for shared logic.
#
# Sections: nodes, pods, events, flux, dbs, resources, np-gap, alerts.
# Output: section header + raw output per section.

set -euo pipefail
SHARED="$HOME/.agents/skills/_shared"

header() { printf '\n=== %s ===\n' "$1"; }

header "Nodes"
kubectl get nodes -o wide || true

header "Unhealthy pods"
bash "$SHARED/pod-health.sh" --count || true
bash "$SHARED/pod-health.sh" || true

header "Recent warning events (last 20)"
kubectl get events -A --sort-by='.lastTimestamp' --field-selector type!=Normal --no-headers 2>/dev/null | tail -20 || true

header "Flux status"
bash "$SHARED/flux-status.sh" --count || true
bash "$SHARED/flux-status.sh" --failed || true

header "Databases"
echo "PostgreSQL:"
kubectl get cluster -n databases main-postgres -o jsonpath='{.status.readyInstances}/{.status.instances}' 2>/dev/null || echo "?/?"
echo
echo "MySQL: $(kubectl get ps -n databases main-mysql -o jsonpath='{.status.state}' 2>/dev/null || echo '?')"
# CouchDB + Redis live in `databases` ns (not their own); count by name pattern not label.
# Capture the fetch first: kubectl outage prints '?', never a false zero.
if DB_PODS="$(kubectl get pods -n databases --no-headers 2>/dev/null)"; then
  echo "CouchDB pods: $(printf '%s\n' "$DB_PODS" | grep -c '^couchdb-' || true)"
  echo "Redis pods: $(printf '%s\n' "$DB_PODS" | grep -cE '^redis-' || true)"
else
  echo "CouchDB pods: ?"
  echo "Redis pods: ?"
fi

# `| head -10` would SIGPIPE upstream under `pipefail` and trip `|| echo`.
# Use awk NR<=10 (reads all, prints first 10) — no SIGPIPE.
header "Top memory pods"
kubectl top pods -A --sort-by=memory --no-headers 2>/dev/null | awk 'NR<=10' || echo "(metrics unavailable)"

header "Top CPU pods"
kubectl top pods -A --sort-by=cpu --no-headers 2>/dev/null | awk 'NR<=10' || echo "(metrics unavailable)"

header "NetworkPolicy gaps"
bash "$SHARED/np-gap.sh" || true

header "Firing alerts (VMAlert + Alertmanager)"
bash "$SHARED/check-alerts.sh" --count || true
bash "$SHARED/check-alerts.sh" || true
