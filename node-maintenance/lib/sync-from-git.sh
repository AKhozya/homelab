#!/usr/bin/env bash
# sync-from-git.sh — pull homelab repo on CP, run install.sh --sync-only if SHA changed.
# Invoked by node-maintenance-sync.service (systemd oneshot, root).
# Runs install.sh only when HEAD differs from the last SHA install.sh applied.
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

# Retry git fetch — transient SSH/network failures are common (exit 128)
MAX_RETRIES=3
RETRY_DELAY=5
for attempt in $(seq 1 "$MAX_RETRIES"); do
  if git -C "$REPO_DIR" fetch --depth=50 origin "$BRANCH"; then
    break
  fi
  if [ "$attempt" -eq "$MAX_RETRIES" ]; then
    echo "==> git fetch failed after $MAX_RETRIES attempts" >&2
    exit 128
  fi
  echo "==> git fetch failed (attempt $attempt/$MAX_RETRIES); retrying in ${RETRY_DELAY}s..."
  sleep "$RETRY_DELAY"
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
# Re-apply declarative config after pull. Idempotent (changed=0 if nothing drifted).
# Runs synchronously; failure = sync.service fails = TG alert via existing ExecStopPost.
if [ -x /usr/bin/ansible-playbook ] && [ -f /etc/node-maintenance/ansible/node-config.yml ]; then
  echo "==> Running node-config playbook"
  systemctl start --wait node-maintenance-config.service
  echo "==> node-config playbook done"
else
  echo "==> node-config.yml or ansible-playbook missing; skipping drift-heal"
fi
