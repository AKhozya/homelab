#!/bin/bash
# Fix rebuilderd auth cookie and config issues
set -e

echo "=== Fixing sync config (architecture -> architectures) ==="
sudo sed -i 's/^architecture = /architectures = ["/; s/architectures = \["\([^"]*\)"/architectures = ["\1"]/' /etc/rebuilderd-sync.conf

echo "=== Checking cookie location ==="
COOKIE_PATH="/var/lib/rebuilderd/.cookie"
if [ -f "$COOKIE_PATH" ]; then
    echo "Cookie exists at $COOKIE_PATH"
    ls -la "$COOKIE_PATH"
else
    echo "Cookie not found - restarting rebuilderd to generate it"
    sudo systemctl restart rebuilderd
    sleep 2
fi

echo "=== Making cookie readable for sync services ==="
# The sync service runs as root via systemd, so it should work
# But let's ensure the cookie exists and is readable
sudo ls -la /var/lib/rebuilderd/

echo "=== Creating override for sync services to run as rebuilderd user ==="
sudo mkdir -p /etc/systemd/system/rebuilderd-sync@.service.d
sudo tee /etc/systemd/system/rebuilderd-sync@.service.d/user.conf > /dev/null << 'CONF'
[Service]
# Run as rebuilderd user to access auth cookie
User=rebuilderd
Group=rebuilderd
CONF

echo "=== Reloading systemd ==="
sudo systemctl daemon-reload

echo "=== Restarting rebuilderd and triggering sync ==="
sudo systemctl restart rebuilderd
sleep 2

echo "=== Manually triggering sync ==="
sudo systemctl start rebuilderd-sync@archlinux-core.service || true
sleep 3

echo "=== Checking sync result ==="
journalctl -u rebuilderd-sync@archlinux-core.service --since "1 minute ago" --no-pager | tail -10

echo ""
echo "=== Done ==="
