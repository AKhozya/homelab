#!/usr/bin/env bash
# install-worker.sh — idempotent per-worker bootstrap.
# Run as root on each worker (worker-node, worker-node-2).
# install.sh on CP substitutes PUB_KEY placeholder before scp to worker.
set -euo pipefail

PUB_KEY="__REPLACE_WITH_ACTUAL_PUBKEY__"
case "$PUB_KEY" in
  ssh-ed25519\ *|ssh-rsa\ *|ecdsa-*\ *) ;;
  *) echo "PUB_KEY not substituted or invalid format" >&2; exit 1 ;;
esac
[ "$(id -u)" = "0" ] || { echo "Run as root" >&2; exit 1; }

# ── node-maintenance user ──
# Shell = /bin/bash required for SSH command execution (ansible).
# Security: SSH key auth + sudoers; no password set.
if id node-maintenance >/dev/null 2>&1; then
  usermod -s /bin/bash node-maintenance
else
  useradd -r -s /bin/bash -m -d /var/lib/node-maintenance node-maintenance
fi

install -d -m 0700 -o node-maintenance -g node-maintenance /var/lib/node-maintenance/.ssh

AK=/var/lib/node-maintenance/.ssh/authorized_keys
touch "$AK"
grep -qxF "$PUB_KEY" "$AK" || echo "$PUB_KEY" >> "$AK"
chown node-maintenance:node-maintenance "$AK"
chmod 0600 "$AK"

# ── sudoers ──
# Ansible's `become: true` invokes `sudo -H -n -u root /bin/sh -c ...`
# for ALL tasks. Restricting to specific binaries breaks ansible_builtin
# modules (systemd_service, reboot, etc.). Broad NOPASSWD is the standard
# ansible-managed-host pattern — trust surface = SSH key + user account.
# shellcheck disable=SC2016
cat > /etc/sudoers.d/node-maintenance <<'EOF'
node-maintenance ALL=(ALL) NOPASSWD: ALL
EOF
chmod 0440 /etc/sudoers.d/node-maintenance
visudo -c -f /etc/sudoers.d/node-maintenance

# ── rebuilderd-worker systemd override (60s stop) ──
install -d -m 0755 /etc/systemd/system/rebuilderd-worker@.service.d
cat > /etc/systemd/system/rebuilderd-worker@.service.d/override.conf <<'EOF'
[Service]
TimeoutStopSec=60s
EOF

# ── logrotate: pacman log (Arch default has none) ──
cat > /etc/logrotate.d/pacman <<'EOF'
/var/log/pacman.log {
    monthly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
EOF
chmod 0644 /etc/logrotate.d/pacman

# ── journald caps (500M max, 30d retention) ──
install -d -m 0755 /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/00-caps.conf <<'EOF'
[Journal]
SystemMaxUse=500M
SystemKeepFree=2G
MaxRetentionSec=30d
MaxFileSec=1week
Compress=yes
EOF
chmod 0644 /etc/systemd/journald.conf.d/00-caps.conf

systemctl daemon-reload
systemctl restart systemd-journald.service
systemctl enable --now logrotate.timer

echo "Worker bootstrap complete on ${HOSTNAME:-$(cat /etc/hostname 2>/dev/null || echo unknown)}."
