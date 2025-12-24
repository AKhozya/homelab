#!/bin/bash
# Update rebuilderd CPU limits
set -e

HOSTNAME=$(cat /etc/hostname)
echo "=== Detected hostname: $HOSTNAME ==="

sudo mkdir -p /etc/systemd/system/rebuilderd-worker@.service.d

if [ "$HOSTNAME" = "worker-node" ]; then
    echo "Setting worker-node resources (12 CPU, 24GB)"
    sudo tee /etc/systemd/system/rebuilderd-worker@.service.d/resources.conf > /dev/null << 'CONF'
[Service]
CPUQuota=1200%
MemoryMax=24G
MemoryHigh=22G
IOSchedulingClass=best-effort
IOSchedulingPriority=7
Nice=15
TimeoutStopSec=7200
KillMode=mixed
CONF
else
    echo "Setting worker-node-2 resources (6 CPU, 16GB)"
    sudo tee /etc/systemd/system/rebuilderd-worker@.service.d/resources.conf > /dev/null << 'CONF'
[Service]
CPUQuota=600%
MemoryMax=16G
MemoryHigh=14G
IOSchedulingClass=best-effort
IOSchedulingPriority=7
Nice=15
TimeoutStopSec=7200
KillMode=mixed
CONF
fi

sudo systemctl daemon-reload

echo "=== New limits ==="
grep -E "(CPUQuota|MemoryMax)" /etc/systemd/system/rebuilderd-worker@.service.d/resources.conf
echo "=== Done ==="
