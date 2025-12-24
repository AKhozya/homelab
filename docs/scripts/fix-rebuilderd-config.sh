#!/bin/bash
set -e

echo "=== Writing correct sync config ==="
sudo tee /etc/rebuilderd-sync.conf > /dev/null << 'EOF'
[profile.archlinux-core]
distro = "archlinux"
suite = "core"
architectures = ["x86_64"]
source = "https://geo.mirror.pkgbuild.com/core/os/x86_64/core.db"

[profile.archlinux-extra]
distro = "archlinux"
suite = "extra"
architectures = ["x86_64"]
source = "https://geo.mirror.pkgbuild.com/extra/os/x86_64/extra.db"
EOF

echo "=== Triggering sync ==="
sudo systemctl start rebuilderd-sync@archlinux-core.service
sleep 3

echo "=== Result ==="
journalctl -u rebuilderd-sync@archlinux-core.service --since "1 minute ago" --no-pager | tail -10
