#!/bin/bash
# Fix database lock issue on worker-node-2
set -e

echo "=== Stopping worker ==="
sudo systemctl stop rebuilderd-worker@1 || true

echo "=== Removing stale lock files ==="
sudo find / -name 'db.lck' -delete 2>/dev/null || true

echo "=== Clearing nspawn container cache ==="
sudo rm -rf /var/lib/machines/repro-* 2>/dev/null || true
sudo rm -rf /var/lib/machines/archbuild-* 2>/dev/null || true

echo "=== Clearing pacman cache locks ==="
sudo rm -f /var/lib/pacman/db.lck 2>/dev/null || true

echo "=== Listing any remaining containers ==="
sudo ls -la /var/lib/machines/ 2>/dev/null || echo "No machines directory"

echo "=== Done - restart the 2hr test script ==="
