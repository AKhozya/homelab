#!/bin/bash
# Migrate kubelet and rebuilderd data to LVM storage
# Run with sudo on worker-node (worker-node-1)
set -e

LVM_BASE="/mnt/k8s-storage"

echo "=== Worker-Node Migration to LVM ==="
echo "Target: $LVM_BASE"
echo ""

echo "=== Current sizes ==="
du -sh /var/lib/kubelet /var/lib/rebuilderd-worker /var/lib/repro 2>/dev/null || true
echo ""

echo "=== Step 1: Stop services ==="
sudo systemctl stop rebuilderd-worker@1 2>/dev/null || true
sudo systemctl stop rebuilderd-sync.timer 2>/dev/null || true
sudo systemctl stop rebuilderd-stop.timer 2>/dev/null || true
sudo systemctl stop rebuilderd-start.timer 2>/dev/null || true
sudo systemctl stop rebuilderd 2>/dev/null || true
sudo systemctl stop k3s 2>/dev/null || true
sleep 5
echo "Services stopped"
echo ""

echo "=== Step 2: Create LVM directories ==="
sudo mkdir -p "$LVM_BASE/kubelet"
sudo mkdir -p "$LVM_BASE/rebuilderd-worker"
sudo mkdir -p "$LVM_BASE/repro"
echo "Directories created"
echo ""

echo "=== Step 3: Migrate kubelet ==="
if [ -d /var/lib/kubelet ] && [ ! -L /var/lib/kubelet ]; then
    echo "Copying /var/lib/kubelet..."
    sudo rsync -aHAX --info=progress2 /var/lib/kubelet/ "$LVM_BASE/kubelet/"
    sudo mv /var/lib/kubelet /var/lib/kubelet.old
    sudo mkdir -p /var/lib/kubelet

    # Add bind mount to fstab if not already there
    if ! grep -q "$LVM_BASE/kubelet" /etc/fstab; then
        echo "$LVM_BASE/kubelet /var/lib/kubelet none bind 0 0" | sudo tee -a /etc/fstab
    fi
    sudo mount /var/lib/kubelet
    echo "kubelet migrated (bind mount)"
else
    echo "Skipped - already migrated or doesn't exist"
fi
echo ""

echo "=== Step 4: Migrate rebuilderd-worker ==="
if [ -d /var/lib/rebuilderd-worker ] && [ ! -L /var/lib/rebuilderd-worker ]; then
    echo "Copying /var/lib/rebuilderd-worker..."
    sudo rsync -aHAX --info=progress2 /var/lib/rebuilderd-worker/ "$LVM_BASE/rebuilderd-worker/"
    sudo rm -rf /var/lib/rebuilderd-worker
    sudo ln -s "$LVM_BASE/rebuilderd-worker" /var/lib/rebuilderd-worker
    echo "rebuilderd-worker migrated (symlink)"
else
    echo "Skipped - already migrated or doesn't exist"
fi
echo ""

echo "=== Step 5: Migrate repro ==="
if [ -d /var/lib/repro ] && [ ! -L /var/lib/repro ]; then
    echo "Copying /var/lib/repro..."
    sudo rsync -aHAX --info=progress2 /var/lib/repro/ "$LVM_BASE/repro/"
    sudo rm -rf /var/lib/repro
    sudo ln -s "$LVM_BASE/repro" /var/lib/repro
    echo "repro migrated (symlink)"
else
    echo "Skipped - already migrated or doesn't exist"
fi
echo ""

echo "=== Step 6: Start k3s ==="
sudo systemctl start k3s
sleep 10
if systemctl is-active --quiet k3s; then
    echo "k3s started successfully"
else
    echo "WARNING: k3s may have issues. Check: journalctl -u k3s -f"
fi
echo ""

echo "=== Step 7: Verify ==="
echo "Symlinks:"
ls -la /var/lib/rebuilderd-worker /var/lib/repro 2>/dev/null || true
echo ""
echo "Bind mount:"
mountpoint /var/lib/kubelet && echo "/var/lib/kubelet is mounted"
echo ""

echo "=== Step 8: Disk usage ==="
df -h / /mnt/k8s-storage
echo ""

echo "=== Migration Complete ==="
echo ""
echo "After verifying k3s is healthy, cleanup old kubelet data:"
echo "  sudo rm -rf /var/lib/kubelet.old"
