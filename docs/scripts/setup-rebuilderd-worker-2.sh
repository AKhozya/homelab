#!/bin/bash
# Setup rebuilderd on worker-node-2 (192.168.1.126)
#
# Configuration:
#   - 1 worker (@1)
#   - CPU: 400% (4 cores of 16)
#   - RAM: 24GB
#   - Schedule: 24/7 (starts 10 min after boot)
#   - Build timeout: 48 hours
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
cat > /etc/systemd/system/rebuilderd-worker@.service.d/resources.conf << 'EOF'
[Service]
# CPU: 400% (4 cores)
CPUQuota=400%

# RAM: 24GB (hard limit)
MemoryMax=24G
MemoryHigh=23G

# IO: Low priority to not interfere with k8s workloads
IOWeight=50

# Nice: Run with lower priority
Nice=10

# Timeout: Allow long builds (2h) to complete gracefully on stop
TimeoutStopSec=7200
KillMode=mixed

# Environment for archlinux-repro patches
# These pass limits to nspawn containers
Environment="MAX_CPU=400%" "MAX_MEMORY=24G"
EOF

echo "Created resource limits (400% CPU, 24GB RAM)"

# Configure 48-hour build timeout in rebuilderd-worker.conf
CONFIG="/etc/rebuilderd-worker.conf"
if [ -f "$CONFIG" ]; then
    if grep -q "^timeout" "$CONFIG"; then
        sed -i 's/^timeout.*/timeout = 172800/' "$CONFIG"
    else
        echo "" >> "$CONFIG"
        echo "# Build timeout in seconds (48 hours for large packages like python-aotriton)" >> "$CONFIG"
        echo "timeout = 172800" >> "$CONFIG"
    fi
    echo "Configured 48-hour build timeout"
fi

# Remove old scheduled timers
systemctl disable --now rebuilderd-worker-start.timer 2>/dev/null || true
systemctl disable --now rebuilderd-worker-stop.timer 2>/dev/null || true
rm -f /etc/systemd/system/rebuilderd-worker-start.timer
rm -f /etc/systemd/system/rebuilderd-worker-start.service
rm -f /etc/systemd/system/rebuilderd-worker-stop.timer
rm -f /etc/systemd/system/rebuilderd-worker-stop.service

echo "Removed old scheduled timers"

# Create boot timer (starts 10 minutes after boot)
cat > /etc/systemd/system/rebuilderd-worker-boot.timer << 'EOF'
[Unit]
Description=Start rebuilderd worker 10 minutes after boot

[Timer]
OnBootSec=10min
Unit=rebuilderd-worker@1.service

[Install]
WantedBy=timers.target
EOF

echo "Created boot timer (10 min delay after reboot)"

# Reload systemd
systemctl daemon-reload

# Enable boot timer for automatic start after reboot
systemctl enable rebuilderd-worker-boot.timer

# Start worker now (don't wait for timer on first setup)
systemctl start rebuilderd-worker@1

echo ""
echo "=== Configuration Summary ==="
echo "Node: worker-node-2 (192.168.1.126)"
echo "Workers: 1 (@1)"
echo ""
echo "Per Worker:"
echo "  CPU: 400% (4 cores)"
echo "  RAM: 24GB (hard limit, passed to nspawn)"
echo "  Build timeout: 48 hours"
echo ""
echo "Schedule: 24/7 (starts 10 min after boot)"
echo ""
echo "=== Worker Status ==="
systemctl status rebuilderd-worker@1 --no-pager 2>/dev/null | head -10 || echo "Worker starting..."

echo ""
echo "=== Manual Control ==="
echo "Start:   sudo systemctl start rebuilderd-worker@1"
echo "Stop:    sudo systemctl stop rebuilderd-worker@1"
echo "Restart: sudo systemctl restart rebuilderd-worker@1"
echo "Status:  systemctl status rebuilderd-worker@1"
echo "Logs:    journalctl -u rebuilderd-worker@1 -f"
echo ""
echo "Done!"
