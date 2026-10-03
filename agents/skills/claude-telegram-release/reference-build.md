# Build background and troubleshooting

Read this when a local build stalls, when emulated test results look wrong, or when you need the reason behind a build step.

## Why no compile step and why --frozen-lockfile

No compile step: `package.json` has no `build` script and the image runs `src/index.ts`
directly. `bun build --compile` belongs to the ClaudeBot macOS wrapper, not this release.

`--frozen-lockfile` here, deliberately: it proves the committed lockfile is what CI would
resolve. The Dockerfile uses `bun update` instead, so the image can float **past** the lock —
which is exactly why step 4's in-image run is the authoritative one.

## BuildKit metadata stall

A retry does not always clear it. On 2026-08-13 two builds in a row died on the same line —
`failed to resolve source metadata for docker.io/oven/bun:1.3-alpine ... dial tcp 98.84.245.6:443:
i/o timeout` — while `docker run alpine:3` pulled fine and reached the same registry from inside
the VM. BuildKit's metadata HEAD is the part that hangs, not egress. Pull the base image by hand,
then rebuild; the build then reads it from the local store and completes:

```bash
docker pull --platform linux/amd64 oven/bun:1.3-alpine
```

## Emulated vs native test results (2026-08-07)

Measured 2026-08-07 on an M-series Mac:

  | where | result |
  |---|---|
  | host (arm64, native) | 526 run · 526 pass / 0 fail · 24s |
  | in-image via `docker run --platform linux/amd64` | 479 run · **4-6 fail** · 74-93s |
  | in-image, hook budget raised so the aborted files run | 526 run · **23+11 fail** (`Not connected`) · 105s |
  | **in-cluster `kubectl exec` (real amd64)** | **526 run · 525 pass / 1 skip / 0 fail · 22s** |

## Skipped zip-fixture test in the image

On the host it passes, so host and image totals differ by one by design.

## CI jobs with zero steps

A billing block creates runs, then every job dies with `steps: 0`. That zero-step count is
the fastest tell.

## Why the CI-built image needs the in-image checks

They matter MORE on this path, not less: the missing `mcp-config.ts` defect was CI-build-specific
(a local build masks it with the developer's own config), so a CI-built image is exactly the one
to verify.

## Why pull the fork first

Renovate lands "Lock file maintenance" PRs on the fork, and **the lockfile is what
moves the Agent SDK**. If you build without pulling, the build installs the older SDK. The surface
probe then reports that version, so it does not validate the updated dependency.

## In-cluster test run: safety and cost

Non-destructive: `test-preload.ts` redirects `AUDIT_LOG_PATH` and `TEMP_DIR`, and the MCP tests
use a chat id no real chat has. It costs the pod ~22s of CPU.

## Why the MCP-config check exists

Verified absent in both the 1.30.0 and 1.30.1 images (how
far back it goes was not checked). It went unnoticed because a *local* build picks up the
developer's own `mcp-config.ts` and looks fine, while a CI build has none — and neither the
suite nor the surface probe covers it.
