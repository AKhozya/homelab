#!/bin/bash
set -e

echo "=== Fixing source format ==="
sudo tee /etc/rebuilderd-sync.conf > /dev/null << 'EOF'
[profile.archlinux-core]
distro = "archlinux"
suite = "core"
architectures = ["x86_64"]
source = "https://geo.mirror.pkgbuild.com/$repo/os/$arch"

[profile.archlinux-extra]
distro = "archlinux"
suite = "extra"
architectures = ["x86_64"]
source = "https://geo.mirror.pkgbuild.com/$repo/os/$arch"
EOF

echo "=== Syncing both repos ==="
sudo systemctl start rebuilderd-sync@archlinux-core.service
sudo systemctl start rebuilderd-sync@archlinux-extra.service
sleep 5

echo "=== Checking results ==="
journalctl -u 'rebuilderd-sync@*' --since "1 minute ago" --no-pager | grep -E "(INFO|WARN|ERROR)" | tail -10

echo "=== Package count ==="
curl -s "http://127.0.0.1:8484/api/v0/pkgs/list?distro=archlinux" | python3 -c "import sys,json; print(f'Total: {len(json.load(sys.stdin))} packages')"
