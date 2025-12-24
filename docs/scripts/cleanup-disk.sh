#!/bin/bash
# Cleanup disk space on Arch Linux K3s nodes
set -e

HOSTNAME=$(cat /etc/hostname)
echo "=== Disk Cleanup: $HOSTNAME ==="
echo ""

echo "=== Before cleanup ==="
df -h / /var 2>/dev/null | grep -v Filesystem
echo ""

# 1. Pacman cache - keep last 2 versions
echo "=== Cleaning pacman cache (keeping last 2 versions) ==="
sudo paccache -rk2
echo ""

# 2. Journal logs - keep 100MB
echo "=== Vacuuming journal logs to 100MB ==="
sudo journalctl --vacuum-size=100M
echo ""

# 3. Remove old swapfile if exists and LVM swap is active
if [ -f /swapfile ]; then
    # Check if LVM swap exists
    if swapon --show | grep -q "partition"; then
        echo "=== Removing old swapfile (LVM swap is active) ==="
        sudo swapoff /swapfile 2>/dev/null || true
        sudo rm -f /swapfile
        sudo sed -i '/swapfile/d' /etc/fstab
        echo "Swapfile removed"
    else
        echo "=== Keeping swapfile (no LVM swap detected) ==="
    fi
    echo ""
fi

# 4. Clean old container logs (pods)
echo "=== Cleaning old pod logs ==="
sudo find /var/log/pods -type f -name "*.log" -mtime +7 -delete 2>/dev/null || true
sudo find /var/log/containers -type f -name "*.log" -mtime +7 -delete 2>/dev/null || true
echo "Old pod logs cleaned"
echo ""

# 5. Clean orphaned container images (if crictl available)
if command -v crictl &> /dev/null; then
    echo "=== Pruning unused container images ==="
    sudo crictl rmi --prune 2>/dev/null || echo "No unused images to prune"
    echo ""
fi

echo "=== After cleanup ==="
df -h / /var 2>/dev/null | grep -v Filesystem
echo ""

echo "=== Cleanup complete ==="
