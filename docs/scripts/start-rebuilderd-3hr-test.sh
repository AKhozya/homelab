#!/bin/bash
# Start rebuilderd worker for 3-hour test
# Run as: sudo bash start-rebuilderd-3hr-test.sh

set -e

echo "=== Starting rebuilderd worker for 3-hour test ==="
echo "Current limits:"
grep -E "CPUQuota|MemoryMax" /etc/systemd/system/rebuilderd-worker@.service.d/resources.conf

echo ""
echo "Starting worker..."
systemctl start rebuilderd-worker@1

echo ""
echo "Worker started at $(date)"
echo "Will run for 3 hours - stop manually with: sudo systemctl stop rebuilderd-worker@1"
echo ""
systemctl status rebuilderd-worker@1 --no-pager | head -10
