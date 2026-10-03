# Tool surface probe: facts and results

Read this when you run the tool-surface probe or the tool-gap log check and need to interpret the output.

## What the probe covers

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

## Past probe results

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

## Tool-gap count: what it means

  | Result | Meaning |
  | --- | --- |
  | `0` | Every allowed tool is served |
  | Non-zero | Run `grep 'not served by the CLI' /tmp/bot.log` to see which tools are missing |
  | Image built before commit `5f6a200` (2026-09-16) | `0` proves the command runs, not that the gap check passed. The warning does not exist in that build |
  | `WebFetch, WebSearch` named | Correct on the macOS standalone, because settings deny both there |

### The `Allowed tools not served by the CLI:` log line

The bot logs the line once per distinct gap per process, so a later message does not repeat a gap it already reported.
That line detects a rename: if the CLI does not know a name in `options.tools` it drops that name without a diagnostic.

## Why the surface needs a probe

The surface probe in SKILL.md step 4 (build amd64 and verify inside the image) spawns the CLI,
so it needs native execution and an authenticated environment.
The gate defaults to deny, so the model cannot call a tool that a new CLI version adds, and
nothing reports that such a tool exists, so the surface needs a periodic read.
Nothing hermetic can produce it: the CLI binary arrives at install time, and reading its surface
needs auth and a spawn.

## Probe a checkout

On a checkout, for a Renovate SDK PR before it deploys:

```bash
SDK_MANIFEST=$PWD/node_modules/@anthropic-ai/claude-agent-sdk/manifest.json bun run /tmp/tool-surface.ts
```

If you pipe this command anywhere, first read SKILL.md step 4 for the rule on `tail`.
