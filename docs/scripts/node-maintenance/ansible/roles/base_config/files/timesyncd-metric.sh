#!/bin/bash
# timesyncd-metric.sh
# Emits clock-sync health metrics for node-exporter textfile collector.
# Runs via timesyncd-metric.timer every 60s.

set -uo pipefail

OUTDIR="/var/lib/node_exporter/textfile"
OUTFILE="${OUTDIR}/time_sync.prom"
TMPFILE="${OUTFILE}.tmp"
NODE="$(cat /etc/hostname)"

mkdir -p "$OUTDIR"

# NTPSynchronized: kernel clock disciplined by adj_time loop. 1 only when
# timesyncd successfully synced against an NTP server in last poll cycle.
if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q '^yes$'; then
    SYNCED=1
else
    SYNCED=0
fi

# systemd-timesyncd active flag.
if systemctl is-active --quiet systemd-timesyncd.service 2>/dev/null; then
    ACTIVE=1
else
    ACTIVE=0
fi

# Last sync drift in seconds (PollInterval × ServerOffset). Microseconds
# from `timedatectl timesync-status`. Best-effort parse — ignore failures.
DRIFT_SECONDS=0
DRIFT_RAW="$(timedatectl timesync-status 2>/dev/null | awk -F': *' '/Offset/{print $2}' | head -1)"
if [ -n "$DRIFT_RAW" ]; then
    case "$DRIFT_RAW" in
        *us*) DRIFT_SECONDS=$(awk -v v="${DRIFT_RAW%us*}" 'BEGIN{printf "%.9f", v/1000000}') ;;
        *ms*) DRIFT_SECONDS=$(awk -v v="${DRIFT_RAW%ms*}" 'BEGIN{printf "%.6f", v/1000}') ;;
        *s*)  DRIFT_SECONDS=$(awk -v v="${DRIFT_RAW%s*}" 'BEGIN{printf "%.3f", v}') ;;
    esac
fi
DRIFT_ABS=$(awk -v v="$DRIFT_SECONDS" 'BEGIN{print (v<0)?-v:v}')

cat > "${TMPFILE}" <<EOF
# HELP node_time_sync_synchronized Kernel clock synchronized via NTP (1=yes, 0=no)
# TYPE node_time_sync_synchronized gauge
node_time_sync_synchronized{node="${NODE}"} ${SYNCED}
# HELP node_time_sync_active systemd-timesyncd service is active (1=yes, 0=no)
# TYPE node_time_sync_active gauge
node_time_sync_active{node="${NODE}"} ${ACTIVE}
# HELP node_time_sync_drift_seconds Absolute clock offset from NTP server in seconds
# TYPE node_time_sync_drift_seconds gauge
node_time_sync_drift_seconds{node="${NODE}"} ${DRIFT_ABS}
EOF

mv "${TMPFILE}" "${OUTFILE}"
