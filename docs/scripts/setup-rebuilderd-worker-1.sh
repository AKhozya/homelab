#!/bin/bash
# Setup rebuilderd on worker-node (192.168.1.129)
#
# Configuration:
#   - 1 worker (@1)
#   - CPU: 600% (6 cores of 32)
#   - RAM: 18GB
#   - Schedule: 24/7 (starts 10 min after boot)
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
cat > /etc/systemd/system/rebuilderd-worker@.service.d/resources.conf << 'EOF'
[Service]
# CPU: 600% (6 cores)
CPUQuota=600%

# RAM: 18GB (hard limit)
MemoryMax=18G
MemoryHigh=17G

# IO: Low priority to not interfere with k8s workloads
IOWeight=50

# Nice: Run with lower priority
Nice=10

# Timeout: Allow long builds (2h) to complete gracefully
TimeoutStopSec=7200
KillMode=mixed

# Environment for archlinux-repro patches
# These pass limits to nspawn containers
Environment="MAX_CPU=600%" "MAX_MEMORY=18G"
EOF

echo "Created resource limits (600% CPU, 18GB RAM)"

# Remove old scheduled timers if they exist
systemctl disable --now rebuilderd-worker-scheduled.timer 2>/dev/null || true
systemctl disable --now rebuilderd-worker-stop.timer 2>/dev/null || true
rm -f /etc/systemd/system/rebuilderd-worker-scheduled.timer
rm -f /etc/systemd/system/rebuilderd-worker-scheduled.service
rm -f /etc/systemd/system/rebuilderd-worker-stop.timer
rm -f /etc/systemd/system/rebuilderd-worker-stop.service

echo "Removed old scheduled timers"

# Create boot delay service (starts worker 10 min after boot)
cat > /etc/systemd/system/rebuilderd-worker-boot.timer << 'EOF'
[Unit]
Description=Start rebuilderd worker 10 minutes after boot

[Timer]
OnBootSec=10min
Unit=rebuilderd-worker-boot.service

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/rebuilderd-worker-boot.service << 'EOF'
[Unit]
Description=Start rebuilderd worker after boot delay

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl start rebuilderd-worker@1
EOF

echo "Created boot timer (10 min delay)"

# Reload systemd
systemctl daemon-reload

# Enable boot timer (24/7 operation)
systemctl enable --now rebuilderd-worker-boot.timer

# Stop old workers and start new config
echo "Stopping any running workers..."
systemctl stop 'rebuilderd-worker@*' 2>/dev/null || true

# Start the single worker
echo "Starting rebuilderd-worker@1..."
systemctl start rebuilderd-worker@1

echo ""
echo "=== Configuration Summary ==="
echo "Node: worker-node (192.168.1.129)"
echo "Workers: 1 (@1)"
echo ""
echo "Per Worker:"
echo "  CPU: 600% (6 cores)"
echo "  RAM: 18GB (hard limit, passed to nspawn)"
echo ""
echo "Schedule: 24/7 (starts 10 min after boot)"
echo ""
echo "=== Timer Status ==="
systemctl list-timers rebuilderd-worker* --no-pager

echo ""
echo "=== Worker Status ==="
systemctl status rebuilderd-worker@1 --no-pager | head -5

echo ""
echo "=== Manual Control ==="
echo "Start:  sudo systemctl start rebuilderd-worker@1"
echo "Stop:   sudo systemctl stop rebuilderd-worker@1"
echo "Status: systemctl status rebuilderd-worker@1"
echo ""
echo "Done!"
