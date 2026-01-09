#!/bin/bash
# Hourly NetworkPolicy Monitor - runs for 24 hours
# Logs to .monitoring-scripts/hourly-monitor.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/hourly-monitor.log"
CHECK_SCRIPT="$SCRIPT_DIR/check-networkpolicy-health.sh"
HOURS=24
INTERVAL=3600  # 1 hour in seconds

echo "Starting 24-hour monitoring at $(date -u '+%Y-%m-%d %H:%M:%S UTC')" | tee "$LOG_FILE"
echo "Log file: $LOG_FILE"
echo "=========================================="

for ((i=1; i<=HOURS; i++)); do
    echo "" >> "$LOG_FILE"
    echo "########## CHECK $i of $HOURS - $(date -u '+%Y-%m-%d %H:%M:%S UTC') ##########" >> "$LOG_FILE"

    # Run the health check
    if $CHECK_SCRIPT >> "$LOG_FILE" 2>&1; then
        echo "Check $i: ✅ PASSED at $(date -u '+%H:%M UTC')"
    else
        echo "Check $i: ⚠️  ISSUES DETECTED at $(date -u '+%H:%M UTC') - see log"
    fi

    # Check for any failures in the output
    if tail -30 "$LOG_FILE" | grep -qE "⚠️|FAILED|refused|timeout"; then
        echo "  └─ Warning indicators found in check $i"
    fi

    # Wait for next check (unless this is the last one)
    if [ $i -lt $HOURS ]; then
        echo "  └─ Next check in 1 hour..."
        sleep $INTERVAL
    fi
done

echo ""
echo "=========================================="
echo "24-hour monitoring complete at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Review full log: $LOG_FILE"
