#!/usr/bin/env bash
# install-worker.sh — per-worker bootstrap (idempotent).
# Run as root on each worker (worker-node, worker-node-2).
# install.sh on CP substitutes PUB_KEY placeholder before scp.
#
# Scope (bootstrap-critical only — everything else moved to ansible node-config.yml):
#   - node-maintenance user + SSH authorized_keys (needs CP-provided pubkey substitution)
#   - sudoers bootstrap (ansible owns going forward; first-run needs it to connect)
#
# Non-bootstrap config (logrotate, journald, rebuilderd-worker override, security-scan
# script + service/timer, sudoers, user shell) is deployed by ansible from CP on first
# node-config.yml run against this worker.
set -euo pipefail

PUB_KEY="__REPLACE_WITH_ACTUAL_PUBKEY__"
case "$PUB_KEY" in
  ssh-ed25519\ *|ssh-rsa\ *|ecdsa-*\ *) ;;
  *) echo "PUB_KEY not substituted or invalid format" >&2; exit 1 ;;
esac
[ "$(id -u)" = "0" ] || { echo "Run as root" >&2; exit 1; }

# ── node-maintenance user ──
# (logrotate + all other pkgs installed by ansible base_config / packages roles
# on first CP → worker apply.)
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

# security-scan.sh + service + timer: owned by ansible roles/security_scan (deployed
# from CP after first node-config.yml run on this worker).
# Log dir /var/log/node-maintenance created by ansible role.

echo "Worker bootstrap complete on ${HOSTNAME:-$(cat /etc/hostname 2>/dev/null || echo unknown)}."
echo "Next: ansible node-config.yml will deploy security-scan + logrotate + journald + rebuilderd-worker override."
