---
name: brave-automation
description: Use when browser automation is needed (claude-in-chrome / mcp__claude-in-chrome__* tools, driving a web UI, authed admin pages) or when the extension reports "Browser extension is not connected" — this machine's automation browser is Brave, not Chrome.
---

# Brave Browser Automation

The claude-in-chrome extension lives in **Brave Browser** on this Mac. Chrome is not the automation target. Authed sessions (Immich/Authentik OIDC, passkey-gated admin UIs) live in the Brave profile — UI automation works without re-login.

## Rules (operator-authorized 2026-07-23)

1. **Never prompt the user to open a browser.** Launch and take control autonomously.
2. **"Browser extension is not connected"** = Brave not running, still starting, or a stale instance (ladder below). NOT a missing extension — don't report failure after one try.
3. **Never spawn a second window**: if `pgrep` matches, skip `open -a` (extra window + focus steal). Work only inside the MCP tab group (`tabs_context_mcp {createIfEmpty: true}`); never drive the user's own tabs unless asked.

## Connection ladder (bounded, ~40s worst case)

```bash
# Rung 1 — not running → launch. open failure must surface, not vanish into sleep's exit code.
if ! pgrep -x "Brave Browser" >/dev/null; then
	open -a "Brave Browser" || { echo "Brave launch FAILED" >&2; exit 1; }
	sleep 5
fi
```

Retry `tabs_context_mcp`; still not connected → one more retry after ~5s (extension registers shortly after startup).

**Rung 2 — running but still disconnected = stale instance.** Known cause: `brew upgrade` replaces `Brave Browser.app` while Brave is open — the running process keeps the old unlinked binaries, the extension host dies, and the UI misbehaves for the user too. Fix is ONE graceful restart cycle (quit = Cmd-Q equivalent; session/tabs restore on relaunch):

```bash
osascript -e 'quit app "Brave Browser"'
for _ in 1 2 3 4 5 6; do pgrep -x "Brave Browser" >/dev/null || break; sleep 2; done
open -a "Brave Browser" && sleep 5
```

Retry `tabs_context_mcp` once. Still dead → stop and report (extension genuinely broken); no restart loop.

## Common mistakes

- Retrying against a closed browser, then asking the user to open "Chrome" (live failure 2026-07-23 — three dead calls + a needless user round-trip).
- Treating pgrep-matches as "browser healthy": a brew-upgraded-underneath instance runs and matches pgrep but the extension is dead — that's rung 2, not an error report.
- `open -a` while Brave already runs → extra window and focus steal.
