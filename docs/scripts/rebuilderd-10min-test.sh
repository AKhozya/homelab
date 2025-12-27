#!/bin/bash
# Quick 10-minute rebuilderd test to verify LVM storage
# Run with sudo on worker-node or worker-node-2
set -e

HOSTNAME=$(cat /etc/hostname)

if [ "$HOSTNAME" = "worker-node" ]; then
    BUILD_DIR="/mnt/k8s-storage/rebuilderd-worker"
    STORAGE="/mnt/k8s-storage"
else
    BUILD_DIR="/mnt/extra-storage/rebuilderd-worker"
    STORAGE="/mnt/extra-storage"
fi

echo "=== Rebuilderd 10-Minute Test ==="
echo "Host: $HOSTNAME"
echo "Build dir: $BUILD_DIR"
echo "Start: $(date)"
echo ""

echo "=== Initial storage ==="
df -h "$STORAGE"
du -sh "$BUILD_DIR" 2>/dev/null || echo "Build dir empty"
echo ""

echo "=== Starting worker ==="
sudo systemctl start rebuilderd-worker@1
sleep 2

if ! systemctl is-active --quiet rebuilderd-worker@1; then
    echo "ERROR: Worker failed to start!"
    journalctl -u rebuilderd-worker@1 --no-pager -n 20
    exit 1
fi
echo "Worker started successfully"
echo ""

echo "=== Monitoring for 10 minutes (storage check every 2 min) ==="
for i in 1 2 3 4 5; do
    sleep 120
    TIMESTAMP=$(date '+%H:%M:%S')
    BUILD_SIZE=$(du -sh "$BUILD_DIR" 2>/dev/null | cut -f1 || echo "0")
    DISK_USED=$(df -h "$STORAGE" | tail -1 | awk '{print $3}')
    DISK_AVAIL=$(df -h "$STORAGE" | tail -1 | awk '{print $4}')

    # Check if any builds happening
    ACTIVE=$(ls "$BUILD_DIR"/*.* 2>/dev/null | wc -l || echo "0")

    echo "[$TIMESTAMP] Build dir: $BUILD_SIZE | Disk used: $DISK_USED | Active files: $ACTIVE"
done

echo ""
echo "=== Stopping worker ==="
sudo systemctl stop rebuilderd-worker@1
echo "Worker stopped"
echo ""

echo "=== Final storage ==="
df -h "$STORAGE"
du -sh "$BUILD_DIR" 2>/dev/null || echo "Build dir empty"
echo ""

echo "=== Recent worker logs ==="
journalctl -u rebuilderd-worker@1 --no-pager -n 30 --since "10 minutes ago"
echo ""

echo "=== Test Complete ==="
echo "End: $(date)"
echo ""
echo "Check above for:"
echo "  1. Build dir size increasing = using LVM storage ✓"
echo "  2. No errors in logs ✓"
echo "  3. Packages being processed ✓"
