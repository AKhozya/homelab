# Portable .zshrc with Chezmoi Templates

**Date:** 2026-04-13
**Goal:** Make .zshrc portable across macOS + Arch Linux (homelab nodes) via chezmoi templates. One-time setup function for package install.

## Context

- 3 homelab nodes run Arch Linux, currently bash
- User SSHes into nodes from Mac — no local console
- Chezmoi already manages dotfiles across Mac + pod (claude-telegram-bot)
- `.zshrc` = plain file (`dot_zshrc`), needs conversion to template (`dot_zshrc.tmpl`)

## Design

### File Change
- Rename `~/.local/share/chezmoi/dot_zshrc` → `dot_zshrc.tmpl`
- Use `{{ if eq .chezmoi.os "darwin" }}` / `{{ else }}` blocks

### Section Layout

```
1. zsh_setup() — one-time package/plugin installer
2. Core zsh config — options, history, completions, keybindings (both OS)
3. Plugin loading — OS-aware paths
4. Tool initialization — starship (mac-only), zoxide, fzf, fnm/pyenv (mac-only)
5. Env vars — HOMEBREW_* (mac-only), EDITOR/GOPATH (both)
6. Aliases/functions — OS-gated where needed
7. Platform fixups — sed, clipboard, ulimit
```

### zsh_setup() Function

Runs once manually. Installs all required packages + plugins.

**macOS (Homebrew):**
```bash
brew install fzf eza bat zoxide starship neovim fd go kubectl helm flux \
  zsh-autosuggestions zsh-syntax-highlighting zsh-completions zsh-you-should-use \
  fnm pyenv direnv btop viddy dust duf
```

**Linux (pacman + yay):**
```bash
# Install zsh and set as default shell
sudo pacman -S --needed --noconfirm zsh
chsh -s /usr/bin/zsh

# Core tools
sudo pacman -S --needed --noconfirm fzf eza bat zoxide neovim fd kubectl helm \
  btop zsh-completions zsh-autosuggestions zsh-syntax-highlighting

# AUR packages (require yay)
yay -S --needed --noconfirm flux-bin zsh-you-should-use viddy duf dust
```

### Plugin Paths

| Plugin | macOS | Linux |
|--------|-------|-------|
| zsh-autosuggestions | `/opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh` | `/usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh` |
| zsh-syntax-highlighting | `/opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh` | `/usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh` |
| zsh-you-should-use | `/opt/homebrew/share/zsh-you-should-use/you-should-use.plugin.zsh` | `/usr/share/zsh/plugins/zsh-you-should-use/you-should-use.plugin.zsh` |
| zsh-completions | `/opt/homebrew/share/zsh-completions` (FPATH) | `/usr/share/zsh/site-functions` (FPATH, auto-included) |

### macOS-Only Sections (skipped on Linux)

| Section | Reason |
|---------|--------|
| starship init | Prompt remote-side; nodes SSH-only — simple `%m%#` prompt sufficient |
| HOMEBREW_* env vars | No Homebrew on Arch |
| Android SDK, Java JDK, Ruby paths | Dev tools, not on servers |
| fnm, pyenv, direnv init | Dev version managers |
| `sw_update()` | Homebrew/mas updater |
| `claude_update_plugins()` | Claude Code not on nodes |
| Docker aliases | No Docker desktop on nodes |
| Chezmoi aliases | Managed from Mac |
| Brewfile check | Homebrew-specific |
| `flushdns` alias | macOS dscacheutil |
| `pbcopy` in fzf binding | Use `xclip -sel clip` on Linux |
| `localip` alias | macOS: `ipconfig getifaddr en0`, Linux: `ip route get 1 \| awk '{print $7}'` |
| `sed -i ''` in functions | macOS BSD sed; Linux uses `sed -i` |
| `ulimit -n 10240` | macOS default too low; Linux default fine |

### Linux-Only Sections
| Section | Reason |
|---------|--------|
| Simple zsh prompt (`%m%#`) | No starship — SSH-only |
| `localip` via `ip route` | Linux network tools |
| `xclip` in fzf binding | Linux clipboard |

### Both OS (no changes needed)
- Zsh options, history, completions, keybindings
- kubectl, flux, helm aliases + completions
- Git aliases
- Safety aliases (rm -i, cp -i, mv -i)
- SSH aliases to nodes
- eza/bat aliases
- fzf power functions (kctx-fzf, kpod-fzf, fgit)
- Extract function, ff, fkill
- EDITOR, GOPATH env vars

### Template Strategy

Chezmoi `{{ if }}` blocks. Sections with 1-2 line differences (like localip) = inline conditionals. Larger blocks (sw_update, plugin paths) = block conditionals.

```
{{ if eq .chezmoi.os "darwin" -}}
# macOS block
{{ else -}}
# Linux block
{{ end -}}
```

### Validation

After conversion, `chezmoi diff` on Mac must show zero changes — output identical to current .zshrc.

## Out of Scope
- Node provisioning (user installs chezmoi + runs `chezmoi init` separately)
- Chezmoi config (`chezmoi.toml`) per node — reuse existing SSH data section
- Claude-telegram pod .zshrc — pod has own lifecycle, gets whatever chezmoi produces for Linux
