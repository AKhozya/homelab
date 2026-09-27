#!/usr/bin/env bash
# Capture infra state into ~/.claude/sessions/checkpoint-<name>.md
#
# Usage: collect.sh <name>

set -euo pipefail
NAME="${1:-}"
if [ -z "$NAME" ]; then
  echo "usage: $0 <name>" >&2
  exit 2
fi

REPO="${HOMELAB_REPO:-$HOME/source-code/homelab}"
SHARED="$HOME/.agents/skills/_shared"
OUT_DIR="$HOME/.claude/sessions"
OUT="$OUT_DIR/checkpoint-${NAME}.md"
mkdir -p "$OUT_DIR"

TS="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
SHA="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
NODES="$(kubectl get nodes -o wide 2>/dev/null || echo 'kubectl unavailable')"

POD_COUNT_LINE="$(bash "$SHARED/pod-health.sh" --count 2>/dev/null || echo 'total=? running=? unhealthy=? stale=?')"
# flux-status prints its own sentinel line AND exits 2 on failure — `|| echo` would
# APPEND a second sentinel line. Capture, then normalize only if truly empty.
FLUX_LINE="$(bash "$SHARED/flux-status.sh" --count 2>/dev/null || true)"
[ -n "$FLUX_LINE" ] || FLUX_LINE='ready=? total=? failed=? reconciling=?'
FLUX_DETAIL="$(bash "$SHARED/flux-status.sh" 2>/dev/null || echo '')"
ALERTS_LINE="$(bash "$SHARED/check-alerts.sh" --count 2>/dev/null || echo 'vmalert=? alertmanager=?')"
ALERTS_DETAIL="$(bash "$SHARED/check-alerts.sh" 2>/dev/null || echo '')"

PG="$(kubectl get cluster -n databases main-postgres -o jsonpath='{.status.readyInstances}/{.status.instances}' 2>/dev/null || echo '?/?')"
MYSQL="$(kubectl get ps -n databases main-mysql -o jsonpath='{.status.state}' 2>/dev/null || echo '?')"
# CouchDB + Redis live in `databases` ns; count by name pattern (label selectors vary by chart).
# Capture the fetch first: kubectl outage prints '?', never a false zero.
if DB_PODS="$(kubectl get pods -n databases --no-headers 2>/dev/null)"; then
  COUCHDB="$(printf '%s\n' "$DB_PODS" | grep -c '^couchdb-' || true)"
  REDIS="$(printf '%s\n' "$DB_PODS" | grep -cE '^redis-' || true)"
else
  COUCHDB='?'
  REDIS='?'
fi

cat >"$OUT" <<EOF
# Checkpoint: ${NAME}
**Created**: ${TS}
**Git SHA**: ${SHA}

## Nodes
\`\`\`
${NODES}
\`\`\`

## Pods
${POD_COUNT_LINE}

## Flux Kustomizations
${FLUX_LINE}

\`\`\`
${FLUX_DETAIL}
\`\`\`

## Alerts
${ALERTS_LINE}

\`\`\`
${ALERTS_DETAIL}
\`\`\`

## Databases
- PostgreSQL: ${PG}
- MySQL: ${MYSQL}
- CouchDB pods: ${COUCHDB}
- Redis pods: ${REDIS}
EOF

echo "wrote $OUT"
