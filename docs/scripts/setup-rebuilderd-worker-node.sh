#!/bin/bash
# Setup rebuilderd on worker-node (32 cores, 61GB RAM)
# Resources: 8 CPUs, 16GB RAM
# Schedule: 1am-8am daily
set -e

echo "=== Installing rebuilderd ==="
sudo pacman -S --needed --noconfirm rebuilderd archlinux-repro

echo "=== Importing Arch Linux GPG key ==="
gpg --auto-key-locate nodefault,wkd --locate-keys pierre@archlinux.de 2>/dev/null || true

echo "=== Creating build directory ==="
sudo mkdir -p /mnt/k8s-storage/rebuilderd/builds
sudo chown $USER:$USER /mnt/k8s-storage/rebuilderd

echo "=== Configuring rebuilderd.conf ==="
sudo tee /etc/rebuilderd.conf > /dev/null << 'CONF'
## rebuilderd configuration

[daemon]
socket = "/var/lib/rebuilderd/rebuilderd.sock"

[worker]
concurrency = 1
build_dir = "/mnt/k8s-storage/rebuilderd/builds"

[schedule]
retry_delay = "24h"
CONF

echo "=== Configuring sync profile ==="
sudo tee /etc/rebuilderd-sync.conf > /dev/null << 'CONF'
## Sync core and extra repos from Arch Linux

[profile.archlinux-core]
distro = "archlinux"
suite = "core"
architecture = "x86_64"
source = "https://geo.mirror.pkgbuild.com/core/os/x86_64/core.db"

[profile.archlinux-extra]
distro = "archlinux"
suite = "extra"
architecture = "x86_64"
source = "https://geo.mirror.pkgbuild.com/extra/os/x86_64/extra.db"
CONF

echo "=== Creating resource limits override ==="
sudo mkdir -p /etc/systemd/system/rebuilderd-worker.service.d
sudo tee /etc/systemd/system/rebuilderd-worker.service.d/resources.conf > /dev/null << 'CONF'
[Service]
# 8 CPUs (out of 32) - leaves plenty for K8s
CPUQuota=800%

# 16GB max memory - leaves 45GB for K8s
MemoryMax=16G
MemoryHigh=14G

# Low I/O priority - won't compete with databases
IOSchedulingClass=best-effort
IOSchedulingPriority=7
Nice=15

# Graceful stop - wait up to 2 hours for current build to finish
TimeoutStopSec=7200
KillMode=mixed

# Build directory on fast storage
Environment="BUILDDIR=/mnt/k8s-storage/rebuilderd/builds"
CONF

echo "=== Creating start timer (1am) ==="
sudo tee /etc/systemd/system/rebuilderd-worker-start.timer > /dev/null << 'CONF'
[Unit]
Description=Start rebuilderd worker at 1am

[Timer]
OnCalendar=*-*-* 01:00:00
Persistent=true

[Install]
WantedBy=timers.target
CONF

sudo tee /etc/systemd/system/rebuilderd-worker-start.service > /dev/null << 'CONF'
[Unit]
Description=Start rebuilderd worker

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl start rebuilderd-worker
CONF

echo "=== Creating stop timer (8am) ==="
sudo tee /etc/systemd/system/rebuilderd-worker-stop.timer > /dev/null << 'CONF'
[Unit]
Description=Stop rebuilderd worker at 8am

[Timer]
OnCalendar=*-*-* 08:00:00
Persistent=true

[Install]
WantedBy=timers.target
CONF

sudo tee /etc/systemd/system/rebuilderd-worker-stop.service > /dev/null << 'CONF'
[Unit]
Description=Stop rebuilderd worker gracefully

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl stop rebuilderd-worker
CONF

echo "=== Enabling services ==="
sudo systemctl daemon-reload
sudo systemctl enable rebuilderd
sudo systemctl enable rebuilderd-sync@archlinux-core.timer
sudo systemctl enable rebuilderd-sync@archlinux-extra.timer
sudo systemctl enable rebuilderd-worker-start.timer
sudo systemctl enable rebuilderd-worker-stop.timer

echo "=== Starting services ==="
sudo systemctl start rebuilderd
sudo systemctl start rebuilderd-sync@archlinux-core.timer
sudo systemctl start rebuilderd-sync@archlinux-extra.timer
sudo systemctl start rebuilderd-worker-start.timer
sudo systemctl start rebuilderd-worker-stop.timer

echo ""
echo "============================================"
echo "  worker-node rebuilderd setup complete!"
echo "============================================"
echo ""
echo "Schedule: Worker runs 1am-8am daily"
echo "Resources: 8 CPUs, 16GB RAM, low I/O priority"
echo "Graceful stop: Waits up to 2 hours for build"
echo ""
echo "Commands:"
echo "  Test now:     sudo systemctl start rebuilderd-worker"
echo "  Status:       systemctl status rebuilderd rebuilderd-worker"
echo "  View queue:   rebuildctl pkgs ls"
echo "  View timers:  systemctl list-timers 'rebuilderd*'"
echo ""
