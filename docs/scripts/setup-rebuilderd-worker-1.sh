#!/bin/bash
# Setup rebuilderd on worker-node (192.168.1.129)
#
# Configuration:
#   - 1 worker (@1)
#   - CPU: 600% (6 cores of 32)
#   - RAM: 32GB (increased from 24GB for heavy LTO builds like python-triton)
#   - Schedule: 24/7 (starts 10 min after boot)
#   - Build timeout: 48 hours
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

# Install firmware packages (suppresses mkinitcpio warnings)
echo "Installing firmware packages..."
pacman -S --noconfirm --needed amd-ucode linux-firmware linux-firmware-whence
sudo -u akhozya yay -S --noconfirm --needed aic94xx-firmware ast-firmware wd719x-firmware upd72020x-fw

# Create systemd override directory
mkdir -p /etc/systemd/system/rebuilderd-worker@.service.d

# Configure resource limits per worker
cat > /etc/systemd/system/rebuilderd-worker@.service.d/resources.conf << 'EOF'
[Service]
# Explicit config path (implicit -c is deprecated)
ExecStart=
ExecStart=/usr/bin/rebuilderd-worker -n %i -c /etc/rebuilderd-worker.conf connect

# CPU: 600% (6 cores)
CPUQuota=600%

# RAM: 32GB (hard limit)
# Increased from 24GB to allow heavy LTO builds (python-triton ~40GB,
# openvdb ~34GB) to complete. K8s actual usage is ~13.5GB of 61GB total,
# so 32GB leaves ~29GB headroom for pods. OOM kills at 24GB were contained
# in rebuilderd cgroup (no K8s impact) but caused build failures (2026-02-21).
MemoryMax=32G
MemoryHigh=31G
MemorySwapMax=16G

# IO: Low priority to not interfere with k8s workloads
IOWeight=50

# Nice: Run with lower priority
Nice=10

# Timeout: Allow long builds (2h) to complete gracefully
TimeoutStopSec=7200

# KillMode: Send SIGTERM to ALL processes (including nspawn children)
# 'mixed' immediately SIGKILLs children, leaving stale pacman locks
# 'control-group' gives nspawn time to clean up before SIGKILL
KillMode=control-group

# Environment for archlinux-repro patches
# These pass limits to nspawn containers
Environment="MAX_CPU=600%" "MAX_MEMORY=32G"

# Cleanup stale pacman locks from nspawn containers before starting
# Prevents "unable to lock database" after unclean shutdown
ExecStartPre=/bin/bash -c 'find /var/lib/repro/ /mnt/k8s-storage/repro/ -name "db.lck" -delete 2>/dev/null; true'
EOF

echo "Created resource limits (600% CPU, 32GB RAM)"

# Configure 48-hour build timeout in rebuilderd-worker.conf
CONFIG="/etc/rebuilderd-worker.conf"
if [ -f "$CONFIG" ]; then
    if grep -q "^timeout" "$CONFIG"; then
        sed -i 's/^timeout.*/timeout = 172800/' "$CONFIG"
    else
        echo "" >> "$CONFIG"
        echo "# Build timeout in seconds (48 hours for large packages like chromium)" >> "$CONFIG"
        echo "timeout = 172800" >> "$CONFIG"
    fi
    echo "Configured 48-hour build timeout"
fi

# Remove old scheduled timers (migrating from 09:00-23:00 to 24/7)
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
echo "Node: worker-node (192.168.1.129)"
echo "Workers: 1 (@1)"
echo ""
echo "Per Worker:"
echo "  CPU: 600% (6 cores)"
echo "  RAM: 32GB (hard limit, passed to nspawn)"
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
