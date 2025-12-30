#!/bin/bash
# Setup rebuilderd on worker-node-2 (192.168.1.126)
#
# Configuration:
#   - 2 workers (@1, @2)
#   - CPU: 300% per worker = 600% total (6 cores of 16)
#   - RAM: 6GB per worker = 12GB total (of 30GB)
#   - Schedule: 24/7 (starts 10 min after boot)
#
# Run as root: sudo bash setup-rebuilderd-worker-2.sh
#
# Rebuilderd verifies Arch Linux package reproducibility by rebuilding
# packages and comparing with official binaries.

set -e

echo "=== Setting up rebuilderd on worker-node-2 ==="

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
# 2 workers x 300% = 600% total (6 of 16 cores)
CPUQuota=300%

# RAM: 6GB per worker (hard limit)
# 2 workers x 6GB = 12GB total (of 30GB available)
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

# Create boot delay service (starts workers 10 min after boot)
cat > /etc/systemd/system/rebuilderd-worker-boot.timer << 'EOF'
[Unit]
Description=Start rebuilderd workers 10 minutes after boot

[Timer]
OnBootSec=10min
Unit=rebuilderd-worker-boot.service

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/rebuilderd-worker-boot.service << 'EOF'
[Unit]
Description=Start rebuilderd workers after boot delay

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl start rebuilderd-worker@1 rebuilderd-worker@2
EOF

echo "Created boot timer (10 min delay)"

# Reload systemd
systemctl daemon-reload

# Enable boot timer (24/7 operation)
systemctl enable --now rebuilderd-worker-boot.timer

# If workers are currently running, restart them to apply new limits
if systemctl is-active --quiet rebuilderd-worker@1; then
    echo "Restarting active workers to apply new limits..."
    systemctl restart rebuilderd-worker@1 rebuilderd-worker@2
fi

echo ""
echo "=== Configuration Summary ==="
echo "Node: worker-node-2 (192.168.1.126)"
echo "Workers: 2 (@1, @2)"
echo ""
echo "Per Worker:"
echo "  CPU: 300% (3 cores)"
echo "  RAM: 6GB (hard limit)"
echo ""
echo "Total:"
echo "  CPU: 600% (6 cores of 16)"
echo "  RAM: 12GB (of 30GB available)"
echo ""
echo "Schedule: 24/7 (starts 10 min after boot)"
echo ""
echo "=== Timer Status ==="
systemctl list-timers rebuilderd-worker* --no-pager

echo ""
echo "=== Manual Control ==="
echo "Start: sudo systemctl start rebuilderd-worker@{1..2}"
echo "Stop:  sudo systemctl stop rebuilderd-worker@{1..2}"
echo "Status: systemctl status rebuilderd-worker@{1..2}"
echo ""
echo "Done!"
