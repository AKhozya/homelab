#!/bin/bash
# 2-hour rebuilderd worker - run on worker-node-2 with sudo
set -e

echo "=== Rebuilderd Worker-2 (2-Hour Test) ==="
echo "Start time: $(date)"
echo ""

echo "=== Starting worker ==="
sudo systemctl start rebuilderd-worker@1
echo "Worker started!"
echo ""

echo "=== Running for 2 hours ==="
echo "Will stop at: $(date -d '+2 hours')"
echo ""

# Show logs for 2 hours
timeout 7200 journalctl -fu rebuilderd-worker@1 || true

echo ""
echo "=== 2 hours elapsed, stopping worker ==="
sudo systemctl stop rebuilderd-worker@1
echo "Worker stopped at: $(date)"
