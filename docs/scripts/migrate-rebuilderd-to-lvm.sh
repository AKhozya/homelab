#!/bin/bash
# Migrate rebuilderd data to LVM storage
# Run with sudo on worker-node-2
set -e

echo "=== Rebuilderd Migration to LVM ==="
echo ""

echo "=== Current sizes ==="
du -sh /var/lib/rebuilderd-worker /var/lib/repro 2>/dev/null || true
echo ""

echo "=== Step 1: Stop rebuilderd services ==="
sudo systemctl stop rebuilderd-worker@1 2>/dev/null || true
sudo systemctl stop rebuilderd-sync.timer 2>/dev/null || true
sudo systemctl stop rebuilderd-stop.timer 2>/dev/null || true
sudo systemctl stop rebuilderd-start.timer 2>/dev/null || true
echo "Services stopped"
echo ""

echo "=== Step 2: Create LVM directories ==="
sudo mkdir -p /mnt/extra-storage/rebuilderd-worker
sudo mkdir -p /mnt/extra-storage/repro
echo "Directories created"
echo ""

echo "=== Step 3: Copy rebuilderd-worker (7.8G) ==="
if [ -d /var/lib/rebuilderd-worker ] && [ ! -L /var/lib/rebuilderd-worker ]; then
    sudo rsync -aHAX --info=progress2 /var/lib/rebuilderd-worker/ /mnt/extra-storage/rebuilderd-worker/
    echo "Copy complete"
else
    echo "Skipped - already migrated or doesn't exist"
fi
echo ""

echo "=== Step 4: Copy repro (5.9G) ==="
if [ -d /var/lib/repro ] && [ ! -L /var/lib/repro ]; then
    sudo rsync -aHAX --info=progress2 /var/lib/repro/ /mnt/extra-storage/repro/
    echo "Copy complete"
else
    echo "Skipped - already migrated or doesn't exist"
fi
echo ""

echo "=== Step 5: Replace with symlinks ==="
if [ -d /var/lib/rebuilderd-worker ] && [ ! -L /var/lib/rebuilderd-worker ]; then
    sudo rm -rf /var/lib/rebuilderd-worker
    sudo ln -s /mnt/extra-storage/rebuilderd-worker /var/lib/rebuilderd-worker
    echo "rebuilderd-worker -> LVM"
fi

if [ -d /var/lib/repro ] && [ ! -L /var/lib/repro ]; then
    sudo rm -rf /var/lib/repro
    sudo ln -s /mnt/extra-storage/repro /var/lib/repro
    echo "repro -> LVM"
fi
echo ""

echo "=== Step 6: Verify symlinks ==="
ls -la /var/lib/rebuilderd-worker /var/lib/repro
echo ""

echo "=== Step 7: Disk usage after migration ==="
df -h / /mnt/extra-storage
echo ""

echo "=== Migration Complete ==="
echo "Root SSD should now have ~14GB more free space"
