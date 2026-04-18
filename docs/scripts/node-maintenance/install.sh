#!/usr/bin/env bash
# install.sh — CP-side bootstrap. Idempotent.
# Run as root on gmk-k3s-control-plane.
set -euo pipefail

[ "$(id -u)" = "0" ] || { echo "Run as root" >&2; exit 1; }

REPO_DIR="$(dirname "$(realpath "$0")")"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

# ── Preconditions ──
command -v ansible-playbook >/dev/null 2>&1 || pacman -S --noconfirm ansible
command -v jq >/dev/null 2>&1 || pacman -S --noconfirm jq
command -v rsync >/dev/null 2>&1 || pacman -S --noconfirm rsync
# python-kubernetes required by kubernetes.core.k8s / k8s_info modules
pacman -Q python-kubernetes >/dev/null 2>&1 || pacman -S --noconfirm python-kubernetes
command -v kubectl >/dev/null 2>&1 || { echo "kubectl required" >&2; exit 1; }
command -v flux >/dev/null 2>&1 || { echo "flux required" >&2; exit 1; }
[ -r "$KUBECONFIG_PATH" ] || { echo "$KUBECONFIG_PATH not readable" >&2; exit 1; }

# ── SSH key source (expect plain decrypted key from Mac) ──
KEY_SRC="${NODE_MAINT_KEY_SRC:-/tmp/node-maintenance-ssh-key}"
[ -r "$KEY_SRC" ] || {
  cat >&2 <<ERR
SSH private key not found at: $KEY_SRC

Expected workflow — run ONCE on Mac before install.sh:

  sops --decrypt --extract '["stringData"]["ssh-private-key"]' \\
    docs/scripts/node-maintenance/secrets/ssh-key.sops.yaml \\
    | ssh -p 65300 akhozya@gmk-k3s-control-plane \\
        'cat > $KEY_SRC && chmod 600 $KEY_SRC'

Then re-run this script. install.sh will copy + chmod + shred the temp file.
Override path via env: NODE_MAINT_KEY_SRC=/custom/path sudo bash install.sh
ERR
  exit 1
}

# ── user + dirs ──
# Shell = /bin/bash required for SSH command execution (ansible tasks).
# Security: SSH key auth + sudoers; login via password disabled (no password set).
if id node-maintenance >/dev/null 2>&1; then
  usermod -s /bin/bash node-maintenance
else
  useradd -r -s /bin/bash -m -d /var/lib/node-maintenance node-maintenance
fi

# /etc/node-maintenance: 0755 so node-maintenance user can traverse
# (known_hosts file itself is public info; token/chat-id files are 0400 root-only)
install -d -m 0755 -o root             -g root            /etc/node-maintenance
install -d -m 0750 -o root             -g adm             /var/log/node-maintenance
install -d -m 0700 -o node-maintenance -g node-maintenance /var/lib/node-maintenance/.ssh

# ── sudoers ──
# yay (run as node-maintenance) internally calls `sudo pacman` — needs NOPASSWD.
# Same pattern as workers (install-worker.sh). Trust surface = user account
# (SSH login disabled: no password set, /etc/ssh/sshd_config omits node-maintenance).
cat > /etc/sudoers.d/node-maintenance <<'EOF'
node-maintenance ALL=(ALL) NOPASSWD: ALL
EOF
chmod 0440 /etc/sudoers.d/node-maintenance
visudo -c -f /etc/sudoers.d/node-maintenance

# ── ansible playbooks + collections ──
rsync -a --delete "$REPO_DIR/ansible/" /etc/node-maintenance/ansible/
chmod 0600 /etc/node-maintenance/ansible/inventory.yml
ansible-galaxy collection install -r /etc/node-maintenance/ansible/requirements.yml --force

# ── SSH key (copy from pre-decrypted path, shred source) ──
install -m 0600 -o node-maintenance -g node-maintenance \
  "$KEY_SRC" /var/lib/node-maintenance/.ssh/id_ed25519
shred -u "$KEY_SRC" 2>/dev/null || rm -f "$KEY_SRC"

# Derive pub key from private (no separate storage)
ssh-keygen -y -f /var/lib/node-maintenance/.ssh/id_ed25519 \
  > /var/lib/node-maintenance/.ssh/id_ed25519.pub
chown node-maintenance:node-maintenance /var/lib/node-maintenance/.ssh/id_ed25519.pub
chmod 0644 /var/lib/node-maintenance/.ssh/id_ed25519.pub

# ── known_hosts ──
install -m 0644 "$REPO_DIR/lib/known_hosts" /etc/node-maintenance/known_hosts

# ── Telegram creds (reuse backup-replication/backup-telegram) ──
kubectl --kubeconfig="$KUBECONFIG_PATH" get secret -n backup-replication backup-telegram \
  -o jsonpath='{.data.bot_token}' | base64 -d > /etc/node-maintenance/telegram-token
chmod 0400 /etc/node-maintenance/telegram-token
kubectl --kubeconfig="$KUBECONFIG_PATH" get secret -n backup-replication backup-telegram \
  -o jsonpath='{.data.chat_id}' | base64 -d > /etc/node-maintenance/telegram-chat-id
chmod 0400 /etc/node-maintenance/telegram-chat-id

# ── notify helper + systemd units ──
install -m 0750 -o root -g root "$REPO_DIR/lib/telegram-notify.sh" /usr/local/sbin/telegram-notify.sh
install -m 0644 "$REPO_DIR/systemd/node-maintenance.timer"                     /etc/systemd/system/
install -m 0644 "$REPO_DIR/systemd/node-maintenance-phase1.service"            /etc/systemd/system/
install -m 0644 "$REPO_DIR/systemd/node-maintenance-phase2.service"            /etc/systemd/system/
install -m 0644 "$REPO_DIR/systemd/node-maintenance-kubectl-proxy.service"     /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now node-maintenance-kubectl-proxy.service
systemctl enable --now node-maintenance.timer
systemctl enable node-maintenance-phase2.service

# Verify kubectl proxy reachable
for i in {1..10}; do
  curl -sf -m 2 http://127.0.0.1:8001/api > /dev/null && break
  [ "$i" = "10" ] && { echo "ERROR: kubectl proxy not reachable after 10s" >&2; exit 1; }
  sleep 1
done
echo "kubectl proxy ready on 127.0.0.1:8001"

# ── generate worker install scripts with pubkey substituted ──
PUB_KEY="$(cat /var/lib/node-maintenance/.ssh/id_ed25519.pub)"
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
