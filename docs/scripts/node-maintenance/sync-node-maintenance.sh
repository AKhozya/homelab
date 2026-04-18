#!/usr/bin/env bash
# sync-node-maintenance.sh — Mac-side wrapper.
# Pulls homelab repo on CP, re-runs install.sh --sync-only.
# Idempotent. Safe to re-run any time after pushing changes to main.
set -euo pipefail

CP_HOST="${NODE_MAINT_CP_HOST:-gmk-k3s-control-plane}"
CP_USER="${NODE_MAINT_CP_USER:-akhozya}"
CP_PORT="${NODE_MAINT_CP_PORT:-65300}"
REPO_URL="${NODE_MAINT_REPO_URL:-https://github.com/AKhozya/homelab.git}"
REPO_DIR_ON_CP="${NODE_MAINT_REPO_DIR:-\$HOME/homelab}"  # literal $HOME for remote expansion
BRANCH="${NODE_MAINT_BRANCH:-main}"

echo "==> Sync node-maintenance to $CP_USER@$CP_HOST:$CP_PORT ($BRANCH)"

# shellcheck disable=SC2087  # intentional mix: $VAR client, \$VAR server
ssh -p "$CP_PORT" -t "$CP_USER@$CP_HOST" "bash -se" <<EOF
set -euo pipefail
REPO_DIR="$REPO_DIR_ON_CP"

if [ ! -d "\$REPO_DIR/.git" ]; then
  echo "==> Cloning $REPO_URL → \$REPO_DIR"
  git clone --depth=50 -b "$BRANCH" "$REPO_URL" "\$REPO_DIR"
else
  echo "==> Pulling latest $BRANCH in \$REPO_DIR"
  git -C "\$REPO_DIR" fetch --depth=50 origin "$BRANCH"
  git -C "\$REPO_DIR" checkout "$BRANCH"
  git -C "\$REPO_DIR" reset --hard "origin/$BRANCH"
fi

HEAD_SHA=\$(git -C "\$REPO_DIR" rev-parse --short HEAD)
echo "==> Repo at \$HEAD_SHA"

sudo bash "\$REPO_DIR/docs/scripts/node-maintenance/install.sh" --sync-only
EOF

echo "==> Sync complete"
