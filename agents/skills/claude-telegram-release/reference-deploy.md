# Deploy background

Read this when you need the reason behind a push or deploy step, or the background on model and effort.

## Why pull before tagging

Order matters: homelab has `fetch.pruneTags`, so a `git pull` deletes any local tag the remote
does not have — tagging first then pulling silently drops the tag, and the push succeeds without
it.

## Rollout timing

Measured 2026-08-08 (release 1.32.2): 6m20s wall, of which the image pull was 22.8s. The rest
is `chezmoi-init` — hard-reset of the dotfiles checkout, `chezmoi apply`, then nine plugin
marketplaces. `--timeout=240s` and even `300s` expired on a healthy deploy. The `kubectl rollout status`
command in SKILL.md step 6 therefore waits 480s. The earlier "~90s" figure predates the plugin set. The Deployment sets `strategy: Recreate`, so the
old pod is already gone and the gap is real downtime.

## Model and effort background

As of homelab `cdce0adf`:

- A `node -e` step in the init container also writes
  `model` + `effortLevel` into the PVC's `~/.claude/settings.json`, because that file is
  `.chezmoiignore`'d on linux and would otherwise drift forever.

## Get a valid model identifier

Get a valid model identifier from the binary rather than from docs:

```bash
kubectl exec -n claude-telegram <pod> -c claude-telegram -- sh -c \
  'strings -n 8 /app/node_modules/@anthropic-ai/claude-agent-sdk-linux-x64-musl/claude \
   | grep -oE "claude-(opus|sonnet|haiku|fable)-[0-9a-z-]+" | sort -u'
```
