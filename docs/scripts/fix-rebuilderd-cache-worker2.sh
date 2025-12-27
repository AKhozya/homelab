#!/bin/bash
# Fix rebuilderd cache issues on worker-node-2
# Run as: sudo bash fix-rebuilderd-cache-worker2.sh

set -e

echo "=== Cleaning pacman cache in repro containers ==="
# Remove stale package caches that might have corrupted signatures
find /var/lib/repro -name "*.pkg.tar.zst" -delete 2>/dev/null || true
find /mnt/extra-storage/repro -name "*.pkg.tar.zst" -delete 2>/dev/null || true

echo "=== Updating pacman keyring ==="
pacman-key --refresh-keys 2>/dev/null || true
pacman-key --populate archlinux

echo "=== Clearing archlinux-repro cache ==="
rm -rf /var/cache/archlinux-repro/* 2>/dev/null || true

echo "=== Done ==="
echo "Restart rebuilderd-worker@1 to apply changes"
