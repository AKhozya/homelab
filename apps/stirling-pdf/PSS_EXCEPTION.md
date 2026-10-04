# Stirling PDF Security Configuration

## Pod Security Standards Classification: BASELINE

**Rationale:** the container starts as root and its entrypoint drops to unprivileged users. `deployment.yaml` pins `frooodle/s-pdf:3.0.2-fat`. This page describes that image, read from the upstream source at tag `v3.0.2` on 2026-10-04. The image pins its base image `1.0.6` by digest, so the base-image facts come from the tag's `docker/base/Dockerfile`, which may be newer than that build; the live log below matches them.

The Kyverno policies `require-non-root` and `require-readonly-rootfs` exclude this namespace (`infrastructure/configs/kyverno-policies/`).

---

## Why the Container Starts as Root

Upstream builds the `-fat` image from `docker/embedded/Dockerfile.fat` on top of `stirlingtools/stirling-pdf-base:1.0.6`. Neither Dockerfile sets `USER`, so the entrypoint (`tini -- /scripts/init.sh`, which runs `/scripts/init-without-ocr.sh` with `exec`) runs as UID 0. Spring Boot serves the frontend itself; the image has no nginx.

The entrypoint does these steps as root:

| Step | `init-without-ocr.sh` at v3.0.2 | Needs |
|---|---|---|
| Remap `stirlingpdfuser` and `stirlingpdfgroup` to `PUID`/`PGID` (both default to 1000) with `usermod -o`/`groupmod -o` | lines 1248–1259 | root, writable `/etc/passwd` and `/etc/group` |
| `chown -R` the app paths to `stirlingpdfuser`: `$HOME`, `/logs`, `/scripts`, `/configs`, `/customFiles`, `/pipeline`, `/storage`, `/tmp/stirling-pdf`, `/usr/share/fonts/truetype`, `/opt/stirling-engine/data` | lines 1266–1279 | `CHOWN` |
| Create LibreOffice's profile, temp and XDG directories inside `/var/lib/libreoffice-sandbox`, which the base image owns as `stirlingofficeuser` with mode 700 | lines 1328–1336 | root that can write into another user's 700 directory |
| Start Java and the bundled AI engine as `stirlingpdfuser` with `setpriv --reuid --regid --init-groups` | lines 1423–1450 | `SETUID`, `SETGID` |
| Start LibreOffice as a second user, `stirlingofficeuser` (UID 1100), inside `lo-sandbox` (Landlock and seccomp) | `resolve_office_user`, lines 278–292; `run_as_office_user`, lines 294–311 | root and `setpriv` |

The 2026-10-03 pod log confirms the two-user split is active: `LibreOffice sandbox mode=enforce user=stirlingofficeuser` and `LibreOffice sandbox active (lo-sandbox: landlock ABI 7, seccomp active)`.

The same log shows `XDG_RUNTIME_DIR=/tmp/xdg-1001`. The entrypoint builds that path from `id -u stirlingpdfuser` before the remap and overwrites any inherited value (lines 1215–1227). So `stirlingpdfuser` has UID 1001 in the image. `deployment.yaml` sets no `PUID`. So the image default `PUID=1000` (`Dockerfile.fat`) differs from 1001, and the entrypoint runs `usermod -o -u 1000` on every start.

### Why the Root Filesystem Stays Writable

The entrypoint writes to these root-filesystem paths, and `deployment.yaml` mounts no volume over them:

| Path | Written by |
|---|---|
| `/etc/passwd`, `/etc/group` | the `PUID`/`PGID` remap |
| `/usr/share/tesseract-ocr/5/tessdata` | `init.sh`, which copies the languages from the `/usr/share/tessdata` PVC there |
| `/var/lib/libreoffice-sandbox` | the LibreOffice profile setup |
| `/storage`, `/opt/stirling-engine/data` | the `mkdir`/`chown` steps |

### Upstream Issue

[#1516 — Running Stirling-PDF in docker with --user (rootless, unprivileged)](https://github.com/Stirling-Tools/Stirling-PDF/issues/1516) is open, labelled `enhancement` (checked 2026-10-04).

---

## Security Posture

### Capabilities

```yaml
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: false
  capabilities:
    drop: ["ALL"]
    add: ["SETGID", "SETUID", "CHOWN", "DAC_OVERRIDE"]
```

| Capability | Used by |
|---|---|
| `SETUID`, `SETGID` | `setpriv`, which drops Java, the AI engine and LibreOffice to their users |
| `CHOWN` | the `chown -R` of the app paths |
| `DAC_OVERRIDE` | lets root write into directories other users own, such as `/var/lib/libreoffice-sandbox` (mode 700). This page has not checked whether any other 3.0.2 step needs it |

### Pod Security Standards

**Classification:** BASELINE (not RESTRICTED)

**PSS Violations from Restricted:**
- `runAsNonRoot: true` — not set, because the entrypoint starts as root
- `capabilities.add` — Restricted allows only `NET_BIND_SERVICE`; the container adds `SETGID`, `SETUID`, `CHOWN` and `DAC_OVERRIDE`

`readOnlyRootFilesystem` is not a Pod Security Standards control. The Kyverno policy `require-readonly-rootfs` requires it, and its exclusion of this namespace covers the writes listed above.

**PSS Compliance with Baseline:**
- `allowPrivilegeEscalation: false`
- `capabilities.drop: ["ALL"]`, then the four above added back, all within baseline
- `seccompProfile: RuntimeDefault`
- No `hostNetwork`, `hostPID`, `hostIPC`, `hostPath` volumes or privileged containers

### Additional Mitigations

| Control | Setting |
|---|---|
| NetworkPolicy ingress | port 8080 from the Traefik, Cloudflare Tunnel and Uptime Kuma namespaces |
| NetworkPolicy egress | DNS, and TCP 443 at any destination; `networkpolicy.yaml` lists what uses it |
| Resource limits | CPU and memory limits prevent exhaustion |
| Service account | own ServiceAccount, with no API token mounted |
| TLS | the Traefik ingress serves a Let's Encrypt certificate |

---

## Risk Assessment

**Risk Level:** MEDIUM

**Attack Surface:**
- The entrypoint runs as root (UID 0); Java, the AI engine and LibreOffice do not
- Writable filesystem allows file modifications
- If an attacker gains control of the entrypoint, they have root within the container

**Mitigations:**
- the controls above: NetworkPolicy, four capabilities, seccomp, no host access
- LibreOffice, which parses untrusted documents, runs as its own user inside Landlock and seccomp
- security updates via Renovate

**Acceptable Trade-off:** the entrypoint needs root, and these controls reduce the risk to an acceptable level for a homelab.

---

## Open Items

1. **Non-root start is untested.** The 3.0.2 entrypoint has fallbacks for a non-root start, so it may run with `runAsUser` set:

   | Step | Behaviour if the container starts as non-root |
   |---|---|
   | `run_as_runtime_user` (lines 254–267) and the Java start (lines 1439–1450) | logs `Unable to switch to user` and runs as the current user |
   | `resolve_office_user` (lines 287–290) | logs `Cannot switch to stirlingofficeuser`; LibreOffice shares the runtime user |
   | UID/GID remap and `chown` (lines 1248–1279) | skipped or failure ignored |
   | `lo-sandbox` | still applies, because Landlock and seccomp with `PR_SET_NO_NEW_PRIVS` need no privilege |

   The costs:

   | Cost | Why |
   |---|---|
   | LibreOffice no longer runs as a separate user | `resolve_office_user` needs root |
   | the copy into `/usr/share/tesseract-ocr/5/tessdata` fails silently, so the PVC's OCR languages may go missing | the image never makes that directory writable by `stirlingpdfuser` |
   | `runAsUser: 1000` would not run as `stirlingpdfuser` | in the image `stirlingpdfuser` is UID 1001, and 1000 belongs to another user |

   Test before changing `deployment.yaml`.

2. **Watch upstream:** [#1516](https://github.com/Stirling-Tools/Stirling-PDF/issues/1516).

---

## References

- Upstream source at `v3.0.2`: `docker/embedded/Dockerfile.fat`, `docker/base/Dockerfile`, `docker/base/lo-sandbox.c`, `scripts/init.sh`, `scripts/init-without-ocr.sh`
- [GitHub Issue #1516 — Rootless execution](https://github.com/Stirling-Tools/Stirling-PDF/issues/1516)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)

---

**Last Updated:** 2026-10-04 (against image 3.0.2-fat)
**Next Review:** at the next major image version change, or when #1516 closes
