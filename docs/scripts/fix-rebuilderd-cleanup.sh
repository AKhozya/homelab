#!/bin/bash
# Add cleanup to stop service
set -e

# Detect build directory
if [ -d /mnt/k8s-storage/rebuilderd ]; then
    BUILD_DIR="/mnt/k8s-storage/rebuilderd/builds"
else
    BUILD_DIR="/mnt/extra-storage/rebuilderd/builds"
fi

echo "=== Updating stop service with cleanup ==="
sudo tee /etc/systemd/system/rebuilderd-worker-stop.service > /dev/null << CONF
[Unit]
Description=Stop rebuilderd worker gracefully and cleanup

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl stop rebuilderd-worker@1
ExecStartPost=/usr/bin/rm -rf ${BUILD_DIR}/*
CONF

echo "=== Reloading systemd ==="
sudo systemctl daemon-reload

echo "=== Done (cleanup will run on stop) ==="
echo "Build dir: $BUILD_DIR"
