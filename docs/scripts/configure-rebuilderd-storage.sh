#!/bin/bash
# Configure archlinux-repro to use LVM storage for builds
set -e

HOSTNAME=$(cat /etc/hostname)
echo "=== Configuring build storage for $HOSTNAME ==="

if [ "$HOSTNAME" = "worker-node" ]; then
    BUILD_ROOT="/mnt/k8s-storage/rebuilderd/archbuild"
    CACHE_DIR="/mnt/k8s-storage/rebuilderd/cache"
else
    BUILD_ROOT="/mnt/extra-storage/rebuilderd/archbuild"
    CACHE_DIR="/mnt/extra-storage/rebuilderd/cache"
fi

echo "Build root: $BUILD_ROOT"
echo "Cache dir: $CACHE_DIR"

# Create directories
sudo mkdir -p "$BUILD_ROOT" "$CACHE_DIR"
sudo chown -R rebuilderd:rebuilderd "$BUILD_ROOT" "$CACHE_DIR" 2>/dev/null || \
    sudo chown -R root:root "$BUILD_ROOT" "$CACHE_DIR"

# Configure archlinux-repro
echo "=== Creating /etc/archlinux-repro.conf ==="
sudo tee /etc/archlinux-repro.conf > /dev/null << EOF
# Use LVM storage instead of tmpfs
BUILDDIRECTORY="$BUILD_ROOT"
CACHEDIR="$CACHE_DIR"
EOF

cat /etc/archlinux-repro.conf

# Configure devtools/makepkg to use disk storage
echo ""
echo "=== Creating /etc/makepkg.conf.d/storage.conf ==="
sudo mkdir -p /etc/makepkg.conf.d
sudo tee /etc/makepkg.conf.d/storage.conf > /dev/null << EOF
# Use LVM storage for builds
BUILDDIR="$BUILD_ROOT/build"
SRCDEST="$CACHE_DIR/sources"
PKGDEST="$CACHE_DIR/packages"
EOF

cat /etc/makepkg.conf.d/storage.conf

echo ""
echo "=== Done ==="
echo "Builds will now use: $BUILD_ROOT"
echo "This is disk-backed LVM storage (not RAM tmpfs)"
