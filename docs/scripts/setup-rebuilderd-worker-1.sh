#!/bin/bash
# Setup rebuilderd on worker-node (192.168.1.129)
#
# Configuration:
#   - 4 workers (@1, @2, @3, @4)
#   - CPU: 300% per worker = 1200% total (12 cores of 32)
#   - RAM: 6GB per worker = 24GB total (of 64GB)
#   - Schedule: 2:00 AM - 9:00 AM daily
#
# Run as root: sudo bash setup-rebuilderd-worker-1.sh
#
# Rebuilderd verifies Arch Linux package reproducibility by rebuilding
# packages and comparing with official binaries.

set -e

echo "=== Setting up rebuilderd on worker-node ==="

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo bash $0"
    exit 1
fi

# Install rebuilderd if not present
if ! command -v rebuilderd-worker &> /dev/null; then
    echo "Installing rebuilderd..."
    pacman -S --noconfirm rebuilderd
fi

# Create systemd override directory
mkdir -p /etc/systemd/system/rebuilderd-worker@.service.d

# Configure resource limits per worker
# These limits apply to EACH worker instance independently
cat > /etc/systemd/system/rebuilderd-worker@.service.d/resources.conf << 'EOF'
[Service]
# CPU: 300% per worker (3 cores each)
# 4 workers x 300% = 1200% total (12 of 32 cores)
CPUQuota=300%

# RAM: 6GB per worker (hard limit)
# 4 workers x 6GB = 24GB total (of 64GB available)
MemoryMax=6G
MemoryHigh=5G

# IO: Low priority to not interfere with k8s workloads
# IOSchedulingClass is per-process (not cgroup)
IOSchedulingClass=best-effort
IOSchedulingPriority=7
# IOWeight is cgroup-level (1-10000, default 100)
# Lower = less IO bandwidth when competing with other cgroups
IOWeight=50

# Nice: Run with lower priority
Nice=10

# Timeout: Allow long builds (2h) to complete gracefully
TimeoutStopSec=7200
KillMode=mixed

# Environment for archlinux-repro CPU limit patch
# This passes the limit to nspawn containers
Environment=MAX_CPU=300%
EOF

echo "Created resource limits (300% CPU, 6GB RAM per worker)"

# Create timer for scheduled operation (2am start)
cat > /etc/systemd/system/rebuilderd-worker-scheduled.timer << 'EOF'
[Unit]
Description=Start rebuilderd workers at 2am

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/rebuilderd-worker-scheduled.service << 'EOF'
[Unit]
Description=Start rebuilderd workers for scheduled build window

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl start rebuilderd-worker@1 rebuilderd-worker@2 rebuilderd-worker@3 rebuilderd-worker@4
EOF

# Create stop timer (9am)
cat > /etc/systemd/system/rebuilderd-worker-stop.timer << 'EOF'
[Unit]
Description=Stop rebuilderd workers at 9am

[Timer]
OnCalendar=*-*-* 09:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/rebuilderd-worker-stop.service << 'EOF'
[Unit]
Description=Stop rebuilderd workers after build window

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl stop rebuilderd-worker@1 rebuilderd-worker@2 rebuilderd-worker@3 rebuilderd-worker@4
EOF

echo "Created scheduled timers (2am-9am)"

# Reload systemd
systemctl daemon-reload

# Enable and start timers
systemctl enable --now rebuilderd-worker-scheduled.timer
systemctl enable --now rebuilderd-worker-stop.timer

# If workers are currently running, restart them to apply new limits
if systemctl is-active --quiet rebuilderd-worker@1; then
    echo "Restarting active workers to apply new limits..."
    systemctl restart rebuilderd-worker@1 rebuilderd-worker@2 rebuilderd-worker@3 rebuilderd-worker@4
fi

echo ""
echo "=== Configuration Summary ==="
echo "Node: worker-node (192.168.1.129)"
echo "Workers: 4 (@1, @2, @3, @4)"
echo ""
echo "Per Worker:"
echo "  CPU: 300% (3 cores)"
echo "  RAM: 6GB (hard limit)"
echo ""
echo "Total:"
echo "  CPU: 1200% (12 cores of 32)"
echo "  RAM: 24GB (of 64GB available)"
echo ""
echo "Schedule: 2:00 AM - 9:00 AM daily (7 hours)"
echo ""
echo "=== Timer Status ==="
systemctl list-timers rebuilderd-worker* --no-pager

echo ""
echo "=== Manual Control ==="
echo "Start: sudo systemctl start rebuilderd-worker@{1..4}"
echo "Stop:  sudo systemctl stop rebuilderd-worker@{1..4}"
echo "Status: systemctl status rebuilderd-worker@{1..4}"
echo ""
echo "Done!"
