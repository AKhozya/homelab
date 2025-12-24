#!/bin/bash
# Fix resource limits based on hostname
set -e

HOSTNAME=$(cat /etc/hostname)
echo "=== Detected hostname: $HOSTNAME ==="

sudo mkdir -p /etc/systemd/system/rebuilderd-worker@.service.d

if [ "$HOSTNAME" = "worker-node" ]; then
    echo "Setting worker-node resources (8 CPU, 16GB)"
    sudo tee /etc/systemd/system/rebuilderd-worker@.service.d/resources.conf > /dev/null << 'CONF'
[Service]
CPUQuota=800%
MemoryMax=16G
MemoryHigh=14G
IOSchedulingClass=best-effort
IOSchedulingPriority=7
Nice=15
TimeoutStopSec=7200
KillMode=mixed
CONF
else
    echo "Setting worker-node-2 resources (4 CPU, 8GB)"
    sudo tee /etc/systemd/system/rebuilderd-worker@.service.d/resources.conf > /dev/null << 'CONF'
[Service]
CPUQuota=400%
MemoryMax=8G
MemoryHigh=6G
IOSchedulingClass=best-effort
IOSchedulingPriority=7
Nice=15
TimeoutStopSec=7200
KillMode=mixed
CONF
fi

sudo systemctl daemon-reload
echo "=== Done ==="
