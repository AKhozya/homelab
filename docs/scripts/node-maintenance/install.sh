#!/usr/bin/env bash
# install.sh — CP-side bootstrap. Idempotent.
# Run as root on gmk-k3s-control-plane.
#
# Modes:
#   (default)      full bootstrap: user, sudoers, SSH key, creds, ansible, systemd
#   --sync-only    re-sync ansible playbooks + systemd units + telegram helper.
#                  Skips user/sudoers/SSH-key/creds (preserves existing state).
#                  Use from sync-node-maintenance.sh wrapper after git pull.
set -euo pipefail

[ "$(id -u)" = "0" ] || { echo "Run as root" >&2; exit 1; }

SYNC_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --sync-only) SYNC_ONLY=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 1 ;;
  esac
done

REPO_DIR="$(dirname "$(realpath "$0")")"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
SSH_KEY_PATH="/var/lib/node-maintenance/.ssh/id_ed25519"

# ── Preconditions ──
# ansible / jq / rsync / logrotate / python-kubernetes bootstrapped by
# setup-node.sh (CP-only section). Re-check here as safety net — if anything
# missing, stop with actionable error instead of obscure failure mid-run.
for bin in ansible-playbook jq rsync logrotate kubectl flux; do
  command -v "$bin" >/dev/null 2>&1 \
    || { echo "$bin missing — run setup-node.sh first" >&2; exit 1; }
done
pacman -Q python-kubernetes >/dev/null 2>&1 \
  || { echo "python-kubernetes missing — run setup-node.sh first" >&2; exit 1; }
[ -r "$KUBECONFIG_PATH" ] || { echo "$KUBECONFIG_PATH not readable" >&2; exit 1; }

if [ "$SYNC_ONLY" -eq 0 ]; then
  # ── SSH key source (expect plain decrypted key from Mac) ──
  # Skip gracefully if key already installed (idempotent re-run without key).
  KEY_SRC="${NODE_MAINT_KEY_SRC:-/tmp/node-maintenance-ssh-key}"
  if [ ! -r "$SSH_KEY_PATH" ] && [ ! -r "$KEY_SRC" ]; then
    cat >&2 <<ERR
SSH private key not found at: $SSH_KEY_PATH (installed) or $KEY_SRC (staged)

First-time install — run ONCE on Mac before install.sh:

  sops --decrypt --extract '["stringData"]["ssh-private-key"]' \\
    docs/scripts/node-maintenance/secrets/ssh-key.sops.yaml \\
    | ssh -p 65300 akhozya@gmk-k3s-control-plane \\
        'cat > $KEY_SRC && chmod 600 $KEY_SRC'

Then re-run this script.
Override staging path via env: NODE_MAINT_KEY_SRC=/custom/path sudo bash install.sh
ERR
    exit 1
  fi

  # ── user + dirs ──
  # Shell = /bin/bash required for SSH command execution (ansible tasks).
  # Security: SSH key auth + sudoers; login via password disabled (no password set).
  if id node-maintenance >/dev/null 2>&1; then
    usermod -s /bin/bash node-maintenance
  else
    useradd -r -s /bin/bash -m -d /var/lib/node-maintenance node-maintenance
  fi

  # ── sudoers bootstrap ──
  # yay (run as node-maintenance) internally calls `sudo pacman` — needs NOPASSWD.
  # Ansible node-config playbook owns this file going forward; bootstrap write here
  # is only for the first-install window before ansible has run.
  cat > /etc/sudoers.d/node-maintenance <<'EOF'
node-maintenance ALL=(ALL) NOPASSWD: ALL
EOF
  chmod 0440 /etc/sudoers.d/node-maintenance
  visudo -c -f /etc/sudoers.d/node-maintenance
fi

# /etc/node-maintenance: 0755 so node-maintenance user can traverse
# (known_hosts file itself is public info; token/chat-id files are 0400 root-only)
install -d -m 0755 -o root             -g root            /etc/node-maintenance
install -d -m 0750 -o root             -g adm             /var/log/node-maintenance
install -d -m 0700 -o node-maintenance -g node-maintenance /var/lib/node-maintenance/.ssh

# ── ansible playbooks + collections ──
rsync -a --delete "$REPO_DIR/ansible/" /etc/node-maintenance/ansible/
chmod 0600 /etc/node-maintenance/ansible/inventory.yml
ansible-galaxy collection install -r /etc/node-maintenance/ansible/requirements.yml --force

if [ "$SYNC_ONLY" -eq 0 ]; then
  # ── SSH key (copy from pre-decrypted path, shred source) ──
  # Skip if already installed (idempotent).
  if [ ! -r "$SSH_KEY_PATH" ]; then
    install -m 0600 -o node-maintenance -g node-maintenance \
      "$KEY_SRC" "$SSH_KEY_PATH"
    shred -u "$KEY_SRC" 2>/dev/null || rm -f "$KEY_SRC"

    # Derive pub key from private (no separate storage)
    ssh-keygen -y -f "$SSH_KEY_PATH" > "${SSH_KEY_PATH}.pub"
    chown node-maintenance:node-maintenance "${SSH_KEY_PATH}.pub"
    chmod 0644 "${SSH_KEY_PATH}.pub"
  fi
fi

# ── known_hosts ──
install -m 0644 "$REPO_DIR/lib/known_hosts" /etc/node-maintenance/known_hosts

if [ "$SYNC_ONLY" -eq 0 ]; then
  # ── Telegram creds (reuse backup-replication/backup-telegram) ──
  kubectl --kubeconfig="$KUBECONFIG_PATH" get secret -n backup-replication backup-telegram \
    -o jsonpath='{.data.bot_token}' | base64 -d > /etc/node-maintenance/telegram-token
  chmod 0400 /etc/node-maintenance/telegram-token
  kubectl --kubeconfig="$KUBECONFIG_PATH" get secret -n backup-replication backup-telegram \
    -o jsonpath='{.data.chat_id}' | base64 -d > /etc/node-maintenance/telegram-chat-id
  chmod 0400 /etc/node-maintenance/telegram-chat-id
fi

# ── notify helper + sync helper + systemd units ──
install -m 0750 -o root -g root "$REPO_DIR/lib/telegram-notify.sh" /usr/local/sbin/telegram-notify.sh
install -m 0750 -o root -g root "$REPO_DIR/lib/sync-from-git.sh"   /usr/local/sbin/node-maintenance-sync-from-git.sh
install -m 0750 -o root -g root "$REPO_DIR/lib/node-config-notify.sh" /usr/local/sbin/node-maintenance-config-notify.sh
install -m 0644 "$REPO_DIR/systemd/node-maintenance.timer"                     /etc/systemd/system/
install -m 0644 "$REPO_DIR/systemd/node-maintenance-phase1.service"            /etc/systemd/system/
install -m 0644 "$REPO_DIR/systemd/node-maintenance-phase2.service"            /etc/systemd/system/
install -m 0644 "$REPO_DIR/systemd/node-maintenance-kubectl-proxy.service"     /etc/systemd/system/
install -m 0644 "$REPO_DIR/systemd/node-maintenance-sync.service"              /etc/systemd/system/
install -m 0644 "$REPO_DIR/systemd/node-maintenance-sync.timer"                /etc/systemd/system/
install -m 0644 "$REPO_DIR/systemd/node-maintenance-config.service"            /etc/systemd/system/
install -m 0644 "$REPO_DIR/systemd/node-maintenance-config.timer"              /etc/systemd/system/
# security-scan.sh + .service + .timer now owned by ansible roles/security_scan (all hosts).

# ── github known_hosts (for deploy-key-based git sync) ──
# Baked once; rotation = delete + re-run install.sh (ssh-keyscan re-fetches).
if [ ! -s /etc/node-maintenance/github_known_hosts ]; then
  ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null > /etc/node-maintenance/github_known_hosts
  chmod 0644 /etc/node-maintenance/github_known_hosts
fi

systemctl daemon-reload

# Enable node-config drift-heal timer (security-scan timer enabled by ansible security_scan role).
systemctl enable --now node-maintenance-config.timer

# ── run initial node-config drift-heal (ansible owns logrotate/journald/sudoers/user) ──
# Synchronous — fails install.sh if ansible fails, surfaces issue immediately.
if [ -x /usr/bin/ansible-playbook ] && [ -f /etc/node-maintenance/ansible/node-config.yml ]; then
  echo "==> Running initial node-config drift-heal"
  systemctl start --wait node-maintenance-config.service || {
    echo "ERROR: initial node-config run failed; see journalctl -u node-maintenance-config.service" >&2
    exit 1
  }
fi

if [ "$SYNC_ONLY" -eq 0 ]; then
  systemctl enable --now node-maintenance-kubectl-proxy.service
  systemctl enable --now node-maintenance.timer
  systemctl enable node-maintenance-phase2.service

  # Sync timer: only enable if deploy key present (first-install may precede key setup).
  if [ -r /root/.ssh/homelab-deploy ]; then
    systemctl enable --now node-maintenance-sync.timer
    echo "==> node-maintenance-sync.timer enabled (every 10min)"
  else
    echo "==> WARN: /root/.ssh/homelab-deploy missing — sync timer NOT enabled."
    echo "    Generate key: ssh-keygen -t ed25519 -f /root/.ssh/homelab-deploy -N '' -C 'homelab-deploy@\$(hostname)'"
    echo "    Add pubkey as GitHub deploy key (read-only), then: systemctl enable --now node-maintenance-sync.timer"
  fi

  # Verify kubectl proxy reachable
  for i in {1..10}; do
    curl -sf -m 2 http://127.0.0.1:8001/api > /dev/null && break
    [ "$i" = "10" ] && { echo "ERROR: kubectl proxy not reachable after 10s" >&2; exit 1; }
    sleep 1
  done
  echo "kubectl proxy ready on 127.0.0.1:8001"

  # ── generate worker install scripts with pubkey substituted ──
  PUB_KEY="$(cat "${SSH_KEY_PATH}.pub")"
  WORKER_SCRIPT_OUT="/tmp/install-worker-ready.sh"
  sed "s|__REPLACE_WITH_ACTUAL_PUBKEY__|${PUB_KEY}|" \
    "$REPO_DIR/install-worker.sh" > "$WORKER_SCRIPT_OUT"
  chmod +x "$WORKER_SCRIPT_OUT"

  cat <<EOF

╔═══════════════════════════════════════════════════════════════════╗
║  CP bootstrap complete.                                           ║
║  Next run: $(systemctl list-timers node-maintenance.timer --no-pager 2>/dev/null | awk 'NR==2{print $1,$2,$3}')
║                                                                   ║
║  Worker bootstrap (run from CP):                                  ║
║    scp -P 65300 $WORKER_SCRIPT_OUT akhozya@worker-node:/tmp/      ║
║    ssh -p 65300 akhozya@worker-node 'sudo bash /tmp/install-worker-ready.sh && rm /tmp/install-worker-ready.sh'
║                                                                   ║
║    scp -P 65300 $WORKER_SCRIPT_OUT z3us@worker-node-2:/tmp/       ║
║    ssh -p 65300 z3us@worker-node-2 'sudo bash /tmp/install-worker-ready.sh && rm /tmp/install-worker-ready.sh'
║                                                                   ║
║  After both workers bootstrapped, verify:                         ║
║    sudo -u node-maintenance ssh -p 65300 -i /var/lib/node-maintenance/.ssh/id_ed25519 -o UserKnownHostsFile=/etc/node-maintenance/known_hosts node-maintenance@192.168.1.129 true
║    sudo -u node-maintenance ssh -p 65300 -i /var/lib/node-maintenance/.ssh/id_ed25519 -o UserKnownHostsFile=/etc/node-maintenance/known_hosts node-maintenance@192.168.1.126 true
╚═══════════════════════════════════════════════════════════════════╝
EOF
else
  echo "Sync complete: ansible/, systemd units, telegram-notify.sh → /etc + daemon-reload"
fi
