#!/bin/bash
# Update rebuilderd settings on worker-node
# - RAM: 16GB -> 24GB
# - Start time: 1am -> 2am
set -e

echo "=== Updating resource limits (24GB RAM) ==="
sudo tee /etc/systemd/system/rebuilderd-worker@.service.d/resources.conf > /dev/null << 'CONF'
[Service]
CPUQuota=800%
MemoryMax=24G
MemoryHigh=22G
IOSchedulingClass=best-effort
IOSchedulingPriority=7
Nice=15
TimeoutStopSec=7200
KillMode=mixed
CONF

echo "=== Updating start timer (2am) ==="
sudo tee /etc/systemd/system/rebuilderd-worker-start.timer > /dev/null << 'CONF'
[Unit]
Description=Start rebuilderd worker at 2am

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
CONF

echo "=== Reloading systemd ==="
sudo systemctl daemon-reload

echo "=== Verifying ==="
echo "Resources:"
grep -E "(MemoryMax|CPUQuota)" /etc/systemd/system/rebuilderd-worker@.service.d/resources.conf
echo ""
echo "Timer:"
grep "OnCalendar" /etc/systemd/system/rebuilderd-worker-start.timer

echo ""
echo "=== Done (changes apply on next service start) ==="
