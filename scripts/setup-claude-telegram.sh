#!/bin/bash
# Setup script for claude-telegram on worker-node
# Run this from your Mac BEFORE deploying the claude-telegram pod
#
# Usage: ./scripts/setup-claude-telegram.sh <chezmoi-dotfiles-repo>
# Example: ./scripts/setup-claude-telegram.sh github.com/akhozya/dotfiles

set -euo pipefail

NODE_HOST="worker-node"
NODE_PORT="65300"
NODE_USER="akhozya"
SSH_CMD="ssh -p ${NODE_PORT} ${NODE_USER}@${NODE_HOST}"

DOTFILES_REPO="${1:-}"

if [ -z "$DOTFILES_REPO" ]; then
  echo "Usage: $0 <chezmoi-dotfiles-repo>"
  echo "Example: $0 github.com/akhozya/dotfiles"
  exit 1
fi

echo "=== Claude Telegram Setup for ${NODE_HOST} ==="
echo ""

# Step 1: Test SSH connectivity
echo "[1/7] Testing SSH connectivity..."
${SSH_CMD} 'echo "OK: Connected as $(whoami)@$(hostname)"'

# Step 2: Install chezmoi
echo "[2/7] Installing chezmoi..."
${SSH_CMD} 'command -v chezmoi &>/dev/null && echo "chezmoi already installed" || (curl -fsLS get.chezmoi.io | sh -s -- -b ~/.local/bin && echo "chezmoi installed to ~/.local/bin")'

# Step 3: Apply chezmoi dotfiles
echo "[3/7] Applying chezmoi dotfiles..."
${SSH_CMD} "export PATH=\"\$HOME/.local/bin:\$PATH\" && chezmoi init --apply ${DOTFILES_REPO}"
echo "Verifying key files..."
${SSH_CMD} 'for f in ~/.claude/CLAUDE.md ~/.gitconfig ~/.config/gh/hosts.yml; do [ -e "$f" ] && echo "OK: $f" || echo "MISSING: $f"; done'

# Step 4: Clone homelab repo
echo "[4/7] Setting up homelab repo..."
${SSH_CMD} 'if [ -d ~/source-code/homelab/.git ]; then echo "Repo exists, pulling latest..."; cd ~/source-code/homelab && git pull; else mkdir -p ~/source-code && git clone git@github.com:akhozya/homelab.git ~/source-code/homelab && echo "Cloned homelab repo"; fi'

# Step 5: Install Node.js (if needed) and Claude Code
echo "[5/7] Installing Node.js and Claude Code..."
${SSH_CMD} 'if command -v node &>/dev/null; then
  echo "Node.js $(node --version) already installed"
else
  echo "Installing Node.js via nvm..."
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm install 24
  echo "Node.js $(node --version) installed"
fi'

${SSH_CMD} 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; command -v claude &>/dev/null && echo "Claude Code already installed" || (npm install -g @anthropic-ai/claude-code && echo "Claude Code installed")'

# Step 6: GitHub CLI auth
echo "[6/7] Checking GitHub CLI auth..."
${SSH_CMD} 'gh auth status 2>/dev/null && echo "gh CLI already authenticated" || echo "NEEDS_AUTH: gh CLI not authenticated"'
GH_STATUS=$(${SSH_CMD} 'gh auth status 2>&1 || true')
if echo "$GH_STATUS" | grep -q "not logged"; then
  echo ""
  echo "gh CLI needs authentication on worker-node."
  echo "Enter a GitHub Personal Access Token (with repo scope):"
  read -rs GH_TOKEN
  ${SSH_CMD} "mkdir -p ~/.config/gh && cat > ~/.config/gh/hosts.yml << 'GHEOF'
github.com:
  oauth_token: ${GH_TOKEN}
  user: akhozya
  git_protocol: ssh
GHEOF
chmod 600 ~/.config/gh/hosts.yml"
  echo "gh CLI configured"
fi

# Step 7: Install Telegram Channels plugin
echo "[7/7] Installing Telegram plugin..."
echo "NOTE: Plugin install may require interactive Claude session."
echo "If this fails, SSH to worker-node and run:"
echo "  claude"
echo "  /plugin install telegram@claude-plugins-official"
echo ""
${SSH_CMD} 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; if [ -d ~/.claude/plugins/cache/claude-plugins-official/telegram ]; then echo "Telegram plugin already installed"; else echo "Attempting plugin install..."; claude /plugin install telegram@claude-plugins-official 2>/dev/null || echo "MANUAL: Plugin install needs interactive session"; fi'

# Final verification
echo ""
echo "=== Verification ==="
${SSH_CMD} 'echo "--- Paths ---"
for p in ~/.claude/CLAUDE.md ~/.claude/settings.json ~/.gitconfig ~/.config/gh/hosts.yml ~/source-code/homelab/.git ~/.local/share/chezmoi/.git; do
  [ -e "$p" ] && echo "OK: $p" || echo "MISSING: $p"
done
echo "--- Tools ---"
for t in git chezmoi gh node claude; do
  command -v "$t" &>/dev/null && echo "OK: $t ($(${t} --version 2>/dev/null | head -1))" || echo "MISSING: $t"
done
echo "--- UID ---"
id'

echo ""
echo "=== Setup Complete ==="
echo "Next: git push && flux reconcile kustomization apps --timeout=60s"
