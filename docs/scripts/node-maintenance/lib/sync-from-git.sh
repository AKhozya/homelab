#!/usr/bin/env bash
# sync-from-git.sh — pull homelab repo on CP, run install.sh --sync-only if SHA changed.
# Invoked by node-maintenance-sync.service (systemd oneshot, root).
# Idempotent + fast no-op when HEAD unchanged.
set -euo pipefail

REPO_DIR="${NODE_MAINT_REPO_DIR:-/var/lib/node-maintenance/homelab}"
BRANCH="${NODE_MAINT_BRANCH:-main}"
REPO_URL="${NODE_MAINT_REPO_URL:-git@github.com:AKhozya/homelab.git}"
DEPLOY_KEY="${NODE_MAINT_DEPLOY_KEY:-/root/.ssh/homelab-deploy}"
KNOWN_HOSTS="${NODE_MAINT_GH_KNOWN_HOSTS:-/etc/node-maintenance/github_known_hosts}"

[ -r "$DEPLOY_KEY" ] || { echo "deploy key missing: $DEPLOY_KEY" >&2; exit 10; }
[ -r "$KNOWN_HOSTS" ] || { echo "known_hosts missing: $KNOWN_HOSTS" >&2; exit 11; }

export GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY -o IdentitiesOnly=yes -o UserKnownHostsFile=$KNOWN_HOSTS -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=10"

FRESH_CLONE=0
if [ ! -d "$REPO_DIR/.git" ]; then
  echo "==> Cloning $REPO_URL → $REPO_DIR"
  install -d -m 0750 -o root -g root "$(dirname "$REPO_DIR")"
  git clone --depth=50 -b "$BRANCH" "$REPO_URL" "$REPO_DIR"
  FRESH_CLONE=1
fi

PRE_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)
git -C "$REPO_DIR" fetch --depth=50 origin "$BRANCH"
git -C "$REPO_DIR" checkout "$BRANCH" >/dev/null 2>&1 || true
git -C "$REPO_DIR" reset --hard "origin/$BRANCH"
POST_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)

if [ "$FRESH_CLONE" -eq 0 ] && [ "$PRE_SHA" = "$POST_SHA" ]; then
  echo "==> No changes (HEAD=${POST_SHA:0:10}); skip install"
  exit 0
fi

if [ "$FRESH_CLONE" -eq 1 ]; then
  echo "==> Fresh clone (HEAD=${POST_SHA:0:10}); running install.sh --sync-only"
else
  echo "==> HEAD ${PRE_SHA:0:10} → ${POST_SHA:0:10}; running install.sh --sync-only"
fi
bash "$REPO_DIR/docs/scripts/node-maintenance/install.sh" --sync-only
echo "==> Sync applied: ${POST_SHA:0:10}"

# ── node-config drift-heal (ansible) ──
# Re-apply declarative config after pull. Idempotent (changed=0 if nothing drifted).
# Runs synchronously; failure = sync.service fails = TG alert via existing ExecStopPost.
if [ -x /usr/bin/ansible-playbook ] && [ -f /etc/node-maintenance/ansible/node-config.yml ]; then
  echo "==> Running node-config playbook"
  systemctl start --wait node-maintenance-config.service
  echo "==> node-config playbook done"
else
  echo "==> node-config.yml or ansible-playbook missing; skipping drift-heal"
fi
