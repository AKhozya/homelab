#!/usr/bin/env bash
# setup-rolling-update.sh — Deploy k3s-rolling-update to control-plane
#
# Run on control-plane: sudo bash setup-rolling-update.sh
# Run on workers: sudo bash setup-rolling-update.sh --worker
#
# This sets up:
#   - Control-plane: script, systemd timer/service/resume, sudoers, logrotate
#   - Workers: sudoers entries for rolling update commands

set -euo pipefail

NODE_TYPE="control-plane"
if [[ "${1:-}" == "--worker" ]]; then
    NODE_TYPE="worker"
fi

echo "=== K3s Rolling Update Setup (${NODE_TYPE}) ==="

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root: sudo bash setup-rolling-update.sh"
    exit 1
fi

# Detect the non-root user
if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_USER="${SUDO_USER}"
else
    echo "ERROR: Run with sudo (need SUDO_USER)"
    exit 1
fi

echo "  User: ${REAL_USER}"

# ========================== Worker Setup ==========================

if [[ "${NODE_TYPE}" == "worker" ]]; then
    echo ""
    echo "--- Setting up sudoers for rolling update ---"

    cat > /etc/sudoers.d/90-rolling-update <<EOF
# Allow rolling update script (from control-plane) to run specific commands
# without password. Scoped to exact commands needed.
${REAL_USER} ALL=(root) NOPASSWD: /usr/bin/pacman -Syu --noconfirm
${REAL_USER} ALL=(root) NOPASSWD: /sbin/reboot
EOF
    chmod 440 /etc/sudoers.d/90-rolling-update
    visudo -cf /etc/sudoers.d/90-rolling-update && echo "  Sudoers validated OK" || {
        echo "ERROR: Sudoers validation failed"
        rm -f /etc/sudoers.d/90-rolling-update
        exit 1
    }

    echo "  Worker setup complete"
    exit 0
fi

# ========================== Control-Plane Setup ==========================

echo ""
echo "--- Installing script ---"
SCRIPT_SRC="$(dirname "$0")/k3s-rolling-update.sh"
if [[ ! -f "${SCRIPT_SRC}" ]]; then
    echo "ERROR: ${SCRIPT_SRC} not found (run from docs/scripts/ directory)"
    exit 1
fi
cp "${SCRIPT_SRC}" /usr/local/bin/k3s-rolling-update.sh
chmod 755 /usr/local/bin/k3s-rolling-update.sh
echo "  Installed to /usr/local/bin/k3s-rolling-update.sh"

echo ""
echo "--- Creating state directory ---"
mkdir -p /var/lib/k3s-rolling-update
echo "  Created /var/lib/k3s-rolling-update/"

echo ""
echo "--- Setting up sudoers ---"
cat > /etc/sudoers.d/90-rolling-update <<EOF
# Control-plane: allow rolling update to run pacman and reboot
# The systemd service runs as root, but just in case
${REAL_USER} ALL=(root) NOPASSWD: /usr/bin/pacman -Syu --noconfirm
${REAL_USER} ALL=(root) NOPASSWD: /sbin/reboot
EOF
chmod 440 /etc/sudoers.d/90-rolling-update
visudo -cf /etc/sudoers.d/90-rolling-update && echo "  Sudoers validated OK" || {
    echo "ERROR: Sudoers validation failed"
    rm -f /etc/sudoers.d/90-rolling-update
    exit 1
}

echo ""
echo "--- Creating systemd units ---"

# Timer: Weekly Sunday 4:00 AM
cat > /etc/systemd/system/k3s-rolling-update.timer <<'EOF'
[Unit]
Description=Weekly K3s rolling OS update

[Timer]
OnCalendar=Sun *-*-* 04:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
echo "  Created k3s-rolling-update.timer"

# Main service
cat > /etc/systemd/system/k3s-rolling-update.service <<'EOF'
[Unit]
Description=K3s rolling OS update
After=network-online.target k3s.service
Wants=network-online.target
# Don't run if resume is pending (control-plane just rebooted)
ConditionPathExists=!/var/lib/k3s-rolling-update/state

[Service]
Type=oneshot
ExecStart=/usr/local/bin/k3s-rolling-update.sh
TimeoutStartSec=3600
Environment="KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
StandardOutput=append:/var/log/k3s-rolling-update.log
StandardError=append:/var/log/k3s-rolling-update.log
EOF
echo "  Created k3s-rolling-update.service"

# Resume service (after control-plane reboot)
cat > /etc/systemd/system/k3s-rolling-update-resume.service <<'EOF'
[Unit]
Description=Resume K3s rolling update after control-plane reboot
After=k3s.service network-online.target
Wants=network-online.target
ConditionPathExists=/var/lib/k3s-rolling-update/state

[Service]
Type=oneshot
ExecStart=/usr/local/bin/k3s-rolling-update.sh --resume
TimeoutStartSec=600
Environment="KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
StandardOutput=append:/var/log/k3s-rolling-update.log
StandardError=append:/var/log/k3s-rolling-update.log

[Install]
WantedBy=multi-user.target
EOF
echo "  Created k3s-rolling-update-resume.service"

echo ""
echo "--- Setting up logrotate ---"
cat > /etc/logrotate.d/k3s-rolling-update <<'EOF'
/var/log/k3s-rolling-update.log {
    monthly
    rotate 12
    compress
    missingok
    notifempty
}
EOF
echo "  Created logrotate config"

echo ""
echo "--- Enabling systemd units ---"
systemctl daemon-reload
systemctl enable k3s-rolling-update.timer
systemctl enable k3s-rolling-update-resume.service
systemctl start k3s-rolling-update.timer
echo "  Timer enabled and started"

echo ""
echo "--- Verifying ---"
systemctl list-timers k3s-rolling-update.timer --no-pager
echo ""

echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Run on worker-node:   sudo bash setup-rolling-update.sh --worker"
echo "  2. Run on worker-node-2: sudo bash setup-rolling-update.sh --worker"
echo "  3. Test dry-run:         sudo /usr/local/bin/k3s-rolling-update.sh --dry-run"
echo "  4. Check timer:          systemctl list-timers k3s-rolling-update*"
echo "  5. Manual run:           sudo systemctl start k3s-rolling-update.service"
echo "  6. View logs:            tail -f /var/log/k3s-rolling-update.log"
