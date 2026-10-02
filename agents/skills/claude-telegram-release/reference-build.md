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

  | where | result |
  |---|---|
  | host (arm64, native) | 526 run · 526 pass / 0 fail · 24s |
  | in-image via `docker run --platform linux/amd64` | 479 run · **4-6 fail** · 74-93s |
  | in-image, hook budget raised so the aborted files run | 526 run · **23+11 fail** (`Not connected`) · 105s |
  | **in-cluster `kubectl exec` (real amd64)** | **526 run · 525 pass / 1 skip / 0 fail · 22s** |
