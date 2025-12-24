#!/bin/bash
# Test rebuilderd by building 1 package then stopping
set -e

echo "=== Starting rebuilderd-worker@1 ==="
sudo systemctl start rebuilderd-worker@1

echo "=== Waiting for build to start (max 60s) ==="
for i in {1..12}; do
    sleep 5
    echo "--- Check $i/12 ---"
    journalctl -u rebuilderd-worker@1 --since "1 minute ago" --no-pager | tail -5

    # Check if a build started
    if journalctl -u rebuilderd-worker@1 --since "1 minute ago" --no-pager | grep -q "Building\|Downloading\|Spawning"; then
        echo ""
        echo "=== Build started! Waiting 30s for progress ==="
        sleep 30
        break
    fi
done

echo ""
echo "=== Recent worker logs ==="
journalctl -u rebuilderd-worker@1 --since "2 minutes ago" --no-pager | tail -30

echo ""
echo "=== Stopping worker ==="
sudo systemctl stop rebuilderd-worker@1

echo ""
echo "=== Test complete ==="
