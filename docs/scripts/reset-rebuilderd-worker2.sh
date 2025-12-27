#!/bin/bash
# Reset rebuilderd on worker-node-2 - clean start from scratch
# Run as: sudo bash reset-rebuilderd-worker2.sh

set -e

echo "=== Stopping rebuilderd services ==="
systemctl stop rebuilderd-worker@1 2>/dev/null || true
systemctl stop rebuilderd

echo "=== Cleaning repro build containers ==="
rm -rf /var/lib/repro/* 2>/dev/null || true
rm -rf /mnt/extra-storage/repro/* 2>/dev/null || true

echo "=== Cleaning archlinux-repro cache ==="
rm -rf /var/cache/archlinux-repro/* 2>/dev/null || true

echo "=== Resetting rebuilderd database ==="
rm -rf /var/lib/rebuilderd/* 2>/dev/null || true

echo "=== Refreshing pacman keyring ==="
pacman-key --init
pacman-key --populate archlinux
pacman-key --refresh-keys 2>/dev/null || echo "Key refresh failed (network?), continuing..."

echo "=== Recreating rebuilderd directories ==="
mkdir -p /var/lib/rebuilderd
mkdir -p /var/lib/repro
mkdir -p /mnt/extra-storage/repro
chown rebuilderd:rebuilderd /var/lib/rebuilderd

echo "=== Starting rebuilderd daemon ==="
systemctl start rebuilderd
sleep 2

echo "=== Triggering initial sync ==="
systemctl start rebuilderd-sync@archlinux-core.service
systemctl start rebuilderd-sync@archlinux-extra.service

echo ""
echo "=== Done! ==="
echo "Wait 1-2 minutes for sync to complete, then start worker:"
echo "  sudo systemctl start rebuilderd-worker@1"
echo ""
echo "Check status:"
echo "  rebuildctl pkgs ls | head -10"
echo "  rebuildctl queue ls | head -5"
