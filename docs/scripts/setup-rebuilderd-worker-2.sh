#!/bin/bash
# Setup rebuilderd on worker-node-2 (192.168.1.126)
#
# Configuration:
#   - 1 worker (@1)
#   - CPU: 400% (4 cores of 16)
#   - RAM: 14GB (reduced from 18GB after DPDK OOM killed K8s pods)
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

# Install firmware packages (suppresses mkinitcpio warnings)
echo "Installing firmware packages..."
pacman -S --noconfirm --needed amd-ucode linux-firmware linux-firmware-whence
sudo -u z3us yay -S --noconfirm --needed aic94xx-firmware ast-firmware wd719x-firmware upd72020x-fw

# Create systemd override directory
mkdir -p /etc/systemd/system/rebuilderd-worker@.service.d

# Configure resource limits per worker
cat > /etc/systemd/system/rebuilderd-worker@.service.d/resources.conf << 'EOF'
[Service]
# Explicit config path (implicit -c is deprecated)
ExecStart=
ExecStart=/usr/bin/rebuilderd-worker -n %i -c /etc/rebuilderd-worker.conf connect

# CPU: 400% (4 cores)
CPUQuota=400%

# RAM: 14GB (hard limit)
# Reduced from 18GB after DPDK LTO build (lto1-ltrans) exceeded 18GB,
# triggered OOM killer, and killed MySQL pods on the same node (2026-02-21).
# 14GB leaves ~16GB for K8s pods; large builds fail inside cgroup instead
# of pressuring the whole system.
MemoryMax=14G
MemoryHigh=13G
MemorySwapMax=8G

# IO: Low priority to not interfere with k8s workloads
IOWeight=50

# Nice: Run with lower priority
Nice=10

# Timeout: Allow long builds (2h) to complete gracefully on stop
TimeoutStopSec=7200

# KillMode: Send SIGTERM to ALL processes (including nspawn children)
# 'mixed' immediately SIGKILLs children, leaving stale pacman locks
# 'control-group' gives nspawn time to clean up before SIGKILL
KillMode=control-group

# Environment for archlinux-repro patches
# These pass limits to nspawn containers
Environment="MAX_CPU=400%" "MAX_MEMORY=14G"

# Cleanup stale pacman locks from nspawn containers before starting
# Prevents "unable to lock database" after unclean shutdown
ExecStartPre=/bin/bash -c 'find /var/lib/repro/ /mnt/extra-storage/repro/ -name "db.lck" -delete 2>/dev/null; true'
EOF

echo "Created resource limits (400% CPU, 14GB RAM)"

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
echo "  RAM: 14GB (hard limit, passed to nspawn)"
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
