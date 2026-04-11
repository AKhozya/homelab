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

# Pre-warm: run a quick non-interactive command to complete any first-run setup
echo "Pre-warming Claude Code (completing first-run setup)..."
claude -p "echo hello" --max-turns 1 --allowedTools "" 2>/dev/null || true
echo "Pre-warm complete."

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
  # expect provides a PTY (required by --channels interactive mode)
  expect -c '
    set timeout -1
    spawn claude --channels plugin:telegram@claude-plugins-official --permission-mode acceptEdits
    expect eof
  ' || true
  echo "$(date): Claude exited. Restarting in 5s..."
  sleep 5
done
