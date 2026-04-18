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

# ── Preconditions ──
command -v logrotate >/dev/null 2>&1 || pacman -S --noconfirm logrotate

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
# Filename ordered after any pre-existing drop-in (e.g. size-limit.conf, 00-journal-size.conf)
# so this wins on conflicting keys (systemd reads drop-ins lexically, later overrides earlier).
cat > /etc/systemd/journald.conf.d/99-caps.conf <<'EOF'
[Journal]
SystemMaxUse=500M
SystemKeepFree=2G
MaxRetentionSec=30d
MaxFileSec=1week
Compress=yes
EOF
chmod 0644 /etc/systemd/journald.conf.d/99-caps.conf
rm -f /etc/systemd/journald.conf.d/00-caps.conf

# ── monthly security scan (lynis + rkhunter) ──
# NOTE: script content duplicates bin/security-scan.sh (canonical source on CP).
# To update workers after changes: re-run install-worker.sh on each worker.
install -d -m 0750 -o root -g adm /var/log/node-maintenance

cat > /usr/local/sbin/node-maintenance-security-scan.sh <<'SECSCAN_EOF'
#!/usr/bin/env bash
# security-scan.sh — Monthly lynis + rkhunter scan.
set -uo pipefail

LOG_DIR=/var/log/node-maintenance
install -d -m 0750 -o root -g adm "$LOG_DIR"

MONTH=$(date -u +%Y-%m)
SUMMARY="$LOG_DIR/security-scan-${MONTH}.log"
HOST=$(hostname)
START_TS=$(date -u +'%Y-%m-%d %H:%M:%S %Z')

RKHUNTER_TMP=$(mktemp -t rkhunter-scan.XXXXXX)
trap 'rm -f "$RKHUNTER_TMP"' EXIT

{
  echo "====================================================="
  echo "Host:      $HOST"
  echo "Started:   $START_TS"
  echo "Month tag: $MONTH"
  echo "====================================================="
  echo
  echo "── LYNIS ──"
  if command -v lynis >/dev/null 2>&1; then
    lynis audit system --quick --quiet --no-colors >/dev/null 2>&1 || true
    echo "# Version:"
    lynis --version 2>/dev/null | head -1 || true
    echo
    REPORT=/var/log/lynis-report.dat
    if [ -r "$REPORT" ]; then
      echo "# Hardening index:"
      grep -E '^hardening_index=' "$REPORT" | tail -1 || echo "(n/a)"
      echo
      echo "# Warnings:"
      WARN_COUNT=$(grep -cE '^warning\[\]=' "$REPORT" || true)
      echo "count=$WARN_COUNT"
      grep -E '^warning\[\]=' "$REPORT" || true
      echo
      echo "# Suggestions:"
      SUG_COUNT=$(grep -cE '^suggestion\[\]=' "$REPORT" || true)
      echo "count=$SUG_COUNT"
      grep -E '^suggestion\[\]=' "$REPORT" || true
    else
      echo "(lynis report $REPORT not found after scan)"
    fi
  else
    echo "lynis not installed — SKIP"
  fi
  echo
  echo "── RKHUNTER ──"
  if command -v rkhunter >/dev/null 2>&1; then
    echo "# Version:"
    rkhunter --version 2>/dev/null | head -1 || true
    echo
    rkhunter --update --quiet >/dev/null 2>&1 || true
    rkhunter --check --sk --rwo --nocolors 2>&1 | grep -v '^egrep: warning: egrep is obsolescent' >"$RKHUNTER_TMP" || true
    echo "# Warnings:"
    if [ -s "$RKHUNTER_TMP" ]; then
      cat "$RKHUNTER_TMP"
    else
      echo "(none — clean scan)"
    fi
    echo
    if [ -r /var/log/rkhunter.log ]; then
      echo "# Summary from /var/log/rkhunter.log:"
      grep -E 'Suspect files|Possible rootkits|Info:.*Warnings found|checks\.\.\..*clean' /var/log/rkhunter.log \
        | tail -10 || echo "(no summary lines)"
    fi
  else
    echo "rkhunter not installed — SKIP"
  fi
  echo
  echo "====================================================="
  echo "Finished:  $(date -u +'%Y-%m-%d %H:%M:%S %Z')"
  echo "====================================================="
} >>"$SUMMARY" 2>&1

chown root:adm "$SUMMARY" 2>/dev/null || true
chmod 0640 "$SUMMARY" 2>/dev/null || true
SECSCAN_EOF
chmod 0750 /usr/local/sbin/node-maintenance-security-scan.sh
chown root:root /usr/local/sbin/node-maintenance-security-scan.sh

cat > /etc/systemd/system/node-maintenance-security-scan.service <<'EOF'
[Unit]
Description=Node maintenance — monthly lynis + rkhunter security scan
ConditionPathExists=/usr/local/sbin/node-maintenance-security-scan.sh

[Service]
Type=oneshot
User=root
Nice=15
IOSchedulingClass=best-effort
IOSchedulingPriority=7
ExecStart=/usr/local/sbin/node-maintenance-security-scan.sh
TimeoutStartSec=45min
EOF
chmod 0644 /etc/systemd/system/node-maintenance-security-scan.service

cat > /etc/systemd/system/node-maintenance-security-scan.timer <<'EOF'
[Unit]
Description=Node maintenance — monthly security scan trigger

[Timer]
OnCalendar=*-*-01 04:00:00 UTC
Persistent=true
RandomizedDelaySec=3600
Unit=node-maintenance-security-scan.service

[Install]
WantedBy=timers.target
EOF
chmod 0644 /etc/systemd/system/node-maintenance-security-scan.timer

# ── logrotate: lynis/rkhunter + monthly summaries ──
cat > /etc/logrotate.d/security-tools <<'EOF'
/var/log/lynis.log /var/log/rkhunter.log {
    monthly
    rotate 6
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}

/var/log/node-maintenance/security-scan-*.log {
    monthly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
}
EOF
chmod 0644 /etc/logrotate.d/security-tools

systemctl daemon-reload
systemctl restart systemd-journald.service
systemctl enable --now logrotate.timer
systemctl enable --now node-maintenance-security-scan.timer

echo "Worker bootstrap complete on ${HOSTNAME:-$(cat /etc/hostname 2>/dev/null || echo unknown)}."
