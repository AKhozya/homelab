#!/bin/bash
# 2-hour rebuilderd test with storage monitoring - run on worker-node with sudo
set -e

API="http://127.0.0.1:8484/api/v0"
BUILD_DIR="/mnt/k8s-storage/rebuilderd/builds"
LOG_FILE="/tmp/rebuilderd-storage-log.txt"

echo "=== Rebuilderd Worker-1 (2-Hour Test v2) ==="
echo "Start time: $(date)"
echo ""

# Get initial counts
echo "=== Initial package status ==="
INITIAL_GOOD=$(curl -s "$API/pkgs/list?status=GOOD" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
INITIAL_BAD=$(curl -s "$API/pkgs/list?status=BAD" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
echo "GOOD: $INITIAL_GOOD | BAD: $INITIAL_BAD"
echo ""

# Clear storage log
echo "timestamp,build_dir_mb,disk_used_gb,disk_avail_gb" > "$LOG_FILE"

# Start local worker
echo "=== Starting worker ==="
sudo systemctl start rebuilderd-worker@1
echo "Worker started!"
echo ""

echo "=== Running for 2 hours (logging storage every 10 min) ==="
echo "Will stop at: $(date -d '+2 hours')"
echo ""

# Monitor storage in background
(
    for i in {1..12}; do
        sleep 600
        TIMESTAMP=$(date '+%H:%M')
        BUILD_SIZE=$(du -sm "$BUILD_DIR" 2>/dev/null | cut -f1 || echo "0")
        DISK_USED=$(df -BG /mnt/k8s-storage | tail -1 | awk '{print $3}' | tr -d 'G')
        DISK_AVAIL=$(df -BG /mnt/k8s-storage | tail -1 | awk '{print $4}' | tr -d 'G')
        echo "$TIMESTAMP,$BUILD_SIZE,$DISK_USED,$DISK_AVAIL" >> "$LOG_FILE"
        echo "[${TIMESTAMP}] Build dir: ${BUILD_SIZE}MB | Disk used: ${DISK_USED}GB"
    done
) &
MONITOR_PID=$!

# Show logs for 2 hours
timeout 7200 journalctl -fu rebuilderd-worker@1 || true

# Stop monitor
kill $MONITOR_PID 2>/dev/null || true

# Stop worker
echo ""
echo "=== 2 hours elapsed, stopping worker ==="
sudo systemctl stop rebuilderd-worker@1

# Final storage check before cleanup
echo ""
echo "=== Storage before cleanup ==="
FINAL_BUILD_SIZE=$(du -sm "$BUILD_DIR" 2>/dev/null | cut -f1 || echo "0")
echo "Build dir: ${FINAL_BUILD_SIZE}MB"

# Show storage log
echo ""
echo "=== Storage log (every 10 min) ==="
cat "$LOG_FILE"

# Peak storage
PEAK_MB=$(tail -n +2 "$LOG_FILE" | cut -d',' -f2 | sort -n | tail -1)
echo ""
echo "=== Peak build dir usage: ${PEAK_MB}MB ==="

# Final counts
echo ""
echo "=== Final package status ==="
FINAL_GOOD=$(curl -s "$API/pkgs/list?status=GOOD" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
FINAL_BAD=$(curl -s "$API/pkgs/list?status=BAD" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

echo "GOOD: $FINAL_GOOD (+$((FINAL_GOOD - INITIAL_GOOD)))"
echo "BAD:  $FINAL_BAD (+$((FINAL_BAD - INITIAL_BAD)))"
echo ""

TOTAL_PROCESSED=$((FINAL_GOOD + FINAL_BAD - INITIAL_GOOD - INITIAL_BAD))
echo "=== SUMMARY ==="
echo "Packages processed: $TOTAL_PROCESSED"
echo "Rate: $((TOTAL_PROCESSED / 2)) packages/hour"
echo "Peak storage: ${PEAK_MB}MB"
echo "End time: $(date)"
