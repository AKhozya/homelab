---
name: claude-telegram-release
description: Use to build, publish and deploy a new claude-telegram-bot image — "rebuild the bot", "new bot version", "publish the bot image", "release the bot". Covers both paths — the normal GitHub Actions workflow and the local amd64 build on the Rancher socket when Actions is billing-blocked — plus the live tool-surface probe and the homelab deployment bump.
user-invocable: true
---

# claude-telegram bot release (local escape hatch)

The bot normally builds in **homelab's** `.github/workflows/claude-telegram-build.yml`, which
checks out the fork via `repository: AKhozya/claude-telegram-bot`. The fork itself holds only
`ci.yml` — there is no build workflow there to find. While GitHub billing is blocked, that
workflow cannot run and the whole release happens on the Mac.

Because the build workflow lives in homelab, **homelab's** CI is the one whose liveness decides
whether you need this skill — the fork's CI can be green while homelab's is billing-blocked.

Repos: fork `/Users/akhozya/source-code/claude-telegram-bot` (source + tests) ·
`/Users/akhozya/source-code/homelab` `apps/claude-telegram/deployment.yaml` (deployment).

## 0. Confirm CI really is dead — don't assume

```bash
gh run list --repo AKhozya/homelab --limit 3
gh run view <id> --repo AKhozya/homelab --json jobs --jq '[.jobs[] | {name, steps: (.steps|length)}]'
```

A billing block looks like success at the run level: runs get **created**, then every job dies
with **`steps: 0`**. That zero-step count is the fastest tell. If jobs have steps, CI is alive —
take the workflow path below and skip steps 2, 4-build, 5 and the tag half of 6.

## CI alive: the workflow path (proven 2026-08-04 release 1.31.6; explicit version 2026-08-07 release 1.32.0)

Push the fork commit first, then:

```bash
# Dispatch ONE of the two forms:
gh workflow run claude-telegram-build.yml --repo AKhozya/homelab                      # patch bump (empty input auto-increments)
gh workflow run claude-telegram-build.yml --repo AKhozya/homelab -f version=<VERSION> # explicit — the only way to bump minor
gh run list --repo AKhozya/homelab --limit 1 --json databaseId,workflowName   # grab the run id
gh run view <id> --repo AKhozya/homelab --json status,conclusion   # poll until completed/success
```

Auto-increment only ever moves patch, and the **Mon/Thu 23:00 UTC scheduled rebuild moves it too** —
check what the deployment pins right before choosing a version, not earlier in the session (a
scheduled build bumped 1.31.6→1.31.7 overnight mid-task on 2026-08-07 and a stale read made the
first tag-bump `sd` a silent no-op).

The workflow checks out fork main, builds, pushes the image **and** the `claude-telegram-v<VERSION>`
git tag — do not tag again in step 6. Confirm what it produced:

```bash
git -C /Users/akhozya/source-code/homelab ls-remote --tags origin 'claude-telegram-v1.*' | tail -3
```

Then pull for verification — **`--platform linux/amd64` is required**: the image ships no arm64
manifest, so a bare pull fails on Apple silicon:

```bash
docker pull --platform linux/amd64 ghcr.io/akhozya/claude-telegram-bot:<VERSION>
```

Run step 4's in-image checks unchanged. They matter MORE on this path, not less: the missing
`mcp-config.ts` defect was CI-build-specific (a local build masks it with the developer's own
config), so a CI-built image is exactly the one to verify. Then deploy via step 6 without the
tag commands.

## 1. Pull the fork FIRST

```bash
git -C /Users/akhozya/source-code/claude-telegram-bot pull
```

Not optional. Renovate lands "Lock file maintenance" PRs on the fork, and **the lockfile is what
moves the Agent SDK**. If you build without pulling, the build installs the older SDK. The surface
probe then reports that version, so it does not validate the updated dependency.

## 2. Host CI replica — all three, in order

```bash
cd /Users/akhozya/source-code/claude-telegram-bot
bun install --frozen-lockfile
bun run typecheck
bun test
```

No compile step: `package.json` has no `build` script and the image runs `src/index.ts`
directly. `bun build --compile` belongs to the ClaudeBot macOS wrapper, not this release.

`--frozen-lockfile` here, deliberately: it proves the committed lockfile is what CI would
resolve. The Dockerfile uses `bun update` instead, so the image can float **past** the lock —
which is exactly why step 4's in-image run is the authoritative one.

## 3. Pick the version

Next patch above the tag currently deployed:

```bash
rg -m1 'claude-telegram-bot:' /Users/akhozya/source-code/homelab/apps/claude-telegram/deployment.yaml
```

## 4. Build amd64 and verify INSIDE the image

Rancher Desktop's moby socket, amd64 under emulation on Apple silicon. Rancher is often NOT
running — no socket means every docker command dies `dial unix ... no such file or directory`:

```bash
[ -S ~/.rd/docker.sock ] || ~/.rd/bin/rdctl start   # ~30s to socket; engine needs a few more — wait for `docker info`
export DOCKER_HOST="unix://$HOME/.rd/docker.sock" PATH="$HOME/.rd/bin:$PATH"
docker build --platform linux/amd64 \
  --build-arg BUILD_TS=$(date -u +%Y%m%dT%H%M%SZ) \
  -t ghcr.io/akhozya/claude-telegram-bot:<VERSION> .
```

If you started Rancher, `~/.rd/bin/rdctl shutdown` when done — leave the machine as found. The
first pull after a cold VM boot can flake `i/o timeout`; retry once before diagnosing.

A retry does not always clear it. On 2026-08-13 two builds in a row died on the same line —
`failed to resolve source metadata for docker.io/oven/bun:1.3-alpine ... dial tcp 98.84.245.6:443:
i/o timeout` — while `docker run alpine:3` pulled fine and reached the same registry from inside
the VM. BuildKit's metadata HEAD is the part that hangs, not egress. Pull the base image by hand,
then rebuild; the build then reads it from the local store and completes:

```bash
docker pull --platform linux/amd64 oven/bun:1.3-alpine
```

Then, in the built image — **`--platform linux/amd64` on every `docker run` too**, not just the
pull: without it the daemon looks for an arm64 manifest and fails `no matching manifest for
linux/arm64/v8` (bit the 1.32.0 release):

```bash
docker run --rm --platform linux/amd64 --entrypoint sh ghcr.io/akhozya/claude-telegram-bot:<VERSION> -c \
  'cat node_modules/@anthropic-ai/claude-agent-sdk/package.json | grep version; \
   node_modules/@anthropic-ai/claude-agent-sdk-linux-x64-musl/claude --version'
docker run --rm --platform linux/amd64 --entrypoint sh ghcr.io/akhozya/claude-telegram-bot:<VERSION> -c 'bun test'
docker run --rm --platform linux/amd64 --entrypoint sh ghcr.io/akhozya/claude-telegram-bot:<VERSION> -c 'bun test src/security.test.ts'
docker run --rm --platform linux/amd64 --entrypoint sh ghcr.io/akhozya/claude-telegram-bot:<VERSION> -c \
  'TELEGRAM_BOT_TOKEN=x TELEGRAM_ALLOWED_USERS=1 bun -e "await import(\"/app/src/config.ts\")" 2>&1 | grep -i mcp'
```

- **agent-sdk 0.3.X and the vendored CLI 2.1.X move in lockstep** — a mismatch is a red flag.
- Expect **1 skipped** test in-image (zip fixture; the image has `unzip`, not `zip`). On the host
  it passes, so host and image totals differ by one by design.
- **On Apple silicon, `docker run` of this image is QEMU emulation, and its `bun test` result is
  not evidence.** Anything that spawns a process is ~100x slower there, so the MCP stdio tests
  lose their transport and Bun's 5s hook budget expires. Measured 2026-08-07 on an M-series Mac:

  | where | result |
  |---|---|
  | host (arm64, native) | 526 run · 526 pass / 0 fail · 24s |
  | in-image via `docker run --platform linux/amd64` | 479 run · **4-6 fail** · 74-93s |
  | in-image, hook budget raised so the aborted files run | 526 run · **23+11 fail** (`Not connected`) · 105s |
  | **in-cluster `kubectl exec` (real amd64)** | **526 run · 525 pass / 1 skip / 0 fail · 22s** |

  The same two MCP files: **34 failures emulated, 51 pass / 0 fail in the pod in 607ms.** Raising
  the timeout does not fix it — it only converts "47 tests never ran" into "47 tests ran and 34
  failed". Do not chase these, and do not raise timeouts for them.

  **Verify in the cluster instead**, which is real amd64 and takes seconds:

  ```bash
  pod=$(kubectl get pod -n claude-telegram -l app=claude-telegram -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -n claude-telegram "$pod" -c claude-telegram -- sh -c 'cd /app && bun test 2>&1 | tail -6'
  ```

  Non-destructive: `test-preload.ts` redirects `AUDIT_LOG_PATH` and `TEMP_DIR`, and the MCP tests
  use a chat id no real chat has. It costs the pod ~22s of CPU. Run it after the rollout, as the
  post-deploy check — the emulated pre-push run is only good for the SDK/CLI version pair and the
  MCP-config line below, neither of which spawns anything. The surface probe below spawns the CLI,
  so it needs native execution and an authenticated environment.
- **Probe the live tool surface.** The gate defaults to deny, so the model cannot call a tool the
  CLI adds. Nothing reports that the tool exists either, so the surface needs a periodic read.
  Nothing hermetic can produce it: the CLI binary arrives at install time, and reading its surface
  needs auth and a spawn.

  | Fact | Value |
  | --- | --- |
  | What the probe answers for | The SDK installed where you run it, and nothing else |
  | Pod probe reports | The deployed image, not a branch |
  | PR probe | Run the same script on the checkout after `bun install`; the pod still runs the old image |
  | Why a PR needs it | The SDK's `manifest.json` pins the CLI, so a Renovate SDK bump moves the surface |
  | Cost | One model turn |
  | `require` path | Absolute. Bun does not resolve `@anthropic-ai/...` from `/tmp` |
  | `options.tools` | Omitted on purpose. If the allowlist applies, the output repeats the allowlist |
  | Pod selection | Name the pod. If a rollout is in progress, `.items[0]` can select the outgoing one |
  | `settingSources` | Matches `session.ts`. Settings can remove tools from the surface, so a probe without them measures something the bot never sees |
  | Hooks | The probe loads the same settings, so it runs SessionStart hooks, as every bot query does |

  ```bash
  cat > /tmp/tool-surface.ts <<'TS'
  import { query } from "@anthropic-ai/claude-agent-sdk";
  const manifest = require(process.env.SDK_MANIFEST!);
  let seen = false;
  for await (const e of query({
    prompt: "hi",
    options: {
      maxTurns: 1,
      strictMcpConfig: true,
      mcpServers: {},
      settingSources: ["user", "project"],
    } as any,
  }) as any) {
    if (e.type === "system" && e.subtype === "init") {
      console.log("CLI " + manifest.version);
      console.log("SURFACE " + e.tools.filter((t: string) => !t.startsWith("mcp__")).sort().join(" "));
      seen = true;
      break;
    }
  }
  // Exit non-zero if no init event arrived, so a failed probe cannot read as a clean one.
  process.exit(seen ? 0 : 1);
  TS
  ```

  In the pod:

  ```bash
  # Quote the -o value: if it is unquoted, zsh treats `[0]` as a glob and the command fails with
  # "no matches found" before kubectl runs.
  kubectl get pod -n claude-telegram -l app=claude-telegram \
    -o 'custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image,AGE:.metadata.creationTimestamp'
  pod=<the pod you mean>
  kubectl cp /tmp/tool-surface.ts claude-telegram/$pod:/tmp/tool-surface.ts -c claude-telegram
  kubectl exec -n claude-telegram "$pod" -c claude-telegram -- \
    sh -c 'cd /app && SDK_MANIFEST=/app/node_modules/@anthropic-ai/claude-agent-sdk/manifest.json bun run /tmp/tool-surface.ts'
  ```

  On a checkout, for a Renovate SDK PR before it deploys:

  ```bash
  SDK_MANIFEST=$PWD/node_modules/@anthropic-ai/claude-agent-sdk/manifest.json bun run /tmp/tool-surface.ts
  ```

  Do not pipe either command into `tail`. The pipeline then reports `tail`'s status, so a failed
  probe reports success. Diff the `SURFACE` line against the run below, then classify each new
  name in `ALLOWED_BUILTIN_TOOLS` or `DENIED_TOOLS` in `src/security.ts`.

  | Where | Image / checkout | CLI | Built-ins | Date | Exit |
  | --- | --- | --- | --- | --- | --- |
  | Pod `claude-telegram-774f8f8fdf-5v9rn` | `ghcr.io/akhozya/claude-telegram-bot:1.32.14` | 2.1.283 | 22 | 2026-09-26 | 0 |
  | Dev Mac checkout | SDK 0.3.282 | 2.1.282 | 23 | 2026-09-26 | 0 |
  | Pod `claude-telegram-58b94547cb-q7hp5` | `ghcr.io/akhozya/claude-telegram-bot:1.32.13` | 2.1.273 | 23 | 2026-09-16 | 0 |
  | Pod `claude-telegram-694c55bbd7-9nr57` | `ghcr.io/akhozya/claude-telegram-bot:1.32.12` | 2.1.263 | 23 | 2026-09-16 | 0 |
  | Dev Mac checkout | SDK 0.3.273 | 2.1.273 | 24 | 2026-09-16 | 0 |

  Pod, CLI 2.1.273 and 2.1.263 alike:

  ```
  Bash CronCreate CronDelete CronList Edit EnterWorktree ExitWorktree ListAgents NotebookEdit
  Read RemoteTrigger ReportFindings ScheduleWakeup SendMessage Skill Task TaskOutput TaskStop
  ToolSearch WebFetch WebSearch Workflow Write
  ```

  Dev Mac, CLI 2.1.273:

  ```
  Bash CronCreate CronDelete CronList DesignSync Edit EnterWorktree ExitWorktree ListAgents
  Monitor NotebookEdit PushNotification Read RemoteTrigger ReportFindings ScheduleWakeup
  SendMessage Skill Task TaskOutput TaskStop ToolSearch Workflow Write
  ```

  The 2026-09-26 probes, pod CLI 2.1.283 and Mac CLI 2.1.282, match the lists above except that
  `TaskOutput` is gone from both. They add no new names.

  **The CLI version does not explain the difference.** The pod and the Mac both run 2.1.273 and
  still differ in both directions, so read a name's absence as a property of the environment that
  produced it, never of the build:

  | Name | Mac 2.1.273 | Pod 2.1.273 | Pod 2.1.263 |
  | --- | --- | --- | --- |
  | `DesignSync`, `Monitor`, `PushNotification` | served | absent | absent |
  | `WebFetch`, `WebSearch` | absent — `~/.claude/settings.json` denies both | served | served |

  Record where each probe ran, because a snapshot without its environment answers nothing.


  Claims a probe refutes:

  | Claim | What a probe shows |
  | --- | --- |
  | `sdk-tools.d.ts` describes the served surface | It does not. It declares `AgentInput` and `FileReadInput`; the runtime serves `Task` and `Read` |
  | The deleted `SDK tool-surface tripwire` test covers the surface | It reads `sdk-tools.d.ts`. It matches 45 of 45 declared schemas and misses 9 of the 24 names CLI 2.1.273 serves on the dev Mac |
  | `WebFetch`/`WebSearch` do not exist in this build | The pod serves both. The dev Mac lacks them because `~/.claude/settings.json` denies them. The SSRF branch in `evaluateToolUse` is live code |

- **Read the bot's own tool-gap warning after the rollout.** `session.ts` diffs
  `ALLOWED_BUILTIN_TOOLS` against the init event and logs `Allowed tools not served by the CLI:`
  once per distinct gap. That line detects a rename: if the CLI does not know a name in
  `options.tools` it drops that name without a diagnostic. Send the bot one message, then:

  Read the whole log for the current container, not a recent window. The bot logs the line once per
  distinct gap per process, so a later message does not repeat a gap it already reported.

  ```bash
  # `&&` so the search runs only if retrieval succeeds: a failed `kubectl logs` truncates the file,
  # and an unguarded search then reports no gap. `grep -c` prints the count and exits 1 if that
  # count is 0, which stops a `set -e` script.
  kubectl logs -n claude-telegram "$pod" -c claude-telegram > /tmp/bot.log \
    && grep -c 'not served by the CLI' /tmp/bot.log
  ```

  | Result | Meaning |
  | --- | --- |
  | `0` | Every allowed tool is served |
  | Non-zero | Run `grep 'not served by the CLI' /tmp/bot.log` to see which tools are missing |
  | Image built before commit `5f6a200` (2026-09-16) | `0` proves the command runs, not that the gap check passed. The warning does not exist in that build |
  | `WebFetch, WebSearch` named | Correct on the macOS standalone, because settings deny both there |



- **The last command must print `Loaded 2 MCP servers from mcp-config.ts`.** `mcp-config.ts` is
  gitignored, so the Dockerfile copies `mcp-config.example.ts` in as the image default; if that
  breaks, the only symptom is one startup line reading `No mcp-config.ts found` and `ask_user` /
  `send_file` silently do not exist. Verified absent in both the 1.30.0 and 1.30.1 images (how
  far back it goes was not checked). It went unnoticed because a *local* build picks up the
  developer's own `mcp-config.ts` and looks fine, while a CI build has none — and neither the
  suite nor the surface probe covers it.

## 5. Push

```bash
docker push ghcr.io/akhozya/claude-telegram-bot:<VERSION>
```

Needs `write:packages` (`gh auth status` to confirm).

**Never leave the deployment pulling anonymously.** The image is ~742MB and GHCR throttles
anonymous blob fetches hard — that caused a 28-minute outage on 2026-07-19. The
`claude-telegram-ghcr` pull secret on the ServiceAccount is what keeps pulls fast; don't remove it.

## 6. Deploy through git, in a worktree

```bash
cd /Users/akhozya/source-code/homelab
git worktree add .claude/worktrees/bot-<VERSION> -b wt-bot-<VERSION>
```

Bump **all three** image refs in `apps/claude-telegram/deployment.yaml` (init containers share
the tag — `rg -c` should return 3 before and after). Then `/homelab-yaml-validate`, commit,
merge to main, **`git pull --rebase` BEFORE tagging**, then tag and push both in one command:

```bash
git -C /Users/akhozya/source-code/homelab -c tag.gpgsign=false \
  tag -a claude-telegram-v<VERSION> -m "claude-telegram <VERSION>"
git -C /Users/akhozya/source-code/homelab push origin main claude-telegram-v<VERSION>
```

Order matters: homelab has `fetch.pruneTags`, so a `git pull` deletes any local tag the remote
does not have — tagging first then pulling silently drops the tag, and the push succeeds without
it. Also note `git -C <repo>` targets the MAIN worktree; commits inside a release worktree need
`git -C <worktree-path>`. Then `flux reconcile` and:

```bash
kubectl rollout status deploy/claude-telegram -n claude-telegram --timeout=480s
kubectl get pod -n claude-telegram -l app=claude-telegram --no-headers
kubectl logs -n claude-telegram -l app=claude-telegram -c claude-telegram --tail=15
```

Healthy log ends with `Bot started: @ClaudeSelfHostedBot` and the loopback trigger listening.

**Budget ~6-7 min for the rollout, and do not read a `rollout status` timeout as a failure.**
Measured 2026-08-08 (release 1.32.2): 6m20s wall, of which the image pull was 22.8s. The rest
is `chezmoi-init` — hard-reset of the dotfiles checkout, `chezmoi apply`, then nine plugin
marketplaces. `--timeout=240s` and even `300s` expired on a healthy deploy. The command above
therefore waits 480s. The earlier "~90s" figure predates the plugin set. The Deployment sets `strategy: Recreate`, so the
old pod is already gone and the gap is real downtime. Read `kubectl logs -c chezmoi-init`
before intervening. If those logs stop advancing, treat it as stuck.

Finish with `worktree-cleanup` — `--repo` takes a PATH, not a repo name
(`--repo homelab` exits 3 `not a git repo`).

## Model and effort

Set in `deployment.yaml`, not in the fork. As of homelab `cdce0adf`:

- **`ANTHROPIC_MODEL`** pins the model and overrides `~/.claude/settings.json` (verified against
  CLI 2.1.220). `CLAUDE_CODE_DEFAULT_MODEL` was **inert** — no consumer in the CLI, SDK or bot —
  and has been removed. Do not reintroduce it.
- **`CLAUDE_CODE_EFFORT_LEVEL`** pins effort. A `node -e` step in the init container also writes
  `model` + `effortLevel` into the PVC's `~/.claude/settings.json`, because that file is
  `.chezmoiignore`'d on linux and would otherwise drift forever.

**Effort and thinking are coupled — check both before changing either.** `effortLevel: "xhigh"`
with `thinking: {type:"disabled"}` is an API 400 (`output_config.effort 'xhigh' is not supported
when thinking is disabled on this model`); it took the bot down on 2026-07-28. `effortLevel` is a
*Settings* field, not an `Options` field, so the bot cannot correct it from `query()` — bot code
must stay compatible with whatever the deployment pins. session.ts now defaults to
`thinking: {type:"adaptive"}`, which is accepted at every effort level; `src/session.test.ts`
guards it. Raising effort here is safe as long as thinking is never `disabled`.

Get a valid model identifier from the binary rather than from docs:

```bash
kubectl exec -n claude-telegram <pod> -c claude-telegram -- sh -c \
  'strings -n 8 /app/node_modules/@anthropic-ai/claude-agent-sdk-linux-x64-musl/claude \
   | grep -oE "claude-(opus|sonnet|haiku|fable)-[0-9a-z-]+" | sort -u'
```

## Known drift

Dockerfile `ARG` pins (`KUBECTL_VERSION`, `FLUX_VERSION`) are **not** Renovate-managed and drift
from the cluster. Minor-matched is the accepted policy — check, mention, don't auto-bump.

## Cross-refs

`gitops-workflow` (commit + reconcile) · `homelab-yaml-validate` · `worktree-cleanup`
