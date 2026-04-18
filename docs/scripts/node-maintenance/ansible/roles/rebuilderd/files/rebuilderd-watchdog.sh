#!/bin/bash
SERVICE="rebuilderd-worker@1.service"

if ! systemctl is-active --quiet "$SERVICE"; then
    exit 0
fi

# Count spin indicators: "Suppressed" msgs OR "wait: pid" lines in last 5min
SPIN_COUNT=$(journalctl -u "$SERVICE" --since "5 min ago" --no-pager -q 2>/dev/null \
    | grep -cE "Suppressed|wait: pid" || true)

if [ "$SPIN_COUNT" -ge 5 ]; then
    REAL_LINES=$(journalctl -u "$SERVICE" --since "20 min ago" --no-pager -q 2>/dev/null \
        | grep -v "wait: pid" \
        | grep -v "Suppressed" \
        | grep -v '^\.\c$' \
        | grep -v "^$" \
        | wc -l)

    if [ "$REAL_LINES" -lt 5 ]; then
        echo "$(date -Iseconds) Stuck build detected (${SPIN_COUNT} spin lines, ${REAL_LINES} real). Restarting."
        systemctl restart "$SERVICE"
        logger -t rebuilderd-watchdog "Restarted $SERVICE due to stuck build"
    fi
fi
