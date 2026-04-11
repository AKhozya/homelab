#!/bin/bash
set -e

echo "Claude Telegram Bot starting..."
echo "HOME=$HOME"
echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Verify critical paths
for path in "$HOME/.claude/CLAUDE.md" "$HOME/.ssh/id_ed25519" "$HOME/source-code/homelab"; do
  if [ -e "$path" ]; then
    echo "OK: $path"
  else
    echo "WARN: $path not found"
  fi
done

# Verify tools
for tool in claude kubectl flux gh git ssh bun chezmoi; do
  if command -v "$tool" &>/dev/null; then
    echo "OK: $tool"
  else
    echo "WARN: $tool not found"
  fi
done

# Background config sync (every 30 min)
(
  while true; do
    sleep 1800
    echo "$(date): Syncing config..."
    git -C "$HOME/.local/share/chezmoi" pull --quiet 2>/dev/null && \
      chezmoi apply --force --no-tty 2>/dev/null && \
      echo "$(date): Dotfiles synced" || \
      echo "$(date): Dotfiles sync failed (non-fatal)"
    git -C "$HOME/source-code/homelab" pull --quiet 2>/dev/null && \
      echo "$(date): Homelab repo synced" || \
      echo "$(date): Homelab sync failed (non-fatal)"
  done
) &

cd "$HOME/source-code/homelab"

# Restart loop — Channels can exit on network issues
while true; do
  echo "$(date): Starting Claude Code with Telegram Channels..."
  # script -qec fakes a PTY — required by --channels (interactive mode)
  script -qec "claude --channels plugin:telegram@claude-plugins-official \
    --permission-mode acceptEdits" /dev/null || true
  echo "$(date): Claude exited with code $?. Restarting in 5s..."
  sleep 5
done
