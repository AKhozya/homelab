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
with **`steps: 0`**. If jobs have steps, CI is alive —
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

Run step 4's in-image checks unchanged. Then deploy via step 6 without the tag commands.
If you need the reason the CI-built image needs these checks, read reference-build.md § "Why the CI-built image needs the in-image checks".

## 1. Pull the fork FIRST

```bash
git -C /Users/akhozya/source-code/claude-telegram-bot pull
```

Not optional. If you need the reason, read reference-build.md § "Why pull the fork first".

## 2. Host CI replica — all three, in order

```bash
cd /Users/akhozya/source-code/claude-telegram-bot
bun install --frozen-lockfile
bun run typecheck
bun test
```

If you change the Dockerfile or the host build command, read reference-build.md first, section "Why no compile step and why --frozen-lockfile".
That section says why the image has no compile step and why the host run uses `--frozen-lockfile`.

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

If a retry does not clear the `i/o timeout` on the base image: read reference-build.md.

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
- Expect **1 skipped** test in-image (zip fixture; the image has `unzip`, not `zip`).
- **On Apple silicon, `docker run` of this image is QEMU emulation, and its `bun test` result is
  not evidence.** Anything that spawns a process is ~100x slower there, so the MCP stdio tests
  lose their transport and Bun's 5s hook budget expires.

  If you compare an emulated test result with a host or in-cluster run, read reference-build.md,
  section "Emulated vs native test results". It holds the measured results for all three.

  The same two MCP files: **34 failures emulated, 51 pass / 0 fail in the pod in 607ms.** Raising
  the timeout does not fix it — it only converts "47 tests never ran" into "47 tests ran and 34
  failed". Do not chase these, and do not raise timeouts for them.

  **Verify in the cluster instead**, which is real amd64 and takes seconds:

  ```bash
  pod=$(kubectl get pod -n claude-telegram -l app=claude-telegram -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -n claude-telegram "$pod" -c claude-telegram -- sh -c 'cd /app && bun test 2>&1 | tail -6'
  ```

  Run it after the rollout, as the
  post-deploy check — the emulated pre-push run is only good for the SDK/CLI version pair and the
  MCP-config line below, neither of which spawns anything.
  If you need to know whether the in-cluster run is safe, read reference-build.md § "In-cluster test run: safety and cost".
- **Probe the live tool surface.** It spawns the CLI, so run it natively with an authenticated
  environment, never emulated. The gate defaults to deny, so the model cannot call a tool the
  CLI adds.

  If you run the probe, first read reference-tool-surface.md, section "What the probe covers".
  It says what the probe answers for and why the probe uses each option.
  Name the pod you probe: if a rollout is in progress, `.items[0]` can select the outgoing pod.
  Leave `options.tools` unset, and keep `settingSources` the same as in `session.ts`, or the
  probe measures a surface the bot never sees.

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

  If you probe a Renovate SDK PR on a checkout before it deploys, read reference-tool-surface.md § "Probe a checkout".

  Do not pipe either command into `tail`. The pipeline then reports `tail`'s status, so a failed
  probe reports success. Diff the `SURFACE` line against the last run in reference-tool-surface.md, then classify each new
  name in `ALLOWED_BUILTIN_TOOLS` or `DENIED_TOOLS` in `src/security.ts`.

  If the new `SURFACE` line differs from the last run, read reference-tool-surface.md, section
  "Past probe results". It lists past runs, the surfaces they printed, and the claims they refute.
  Read a missing tool name as a property of the environment that produced it, never of the build.
  Record where each probe ran: a surface without its environment answers nothing.
  If you want the reason the surface needs a probe, read reference-tool-surface.md § "Why the surface needs a probe".

- **Read the bot's own tool-gap warning after the rollout.** `session.ts` diffs
  `ALLOWED_BUILTIN_TOOLS` against the init event and logs `Allowed tools not served by the CLI:`
  once per distinct gap. Send the bot one message, then:

  Read the whole log for the current container, not a recent window.

  ```bash
  # `&&` so the search runs only if retrieval succeeds: a failed `kubectl logs` truncates the file,
  # and an unguarded search then reports no gap. `grep -c` prints the count and exits 1 if that
  # count is 0, which stops a `set -e` script.
  kubectl logs -n claude-telegram "$pod" -c claude-telegram > /tmp/bot.log \
    && grep -c 'not served by the CLI' /tmp/bot.log
  ```

  Before you act on the count, read reference-tool-surface.md, section "Tool-gap count: what it
  means".
  If the image predates commit `5f6a200`, a count of `0` does not prove the gap check passed:
  that build has no warning to print.

- **The last command must print `Loaded 2 MCP servers from mcp-config.ts`.** `mcp-config.ts` is
  gitignored, so the Dockerfile copies `mcp-config.example.ts` in as the image default; if that
  breaks, the only symptom is one startup line reading `No mcp-config.ts found` and `ask_user` /
  `send_file` silently do not exist.
  If you need the history of this defect, read reference-build.md § "Why the MCP-config check exists".

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
the tag — `rg -c` should return 3 before and after). Then `/homelab-yaml-validate` and commit.
Merge the version-bump PR:

```bash
~/.agents/skills/_shared/merge-worktree.sh wt-bot-<VERSION> --teardown
```

If the script exits 0 or 3, continue. If it exits with any other code, stop. If it exits 3, fix
the primary tree first (gitops-workflow step 3). The `OK:` line names the merge commit. After
exit 3, read it with `gh pr view <n> --json mergeCommit -q .mergeCommit.oid`. Tag that commit, not the primary
tree's HEAD, because another PR can merge after yours. Push only the tag:

```bash
git -C /Users/akhozya/source-code/homelab -c tag.gpgsign=false \
  tag -a claude-telegram-v<VERSION> -m "claude-telegram <VERSION>" <merge-commit-sha>
git -C /Users/akhozya/source-code/homelab push origin claude-telegram-v<VERSION>
```

If you need the reason for this order, read reference-deploy.md § "Why tag after the merge".
Also note `git -C <repo>` targets the MAIN worktree; commits inside a release worktree need
`git -C <worktree-path>`. Then watch the merge commit's run (gitops-workflow step 3c). If it is GREEN, `flux reconcile` and:

```bash
kubectl rollout status deploy/claude-telegram -n claude-telegram --timeout=480s
kubectl get pod -n claude-telegram -l app=claude-telegram --no-headers
kubectl logs -n claude-telegram -l app=claude-telegram -c claude-telegram --tail=15
```

Healthy log ends with `Bot started: @ClaudeSelfHostedBot` and the loopback trigger listening.

**Budget ~6-7 min for the rollout, and do not read a `rollout status` timeout as a failure.**
Read `kubectl logs -c chezmoi-init`
before intervening. If those logs stop advancing, treat it as stuck.
If you need the measured rollout timing, read reference-deploy.md § "Rollout timing".

Finish with `worktree-cleanup` — `--repo` takes a PATH, not a repo name
(`--repo homelab` exits 3 `not a git repo`).

## Model and effort

Set in `deployment.yaml`, not in the fork.

- **`ANTHROPIC_MODEL`** pins the model and overrides `~/.claude/settings.json` (verified against
  CLI 2.1.220). `CLAUDE_CODE_DEFAULT_MODEL` was **inert** — no consumer in the CLI, SDK or bot —
  and has been removed. Do not reintroduce it.
- **`CLAUDE_CODE_EFFORT_LEVEL`** pins effort.

**Effort and thinking are coupled — check both before changing either.** `effortLevel: "xhigh"`
with `thinking: {type:"disabled"}` is an API 400 (`output_config.effort 'xhigh' is not supported
when thinking is disabled on this model`); it took the bot down on 2026-07-28. `effortLevel` is a
*Settings* field, not an `Options` field, so the bot cannot correct it from `query()` — bot code
must stay compatible with whatever the deployment pins. session.ts now defaults to
`thinking: {type:"adaptive"}`, which is accepted at every effort level; `src/session.test.ts`
guards it. Raising effort here is safe as long as thinking is never `disabled`.
If you need the background or a valid model identifier, read reference-deploy.md § "Model and effort background" and § "Get a valid model identifier".

## Known drift

Dockerfile `ARG` pins (`KUBECTL_VERSION`, `FLUX_VERSION`) are **not** Renovate-managed and drift
from the cluster. Minor-matched is the accepted policy — check, mention, don't auto-bump.

## Cross-refs

`gitops-workflow` (commit + reconcile) · `homelab-yaml-validate` · `worktree-cleanup`
