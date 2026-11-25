#!/usr/bin/env bash
# sync-from-git.sh — pull the homelab repo on the CP; run install.sh --sync-only when HEAD
# differs from the last SHA install.sh applied.
# Invoked by node-maintenance-sync.service (systemd oneshot, root).
set -euo pipefail

REPO_DIR="${NODE_MAINT_REPO_DIR:-/var/lib/node-maintenance/homelab}"
BRANCH="${NODE_MAINT_BRANCH:-main}"
REPO_URL="${NODE_MAINT_REPO_URL:-git@github.com:AKhozya/homelab.git}"
DEPLOY_KEY="${NODE_MAINT_DEPLOY_KEY:-/root/.ssh/homelab-deploy}"
KNOWN_HOSTS="${NODE_MAINT_GH_KNOWN_HOSTS:-/etc/node-maintenance/github_known_hosts}"
# The SHA install.sh last applied, not the checkout's pre-fetch HEAD: `reset --hard` below moves
# HEAD before install.sh runs, so a failed install would otherwise read as applied on the next run.
APPLIED_FILE="/var/lib/node-maintenance/sync-applied-sha"

[ -r "$DEPLOY_KEY" ] || { echo "deploy key missing: $DEPLOY_KEY" >&2; exit 10; }
[ -r "$KNOWN_HOSTS" ] || { echo "known_hosts missing: $KNOWN_HOSTS" >&2; exit 11; }

export GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY -o IdentitiesOnly=yes -o UserKnownHostsFile=$KNOWN_HOSTS -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=10"

if [ ! -d "$REPO_DIR/.git" ]; then
  echo "==> Cloning $REPO_URL → $REPO_DIR"
  install -d -m 0750 -o root -g root "$(dirname "$REPO_DIR")"
  git clone --depth=50 -b "$BRANCH" "$REPO_URL" "$REPO_DIR"
fi

# GitHub sometimes refuses the deploy key ("Permission denied (publickey)") for a short time, then
# accepts it. The growing waits give it time to recover. If all 4 attempts fail, the run exits 128
# and the unit's ExecStopPost alerts.
FETCH_RETRY_DELAYS=(5 30 60)
MAX_ATTEMPTS=$((${#FETCH_RETRY_DELAYS[@]} + 1))
attempt=1
until git -C "$REPO_DIR" fetch --depth=50 origin "$BRANCH"; do
  if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then
    echo "==> git fetch failed after $MAX_ATTEMPTS attempts" >&2
    exit 128
  fi
  delay=${FETCH_RETRY_DELAYS[attempt - 1]}
  echo "==> git fetch failed (attempt $attempt/$MAX_ATTEMPTS); retrying in ${delay}s..."
  sleep "$delay"
  attempt=$((attempt + 1))
done

git -C "$REPO_DIR" checkout "$BRANCH" >/dev/null 2>&1 || true
git -C "$REPO_DIR" reset --hard "origin/$BRANCH"
POST_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)

# Every run, not only on a new SHA: the commit that rotates the token can reach this node
# before Flux applies the Secret. A failed read keeps the old files, so it only warns;
# telegram-notify.sh reports a stale token itself when a send fails.
bash "$REPO_DIR/node-maintenance/lib/refresh-telegram-creds.sh" \
  || echo "==> WARN: Telegram creds refresh failed; kept the existing files" >&2

APPLIED_SHA=$(cat "$APPLIED_FILE" 2>/dev/null || true)
if [ "$APPLIED_SHA" = "$POST_SHA" ]; then
  echo "==> No changes (HEAD=${POST_SHA:0:10}); skip install"
  exit 0
fi

echo "==> Applied ${APPLIED_SHA:0:10} → HEAD ${POST_SHA:0:10}; running install.sh --sync-only"
# install.sh --sync-only takes the node-maintenance lock itself. If the lock is busy, NOWAIT
# makes install.sh exit 75; the SHA stays unapplied for the next 10-min sync.
rc=0
NODE_MAINT_LOCK_NOWAIT=1 bash "$REPO_DIR/node-maintenance/install.sh" --sync-only || rc=$?
if [ "$rc" = 75 ]; then
  echo "==> another node-maintenance run holds the lock; retrying on the next sync"
  exit 0
fi
[ "$rc" = 0 ] || exit "$rc"
# If the heal below fails, node-maintenance-config.timer retries the same unit and playbook at
# 03:00 and 15:00 UTC. Record the SHA before the heal to avoid sync retries and alerts every 10 min.
printf '%s\n' "$POST_SHA" > "$APPLIED_FILE"
echo "==> Sync applied: ${POST_SHA:0:10}"

# ── node-config drift-heal (ansible) ──
# --wait: if the heal fails, this script fails, and the sync unit's ExecStopPost alerts.
if [ -x /usr/bin/ansible-playbook ] && [ -f /etc/node-maintenance/ansible/node-config.yml ]; then
  echo "==> Running node-config playbook"
  systemctl start --wait node-maintenance-config.service
  echo "==> node-config playbook done"
else
  echo "==> node-config.yml or ansible-playbook missing; skipping drift-heal"
fi
