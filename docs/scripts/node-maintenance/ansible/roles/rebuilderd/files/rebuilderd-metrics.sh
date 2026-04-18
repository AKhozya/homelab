#!/bin/bash
# Rebuilderd metrics exporter for node-exporter textfile collector
set -euo pipefail

OUTDIR="/var/lib/node_exporter/textfile"
OUTFILE="${OUTDIR}/rebuilderd.prom"
TMPFILE="${OUTFILE}.tmp"
NODE="$(cat /etc/hostname)"

if systemctl is-active --quiet 'rebuilderd-worker@*.service' 2>/dev/null; then
    ACTIVE=1
else
    ACTIVE=0
fi

GOOD=$(journalctl -u 'rebuilderd-worker@*' --since '2 hours ago' --no-pager 2>/dev/null \
    | grep -c 'marking as GOOD' || true)
BAD=$(journalctl -u 'rebuilderd-worker@*' --since '2 hours ago' --no-pager 2>/dev/null \
    | grep -c 'marking as BAD' || true)
TOTAL=$((GOOD + BAD))

cat > "${TMPFILE}" << EOF
# HELP rebuilderd_worker_active Whether a rebuilderd worker is running (1=active, 0=inactive)
# TYPE rebuilderd_worker_active gauge
rebuilderd_worker_active{node="${NODE}"} ${ACTIVE}
# HELP rebuilderd_builds_good_total GOOD (reproducible) builds in the last 2 hours
# TYPE rebuilderd_builds_good_total gauge
rebuilderd_builds_good_total{node="${NODE}"} ${GOOD}
# HELP rebuilderd_builds_bad_total BAD (non-reproducible) builds in the last 2 hours
# TYPE rebuilderd_builds_bad_total gauge
rebuilderd_builds_bad_total{node="${NODE}"} ${BAD}
# HELP rebuilderd_builds_total Total builds completed in the last 2 hours
# TYPE rebuilderd_builds_total gauge
rebuilderd_builds_total{node="${NODE}"} ${TOTAL}
EOF

mv "${TMPFILE}" "${OUTFILE}"
