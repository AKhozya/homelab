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

cd "$HOME/source-code/homelab"

# Restart loop — Channels can exit on network issues
while true; do
  echo "$(date): Starting Claude Code with Telegram Channels..."
  claude --channels plugin:telegram@claude-plugins-official \
    --permission-mode acceptEdits || true
  echo "$(date): Claude exited with code $?. Restarting in 5s..."
  sleep 5
done
