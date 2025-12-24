#!/bin/bash
# Cleanup stale kubelet mounts and remove old directory
# Run with sudo
set -e

OLD_DIR="/var/lib/kubelet.old"

if [ ! -d "$OLD_DIR" ]; then
    echo "Nothing to clean - $OLD_DIR doesn't exist"
    exit 0
fi

echo "=== Finding stale mounts in $OLD_DIR ==="
MOUNTS=$(findmnt -rn -o TARGET | grep "$OLD_DIR" || true)

if [ -n "$MOUNTS" ]; then
    echo "Found stale mounts:"
    echo "$MOUNTS"
    echo ""
    echo "=== Lazy unmounting ==="
    for mount in $MOUNTS; do
        echo "Unmounting: $mount"
        sudo umount -l "$mount" 2>/dev/null || true
    done
else
    echo "No mounts found, trying direct removal"
fi

echo ""
echo "=== Removing $OLD_DIR ==="
sudo rm -rf "$OLD_DIR"

if [ -d "$OLD_DIR" ]; then
    echo "WARNING: Some files still remain"
    ls -la "$OLD_DIR"
else
    echo "Cleanup complete!"
fi
