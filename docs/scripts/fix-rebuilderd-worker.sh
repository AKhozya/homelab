#!/bin/bash
# Fix rebuilderd-worker service references to use template instance
set -e

echo "=== Fixing start service ==="
sudo tee /etc/systemd/system/rebuilderd-worker-start.service > /dev/null << 'CONF'
[Unit]
Description=Start rebuilderd worker

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl start rebuilderd-worker@1
CONF

echo "=== Fixing stop service ==="
sudo tee /etc/systemd/system/rebuilderd-worker-stop.service > /dev/null << 'CONF'
[Unit]
Description=Stop rebuilderd worker gracefully

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl stop rebuilderd-worker@1
CONF

echo "=== Creating resource override for template ==="
sudo mkdir -p /etc/systemd/system/rebuilderd-worker@.service.d
# Detect which node we're on by hostname
if [ "$(hostname)" = "worker-node" ]; then
    echo "Detected worker-node (8 CPU, 16GB)"
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
    echo "Detected worker-node-2 (4 CPU, 8GB)"
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

echo "=== Reloading systemd ==="
sudo systemctl daemon-reload

echo "=== Testing worker start ==="
sudo systemctl start rebuilderd-worker@1
sleep 2
systemctl status rebuilderd-worker@1 --no-pager | head -10

echo ""
echo "=== Fix complete ==="
