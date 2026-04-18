#!/usr/bin/env bash
# install-worker.sh — per-worker bootstrap (idempotent).
# Run as root on each worker (worker-node, worker-node-2).
# install.sh on CP substitutes PUB_KEY placeholder before scp.
#
# Scope (bootstrap-critical only — drift-prone config migrated to ansible node-config.yml):
#   - logrotate pkg install (precondition)
#   - node-maintenance user + SSH authorized_keys
#   - sudoers bootstrap (ansible owns going forward; first-run needs it to connect)
#   - security-scan script + systemd units (Phase B will migrate to ansible)
#
# Removed — now ansible-managed (node-config.yml, run from CP):
#   - /etc/logrotate.d/pacman + /etc/logrotate.d/security-tools
#   - /etc/systemd/journald.conf.d/99-caps.conf
#   - /etc/systemd/system/rebuilderd-worker@.service.d/override.conf
#   - logrotate.timer enable
#   - systemd-journald restart
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

# ── sudoers bootstrap ──
# Required for first ansible SSH connection (node-maintenance → sudo).
# Ansible node-config playbook owns this file going forward.
# shellcheck disable=SC2016
cat > /etc/sudoers.d/node-maintenance <<'EOF'
node-maintenance ALL=(ALL) NOPASSWD: ALL
EOF
chmod 0440 /etc/sudoers.d/node-maintenance
visudo -c -f /etc/sudoers.d/node-maintenance

# ── monthly security scan (lynis + rkhunter) ──
# NOTE: script content duplicates bin/security-scan.sh (canonical source on CP).
# To update workers after changes: re-run install-worker.sh on each worker.
# Phase B of node-config migration will move this under ansible too.
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

systemctl daemon-reload
systemctl enable --now node-maintenance-security-scan.timer

echo "Worker bootstrap complete on ${HOSTNAME:-$(cat /etc/hostname 2>/dev/null || echo unknown)}."
echo "Note: logrotate, journald caps, rebuilderd-worker override now deployed via ansible from CP."
