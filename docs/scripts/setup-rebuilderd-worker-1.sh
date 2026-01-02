#!/bin/bash
# Setup rebuilderd on worker-node (192.168.1.129)
#
# Configuration:
#   - 2 workers (@1, @2)
#   - CPU: 600% per worker = 1200% total (12 cores of 32)
#   - RAM: 12GB per worker = 24GB total (of 64GB)
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
# CPU: 600% per worker (6 cores each)
# 2 workers x 600% = 1200% total (12 of 32 cores)
CPUQuota=600%

# RAM: 12GB per worker (hard limit)
# 2 workers x 12GB = 24GB total (of 64GB available)
MemoryMax=12G
MemoryHigh=11G

# IO: Low priority to not interfere with k8s workloads
IOWeight=50

# Nice: Run with lower priority
Nice=10

# Timeout: Allow long builds (2h) to complete gracefully
TimeoutStopSec=7200
KillMode=mixed

# Environment for archlinux-repro patches
# These pass limits to nspawn containers
Environment="MAX_CPU=600%" "MAX_MEMORY=12G"
EOF

echo "Created resource limits (600% CPU, 12GB RAM per worker)"

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
ExecStart=/usr/bin/systemctl start rebuilderd-worker@1 rebuilderd-worker@2
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
ExecStart=/bin/bash -c "systemctl stop 'rebuilderd-worker@*'"
EOF

echo "Created scheduled timers (2am-9am)"

# Reload systemd
systemctl daemon-reload

# Enable and start timers
systemctl enable --now rebuilderd-worker-scheduled.timer
systemctl enable --now rebuilderd-worker-stop.timer

# Stop any currently running workers (config only, timers handle scheduling)
echo "Stopping any running workers..."
systemctl stop 'rebuilderd-worker@*' 2>/dev/null || true

echo ""
echo "=== Configuration Summary ==="
echo "Node: worker-node (192.168.1.129)"
echo "Workers: 2 (@1, @2)"
echo ""
echo "Per Worker:"
echo "  CPU: 600% (6 cores)"
echo "  RAM: 12GB (hard limit, passed to nspawn)"
echo ""
echo "Total:"
echo "  CPU: 1200% (12 cores of 32)"
echo "  RAM: 24GB (of 64GB available)"
echo ""
echo "Schedule: 2:00 AM - 9:00 AM daily (7 hours)"
echo "Workers will start automatically at 2am via timer."
echo ""
echo "=== Timer Status ==="
systemctl list-timers rebuilderd-worker* --no-pager

echo ""
echo "=== Manual Control ==="
echo "Start: sudo systemctl start rebuilderd-worker@{1..2}"
echo "Stop:  sudo systemctl stop 'rebuilderd-worker@*'"
echo "Status: systemctl status rebuilderd-worker@{1..2}"
echo ""
echo "Done!"
