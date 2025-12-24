#!/bin/bash
# Migrate /var/lib/kubelet to LVM storage on worker-node-2
# Run with sudo on worker-node-2
set -e

TARGET="/mnt/extra-storage/kubelet"
SOURCE="/var/lib/kubelet"

echo "=== Kubelet Migration to LVM ==="
echo "Source: $SOURCE ($(du -sh $SOURCE 2>/dev/null | cut -f1))"
echo "Target: $TARGET"
echo ""

# Check if already migrated
if mountpoint -q "$SOURCE" 2>/dev/null; then
    echo "ERROR: $SOURCE is already a mount point. Already migrated?"
    exit 1
fi

# Check if target exists
if [ -d "$TARGET" ] && [ "$(ls -A $TARGET 2>/dev/null)" ]; then
    echo "ERROR: $TARGET already exists and is not empty"
    exit 1
fi

echo "=== Step 1: Stop k3s-agent ==="
echo "Stopping k3s-agent service..."
sudo systemctl stop k3s-agent
sleep 5

# Verify stopped
if systemctl is-active --quiet k3s-agent; then
    echo "ERROR: k3s-agent still running"
    exit 1
fi
echo "k3s-agent stopped"
echo ""

echo "=== Step 2: Copy data to LVM ==="
sudo mkdir -p "$TARGET"
echo "Copying $SOURCE to $TARGET (this may take a few minutes)..."
sudo rsync -aHAXx --info=progress2 "$SOURCE/" "$TARGET/"
echo "Copy complete"
echo ""

echo "=== Step 3: Verify copy ==="
SOURCE_SIZE=$(sudo du -sb "$SOURCE" | cut -f1)
TARGET_SIZE=$(sudo du -sb "$TARGET" | cut -f1)
echo "Source size: $SOURCE_SIZE bytes"
echo "Target size: $TARGET_SIZE bytes"

if [ "$SOURCE_SIZE" != "$TARGET_SIZE" ]; then
    echo "WARNING: Size mismatch! Verify manually before continuing."
    echo "Press Ctrl+C to abort, or Enter to continue anyway..."
    read
fi
echo ""

echo "=== Step 4: Rename old directory ==="
sudo mv "$SOURCE" "${SOURCE}.old"
sudo mkdir -p "$SOURCE"
echo "Old data moved to ${SOURCE}.old"
echo ""

echo "=== Step 5: Add bind mount to fstab ==="
# Check if already in fstab
if grep -q "$TARGET" /etc/fstab; then
    echo "Bind mount already in fstab"
else
    echo "$TARGET $SOURCE none bind 0 0" | sudo tee -a /etc/fstab
    echo "Added to fstab"
fi
echo ""

echo "=== Step 6: Mount and verify ==="
sudo mount "$SOURCE"
if mountpoint -q "$SOURCE"; then
    echo "Mount successful"
else
    echo "ERROR: Mount failed!"
    exit 1
fi
echo ""

echo "=== Step 7: Start k3s-agent ==="
sudo systemctl start k3s-agent
sleep 10

if systemctl is-active --quiet k3s-agent; then
    echo "k3s-agent started successfully"
else
    echo "WARNING: k3s-agent may have issues. Check with: journalctl -u k3s-agent -f"
fi
echo ""

echo "=== Step 8: Cleanup old data ==="
echo "Old data is at ${SOURCE}.old"
echo "After verifying everything works, remove it with:"
echo "  sudo rm -rf ${SOURCE}.old"
echo ""

echo "=== Migration Complete ==="
df -h / /mnt/extra-storage
echo ""
echo "Root SSD should now have ~5GB more free space"
