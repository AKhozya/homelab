# Homelab Ultrareview — 2026-05-23

Multi-agent consensus review of `main` branch. 4 reviewers in parallel: architect, K8s/Flux DevOps, security, code-reviewer.

**Scope:** architecture soundness, Kustomize idioms, folder hierarchy, tool stack, optimization, cut corners.

**Cluster facts (verified by recount, not from `HOMELAB_ANALYSIS.md`):**
- 16 apps, 13 HelmReleases, 31 NetworkPolicy files (40 resources — multi-doc), 11 Kyverno policies, 53 SOPS-encrypted files
- Flux v2.8.8, K3s staging single env, 1 CP + 2 workers
- 456 YAML files / 724 total / ~3.4 MB content

---

## Verdict

**APPROVE with backlog.** No P0/CRITICAL operational blocker. One credential-adjacent leak (Cloudflare account+tunnel UUID in plaintext) needs immediate attention. Architecture is structurally sound; debt is concentrated in:

1. **Doc/policy drift** — `HOMELAB_ANALYSIS.md` overstates Kyverno enforcement and NP count
2. **Three Kyverno policies in Audit-only** — invariants documented but not enforced
3. **Empty staging passthroughs** — ~11 `kustomization.yaml` files that do `resources: [../base]` and nothing else
4. **Monitoring stack lacks `dependsOn`/`healthChecks`** in Flux Kustomizations
5. **Missing CI guards** — no `kubeconform`, no `yamllint`, no SOPS-encryption check, no `shellcheck`

---

## What Works (consensus across 4 agents)

| Area | Evidence |
|---|---|
| GitOps spine | Flux v2.8.8, `prune: true` everywhere, SOPS on every Kustomization needing secrets |
| Helm where it earns its keep | 13 HelmReleases for operators/controllers; raw manifests for CRs the operators produce |
| Image pinning | All apps use `major.minor.patch`. `disallow-latest-tag` Kyverno + Renovate manage drift |
| Backup CronJobs | `concurrencyPolicy: Forbid`, `ttlSecondsAfterFinished`, history limits, staggered schedules (03:00→03:30) |
| Per-pod NetworkPolicies | Specific `podSelector` not namespace-wide shotgun |
| Resource governance | ResourceQuotas + LimitRanges per-namespace, tiered (small/medium/large) |
| Renovate config | Groups Flux/Prometheus/Traefik; major waits 3 days; custom managers for n8n + CNPG `imageName` |
| SSO/security headers | Authentik forward-auth + HSTS + CSP middleware on all 13 internal-facing apps |
| Per-app DB user pattern (where used) | `apps/staging/blocky/` owns its `db-user.yaml` + `cnpg-database.yaml` |
| Kube-prometheus-stack HelmRelease | Reference-quality: `driftDetection: enabled`, `rollback.cleanupOnFail`, `upgrade.remediation`, `crds: CreateReplace` |

---

## Findings

Severity scale: **P0 Critical / P1 High / P2 Medium / P3 Low**.

### P0 — Critical

**F-1 — Cloudflare account ID + tunnel UUID in plaintext YAML**
`infrastructure/configs/staging/cloudflare/cloudflared.yaml:53-54`

```
ACCOUNT="***REMOVED-CF-ACCOUNT-ID***"
TUNNEL="***REMOVED-CF-TUNNEL-UUID***"
```

Embedded in initContainer shell script (`command:` field). `.sops.yaml` `encrypted_regex: ^(data|stringData)$` does NOT cover `command:`. Anyone with repo read can enumerate Cloudflare account + tunnel. Account ID alone is low value; combined with leaked tunnel UUID can enumerate public hostnames via Cloudflare API.

**Fix:** Move both to Secret stringData (SOPS-encrypted) and reference via env vars in initContainer.

---

### P1 — High

**F-2 — 3 of 10 Kyverno policies are Audit-only, contradicting `HOMELAB_ANALYSIS.md`**

| Policy | File | Action |
|---|---|---|
| `disallow-host-path` | `infrastructure/configs/base/kyverno-policies/disallow-host-path.yaml:14` | Audit |
| `require-non-root` | `require-non-root.yaml:14` | Audit |
| `require-resource-limits` | `require-resource-limits.yaml:14` | Audit |

`HOMELAB_ANALYSIS.md:24` claims "10 Kyverno policies (7 enforce, 3 audit)" — doc is honest about count, but text elsewhere says "100% PSS, NetworkPolicy, HSTS, SSO, image-pin coverage" which is read as "all enforced." Reality: hostPath, root-running, and resource-limits are warn-only.

**Fix:** Promote each to Enforce. Existing `exclude:` blocks already carve out exceptions (`mealie`, `home-assistant`, `pricebuddy`, `stirling-pdf`, `loki`, `backup-replication`).

**Enforce safety scan (2026-05-23):** Audited all 16 apps for root indicators. Only **paperless-ngx** breaks Enforce:
- `apps/base/paperless-ngx/deployment.yaml:32-38` — `fix-permissions` init runs `chown -R 1000:1000 /run` with `runAsUser: 0, runAsNonRoot: false`.
- **s6-overlay** (paperless's init system) requires `/run` owned by app UID. Prior incident (HOMELAB_HISTORY, commits ca3891c → 7f12be2 → 8162673 → d3b5036): removing init → `CrashLoopBackOff: /run belongs to uid 0 instead of 1000`. fsGroup migration failed because s6 modifies `/run` perms post-mount.
- **Action:** Add `paperless-ngx` to `require-non-root.yaml` exclude list with comment `# s6-overlay /run permission init — see HOMELAB_HISTORY 2026-05-23`. fsGroup migration NOT viable.

**Other apps verified non-root and will NOT break Enforce:**
- claude-telegram: already pod-level `runAsUser/Group/fsGroup: 1000`. Baseline PSS reason is missing `readOnlyRootFilesystem`, NOT root. See F-39.
- All restricted-PSS apps: clean.

**F-3 — `require-resource-limits` does not cover `initContainers`**
`infrastructure/configs/base/kyverno-policies/require-resource-limits.yaml:34-39, 56-62`

Pattern only validates `spec.containers[*]`. `CLAUDE.md` hard-invariant says "all containers (init included)." A noisy init (apt/pip install) with no limits can starve nodes.

**Fix:** Extend pattern to `spec.initContainers[*]`. Use `=(initContainers):` so apps without init still pass.

**F-4 — `disallow-privilege-escalation` and `require-drop-all-capabilities` use optional `=()` patterns**
`disallow-privilege-escalation.yaml:36-41`, `require-drop-all-capabilities.yaml:36-45`

`=(allowPrivilegeEscalation): false` and `=(capabilities): =(drop): [ALL]` are validated *only when present*. A container omitting these fields silently passes. Linux default for `allowPrivilegeEscalation` when unset is `true`.

**Fix:** Replace with mandatory `deny` conditions (`operator: NotEquals` block).

**F-5 — No Kyverno policy enforces NetworkPolicy presence per namespace**
`infrastructure/configs/base/kyverno-policies/` — 11 policies present. None ensure every new namespace ships with a NetworkPolicy.

`CLAUDE.md` invariant: "Every ingress = NetworkPolicy." Currently maintained by hand. New app deployed without NP is not blocked.

**Fix:** Add `require-networkpolicy.yaml` ClusterPolicy that asserts at least one NP exists per `apps/*` namespace, or generate a default-deny NP via `generate:` rule.

**F-6 — No Kyverno policy enforces `readOnlyRootFilesystem`**
`CLAUDE.md` invariant. Not in any of 11 policies. `pricebuddy` runs `readOnlyRootFilesystem: false` on all 3 containers — manual review is the only gate.

**Fix:** Add `require-readonly-rootfs.yaml` policy (start Audit, then Enforce). Mutate-then-validate pattern works for default-true.

**F-7 — `monitoring-controllers` / `monitoring-configs` missing `dependsOn` + `healthChecks`**
`clusters/monitoring.yaml:1-31`

Both Kustomizations have no `dependsOn`, no `healthChecks`, no `retryInterval`. Documented chain says `infrastructure-controllers → infrastructure-configs → monitoring-controllers → monitoring-configs`. Reality: monitoring runs parallel.

On fresh cluster bootstrap or post-incident replay, KPS + VM operator can race cert-manager + Kyverno admission webhook init. Currently invisible because cluster has been up.

**Fix:**
```yaml
# monitoring-controllers
dependsOn: [{name: infrastructure-controllers}]
retryInterval: 2m
healthChecks:
  - {apiVersion: apps/v1, kind: Deployment, name: kube-prometheus-stack-operator, namespace: monitoring}
  - {apiVersion: apps/v1, kind: Deployment, name: vm-operator, namespace: monitoring}
---
# monitoring-configs
dependsOn: [{name: monitoring-controllers}]
retryInterval: 2m
healthChecks:
  - {apiVersion: operator.victoriametrics.com/v1beta1, kind: VMSingle, name: vmsingle, namespace: monitoring}
```

**F-8 — `apps` Flux Kustomization has `wait: false` AND `healthChecks` — contradiction**
`clusters/apps.yaml:9, 13-17`

`wait: false` marks Kustomization Ready as soon as `apply` succeeds. The `healthChecks` block on `main-postgres` CNPG Cluster is dead config — never gates anything.

**Fix:** Drop the `healthChecks` block, OR remove `wait: false` and raise `timeout: 45s → 5m`. Pick one. Recommend dropping the dead check (intent: avoid blocking on slow Immich pulls).

**F-9 — `apps/base/immich/networkpolicy.yaml:107-112` — allow-all egress on 443 with no RFC1918 exclusion**
Every other `0.0.0.0/0` egress in the repo (cert-manager, backup-replication) excludes RFC1918. Immich's ML-model-download egress does not. A compromised ML container can reach cluster-internal services.

**Fix:** Add `except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16]`.

**F-10 — `uptime-kuma` egress allows unrestricted access to all DB ports cluster-wide**
`apps/base/uptime-kuma/networkpolicy.yaml:46-94`

`namespaceSelector: {}` (all namespaces) + ports 5432/3306/6379/26379/9090 etc. Uptime-Kuma can directly probe DB primaries. If compromised → DB enumeration in any namespace.

**Fix:** Restrict DB-port rules to `namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: databases}}`.

**F-11 — `n8n` egress allows unrestricted HTTPS to internet**
`apps/base/n8n/networkpolicy.yaml:64-67` — no `to:` selector on 443.

n8n is exposed via Cloudflare Tunnel. Workflow engine + arbitrary outbound = data-exfiltration vector if compromised or malicious workflow added. Partially by-design (n8n calls third-party APIs) but tighter than current.

**Fix:** Acknowledge or add RFC1918 except + audit workflow-creation flow.

**F-12 — `claude-telegram` egress allows SSH (port 22) and HTTP (port 80) to any IP**
`apps/base/claude-telegram/networkpolicy.yaml:29-33`

Combined with broad RBAC (`pods/exec`, `jobs create`, `pods delete`), a compromised bot = lateral movement to any SSH host + plaintext exfil over 80.

**Fix:** Drop port 22 entirely (bot does not SSH from inside cluster). Restrict 80 to specific upgrade-check IPs or drop.

---

### P2 — Medium

**F-13 — `apps/staging/<app>/kustomization.yaml` is passthrough+secrets for all 16 apps**
Verified sample: blocky, uptime-kuma, homepage, homehub. No `patches`, no `images:`, no `replicas:`, no `namePrefix`. Just `resources: [../../base, <some-sops-secret>.yaml]`.

Not strictly wrong — SOPS-encrypted resources are cluster-specific and must live outside `base/`. But documentation in `CLAUDE.md` calls this an "overlay," which it is not (no overrides). Confuses future readers.

**Fix options:**
- (a) Collapse to single `apps/<app>/` with secrets co-located (1-env repo today)
- (b) Rename `staging/` → `cluster-bound/` or document the SOPS-injection pattern in `CLAUDE.md`

Recommend (b) — keep structure for future `prod/`, document the actual purpose.

**F-14 — Monitoring/infra staging passthroughs are dead layers**
- `infrastructure/controllers/staging/kustomization.yaml` → just `[../base]`
- `monitoring/controllers/staging/{loki-stack,popeye,victoria-metrics}/kustomization.yaml` → just `[../../base/<name>]`
- `monitoring/configs/staging/victoria-metrics/kustomization.yaml` → same

**Fix:** Delete the passthroughs. Point Flux Kustomization at `./base/` directly OR list base paths in the parent staging kustomization. ~6 files deleted, zero behavior change.

**F-15 — DB user ownership is inconsistent** — ✅ **DONE 2026-05-27** (`002e06f7`, direction inverted after research)
- `apps/staging/blocky/` was app-owned (`cnpg-database.yaml` + `blocky-db-user.yaml`); the other 6 (authentik/immich/linkwarden/mealie/n8n/paperless) lived in `infrastructure/configs/staging/databases/postgres/`. Half-and-half.

**Resolution — original "make all app-owned (blocky pattern)" was backwards.** CNPG `Database.spec.cluster` is a `LocalObjectReference`, so every `Database` CR must sit in ns `databases` (where `main-postgres` lives). 4 of 7 apps (immich/linkwarden/mealie/paperless-ngx) set `namespace: <app>` in their staging kustomization → kustomize would rewrite the moved CR's ns and break the cluster ref. Flux canonical also treats DB provisioning as infrastructure (apps `dependsOn` it). So the consistent + ns-correct fix is the inverse: moved blocky's 2 files → `infrastructure/configs/staging/databases/postgres/` (rename `cnpg-database.yaml`→`blocky-database.yaml`). All 7 now in one canonical infra dir. Handoff verified clean — `databaseReclaimPolicy: retain` + Flux GC label-protection meant the same CR object was adopted by `infrastructure-configs` (applied=true, AGE 31d preserved, never re-created); blocky pods unaffected.

**F-16 — 12 of 13 HelmReleases missing `driftDetection: { mode: enabled }`**
Only `monitoring/controllers/base/kube-prometheus-stack/release.yaml:30-31` has it. Without it, `kubectl edit` against Helm-managed resources persists until next chart upgrade.

**Fix:** Add to remaining 12. ~10 LOC × 12 = ~120 lines.

**F-17 — Most HelmReleases lack explicit `timeout`**
Default 5m. Loki, KPS, cert-manager, couchdb regularly exceed on slow worker disks → spurious upgrade-retries.

**Fix:** `spec.timeout: 10m` on KPS, loki, cert-manager, couchdb.

**F-18 — 5 HelmReleases missing `rollback: { cleanupOnFail: true }`**
mysql, redis-operator, traefik, vm-operator, immich. Orphan ConfigMap/Secret accumulation referenced in `cluster-stale-cleanup` skill is a symptom.

**Fix:** Add `rollback: { cleanupOnFail: true }`.

**F-19 — `claude-telegram` namespace has no ResourceQuota**
`apps/base/claude-telegram/namespace.yaml` exists; no corresponding entry in `infrastructure/configs/staging/resource-governance/small-tier/`. Breaks "100% namespace quota coverage" claim.

**Fix:** Add `claude-telegram.yaml` to `small-tier/`.

**F-20 — HelmRelease interval inconsistent**
- `mysql/helmrelease.yaml:7` → `interval: 30m`
- `redis-operator/release.yaml:7` → `interval: 30m`
- Everyone else → `6h`

`30m` = 12× API server hits for nothing. Renovate handles version bumps.

**Fix:** Standardize at `6h`.

**F-21 — HSTS missing `includeSubDomains; preload`**
`infrastructure/controllers/base/traefik/security-headers-middleware.yaml:18` — `max-age=31536000` only.

**Fix:** `Strict-Transport-Security: "max-age=31536000; includeSubDomains; preload"`.

**F-22 — Global CSP allows `unsafe-inline 'unsafe-eval'` on `script-src`**
`infrastructure/controllers/base/traefik/csp-middleware.yaml:13`

One CSP applied to all 16 apps. Negates XSS protection. Some apps genuinely need it (SPAs), others do not.

**Fix: 3-tier per-app middleware (researched 2026-05-23):**

| Tier | Middleware | `script-src` | Apps |
|---|---|---|---|
| **A strict** | `csp-strict` | `'self'` | paperless-ngx (Angular AOT); blocky, claude-telegram, obsidian (no UI) |
| **B inline** | `csp-inline` | `'self' 'unsafe-inline'` | authentik, homepage, linkwarden, mealie, n8n, homehub, stirling-pdf, audiobookshelf |
| **C permissive** | `csp-permissive` | `'self' 'unsafe-inline' 'unsafe-eval'` | home-assistant (HACS `new Function()`), immich (+wasm + gstatic, Issue #23389), pricebuddy (Filament+Livewire), uptime-kuma (Vue runtime compiler, GH #3806) |

**Rollout (Report-Only first):**
1. Create 3 Middlewares in `traefik` ns. Each carries BOTH `Content-Security-Policy-Report-Only: <proposed>` AND `Content-Security-Policy: <current permissive>` (observe + enforce simultaneously).
2. Swap each ingress annotation from global `csp` to tier-specific.
3. Watch `csp-reporter` Loki logs per app 7d: `{app="csp-reporter"} |= "<domain>"`.
4. Zero violations 48h → flip strict from Report-Only to enforced, drop permissive header.
5. Tier C apps skip step 3 — direct enforced.
6. Rollback = revert ingress annotation (1 line).

**File touch:** `infrastructure/controllers/base/traefik/csp-middleware.yaml` (add 3) + each `apps/base/<app>/ingress*.yaml` (swap annotation).

**F-23 — `claude-telegram-bot:1.22` and `seleniumbase-scrapper:v1.0` are major.minor only**
- `apps/base/claude-telegram/deployment.yaml:36,147,215` → `1.22`
- `apps/base/pricebuddy/deployment.yaml:143` → `jez500/seleniumbase-scrapper:v1.0`

Violates `major.minor.patch` invariant. `disallow-latest-tag` Kyverno does not catch short semver. Both tags are mutable.

**Fix:** Pin patch. claude-telegram is your own image — bump tagging scheme.

**F-24 — `pricebuddy` runs apprise sidecar as root with 5 elevated caps**
`apps/base/pricebuddy/deployment.yaml:172-179` — `runAsUser: 0`, `runAsNonRoot: false`, caps add: CHOWN, SETUID, SETGID, DAC_OVERRIDE, FOWNER. Excluded from `require-non-root` via namespace exclusion. PSS `baseline`.

**Fix:** Investigate apprise non-root image variant. If needed, narrow the cap set; SETUID+SETGID+DAC_OVERRIDE on a root sidecar is effectively privileged.

**F-25 — `home-assistant` and `immich` namespaces at PSS `privileged` audit+warn**
Both set `enforce: privileged, audit: privileged, warn: privileged`. Privileged is intentional for GPU/hardware passthrough; `audit/warn: privileged` means no signal on unexpected privilege uses.

**Fix:** Set `audit: baseline, warn: baseline` to surface drift without breaking the privileged pods.

**F-26 — Renovate `pinDigests: false` + `"schedule": ["at any time"]`**
`renovate.json:97-103, 158-160`. PR queue can burst mid-day.

**Fix:** Schedule outside business hours. Consider `automerge: true` for `patch` updates on low-risk apps.

**F-27 — Setup script missing `set -u` / `pipefail`**
`docs/scripts/setup-node.sh:18` — only `set -e`. Every other script in repo uses `set -euo pipefail`. Runs as root.

**Fix:** Change to `set -euo pipefail`.

**F-28 — `analyze-update.sh:65` — pipe-vs-`||` precedence bug**
```bash
UPDATE_TYPE=$(echo "$PR_TITLE" | grep -iq "major" && echo "major" || echo "$PR_TITLE" | grep -iq "minor" && echo "minor" || echo "patch")
```
Pipe binds tighter than `||`. Logic broken on the "minor" branch. Fallback is "patch" (safe) so impact is low, but it is wrong.

**Fix:** Rewrite as `if/elif/else`.

**F-29 — `claude-telegram-build.yml` force-pushes a version-numbered git tag**
`.github/workflows/claude-telegram-build.yml:82-83` — `git tag -f` + `git push --force` on a non-floating tag. Re-run silently overwrites.

**Fix:** Drop `-f` / `--force`. If re-runs intentional, document.

---

### P3 — Low

- **F-30** No PriorityClasses defined → backups + apps + monitoring compete equally under node pressure
- **F-31** Backup CronJobs missing `startingDeadlineSeconds` and explicit `backoffLimit` (defaults to 6 → 6 retries on broken backup before failure surfaces)
- **F-32** `flux-update.yaml:26` uses `fluxcd/flux2/action@main` (floating). Other actions all pinned to tags
- **F-33** `renovate-analysis.yaml` triggers on all PRs and exits via `if:`; wastes runner minutes (negligible)
- **F-34** `monitoring/configs/staging/blocky/` is only per-app monitoring dir; conflicts with monitoring-lives-with-app pattern elsewhere
- **F-35** Monitoring of databases is split across `monitoring/` and `infrastructure/configs/databases/` (PodMonitor in postgres dir, ServiceMonitor in cloudflare dir). Inconsistent
- **F-36** `prom/mysqld-exporter` + node:24.16.0-alpine pulled from docker.io (library namespace). Prefer ghcr/quay
- **F-37** `uptime-kuma` ingress has no Authentik forward-auth (shared login screen, not SSO)
- **F-38** `disallow-host-namespaces` excludes whole `databases` + `monitoring` namespaces. Should target by workload label, not namespace
- **F-39** `claude-telegram` namespace at PSS `baseline` not `restricted` — actual cause is missing `readOnlyRootFilesystem` on both init + main, not root (pod already runs UID 1000). Both containers mount `home` PVC + `tmp` emptyDir → could enable RoRFS + promote namespace to `restricted`. Verify bot doesn't write outside `/home/akhozya` or `/tmp` first.
- **F-40** `paperless-ngx` fsGroup migration to drop init container — **NOT VIABLE** (s6-overlay modifies /run perms post-mount). Skip. Excluded for documentation.

---

## Drift / Cruft

### Doc Drift
| Claim | Actual | File |
|---|---|---|
| 44 NetworkPolicies | 40 resources (31 files) | `docs/HOMELAB_ANALYSIS.md:24` |
| 17 apps | 16 | `docs/HOMELAB_ANALYSIS.md` (already corrected per memory) |
| "100% PSS coverage" | Immich + Home Assistant privileged | `docs/HOMELAB_ANALYSIS.md:24` |
| "All Kyverno enforce" (implicit) | 3 of 10 in Audit | `docs/HOMELAB_ANALYSIS.md` |

### Cruft to Delete
- 13 `.DS_Store` tracked in git despite `.gitignore` entry — `git rm -f --cached` then commit
- `scripts/analyze-update/baselines/pr-198-baseline.txt` through `pr-208-baseline.txt` — closed-PR snapshots. Delete + gitignore
- `docs/POPEYE_CLUSTER_REPORT.txt` — 7 months stale, superseded by weekly Popeye CronJob
- `docs/superpowers/` — 14 pre-implementation plans/specs for completed work. Move to `docs/archive/` or delete

### Stale Doc Candidates (archive) — ✅ DONE 2026-05-25 (W13-docs)

All 10 `git mv`-d to `docs/archive/` (content preserved, durable conclusions already in CODEMAPS/skills/repo state). Index: [docs/archive/README.md](docs/archive/README.md).
- `archive/KYVERNO_ADDITIONAL_POLICIES_RECOMMENDATIONS.md` — actioned (Wave 8 — 12 policies Enforce)
- `archive/KYVERNO_IMPLEMENTATION_SUMMARY.md` — covered by HOMELAB_ANALYSIS keyfacts
- `archive/NETWORKPOLICY_EGRESS_AUDIT.md` — egress topology in CODEMAPS/networking.md
- `archive/MYSQL_OPERATOR_ANALYSIS.md` — Percona deployed; CODEMAPS/databases.md
- `archive/APP_ALTERNATIVES_RESEARCH.md` — pre-decision research
- `archive/AUTHENTIK_SSO_INTEGRATION.md` — passkey memory + CODEMAPS
- `archive/cloudflare-gateway-setup.md` — setup complete
- `archive/K3S_NETWORKPOLICY_API_ACCESS.md` — ipBlock `10.43.0.1/32` in networkpolicy-helper skill
- `archive/NOTIFICATION_REVIEW.md` — one-time review
- `archive/RENOVATE_UPDATES.md` — superseded by renovate-analysis workflow

### HOMELAB_HISTORY.md Rotation
270 KB / 3537 lines / 123 entries / Oct 2025 → May 2026.

**Strategy:** Freeze pre-2026 entries into `docs/archive/HOMELAB_HISTORY_2025.md`. Rolling 6-month window in main file. Calendar rotate at end of 2026-Q3.

---

## CI Gaps

| Gap | Cost | Risk |
|---|---|---|
| No `yamllint` | Low to add | YAML parse error → silent Flux reconcile failure |
| No `kubeconform` or `flux build kustomization` | Med | Invalid resource fields land in cluster |
| No SOPS encryption check (`grep -rL "ENC\[AES256_GCM" **/*secret*.yaml`) | Trivial | Plaintext secret silently committed |
| No `shellcheck` on `docs/scripts/` | Low | Bash bugs reach prod nodes (would have caught F-27, F-28) |

---

## Top Refactors (highest payoff)

### R1 — Wire `monitoring-controllers` / `monitoring-configs` Flux deps (F-7)
**Effort:** 30 min. **Risk:** Low (worst case: healthCheck typo → NotReady, fix and re-reconcile). **Payoff:** Bootstrap correctness, removes the silent race that has not bitten yet only because cluster has been up.

### R2 — Promote 3 Kyverno policies Audit → Enforce + cover initContainers (F-2, F-3)
**Effort:** 1h (audit policy reports first via `kubectl get policyreport -A`). **Risk:** Low (exclude lists already explicit). **Payoff:** Closes 3 documented invariants. Stops new app from silently regressing.

### R3 — Add `require-networkpolicy.yaml` + `require-readonly-rootfs.yaml` Kyverno policies (F-5, F-6)
**Effort:** 1h each, start Audit, enforce after sweep. **Payoff:** Two documented invariants become real instead of relying on reviewer discipline.

### R4 — Unify app-DB user ownership (F-15) — ✅ DONE 2026-05-27 (`002e06f7`, inverted)
**Done the OTHER way.** "App-owned" is structurally wrong: CNPG `Database.spec.cluster` is a `LocalObjectReference` → CR must be in ns `databases`; 4/7 apps' kustomizations set `namespace:<app>` which would break the ref; Flux canonical treats DB as infra (apps `dependsOn` it). Consolidated blocky's 2 files into `infrastructure/configs/staging/databases/postgres/` — all 7 now infra-owned, one canonical dir.

### R5 — NetworkPolicy Kustomize components — ✅ DONE 2026-05-29 (`6229d4ed` P1, `611b6320` P2)
**Shipped narrower than the brief: only the DNS-egress rule is shareable.** Live read of all 16 per-app NPs showed only `kube-system` UDP-53 egress is byte-identical + parameter-free; Postgres/Redis/HTTPS egress + ingress all vary by port/DB-engine, so a parameter-less component can't cover them without a named-port refactor of every Deployment (rejected — too broad). Created **one** component `apps/base/components/allow-dns-egress/` (egress-only NP, UDP 53 → kube-system), wired into **14** app bases (all except blocky + obsidian), then removed the per-app DNS blocks (−122 LOC).
**Findings:**
- A `podSelector: {}` egress baseline is NOT additive — it isolates the 6 egress-naked provisioning Jobs (audiobookshelf-init, immich-admin-setup, mealie/n8n-user-provision, home-assistant-admin-setup, uptime-kuma-setup) → clamps them DNS-only → breaks on helm-hook re-run. Mitigated: baseline excludes Jobs via `matchExpressions: [{key: batch.kubernetes.io/job-name, operator: DoesNotExist}]` (canonical label on K3s 1.35). True additive.
- **obsidian + blocky excluded.** blocky = specialized DNS (kube-dns podSelector, DoT 853, public resolvers). obsidian = ns-wide `podSelector: {}` NP covering `couchdb-init` Job's DNS; deduping would strip the Job's DNS (baseline excludes Jobs) → break CouchDB resolution.
- **Namespace fix was 2 overlays, not 5.** The nsless component NP needs *some* `namespace:` transformer; home-assistant/n8n/pricebuddy already set it in their **bases**, so only authentik + uptime-kuma needed an overlay `namespace:` (adding to the other 3 = double-declare = build break).
- homehub + linkwarden's meilisearch NPs were DNS-only → now `egress: []` (kept `policyTypes: [Ingress, Egress]`, DNS from baseline). Verified live: both resolve `kubernetes.default`.

### R5-followup — Harden the naked provisioning Jobs — ✅ 4/6 DONE 2026-05-29 (`68dddceb`); 2 deferred
Added 1 tight egress NP per Job (DNS UDP-53→kube-system + the single app container-port), selecting the Job pod by canonical `batch.kubernetes.io/job-name` (R5 baseline excludes Jobs by design, so each carries its own DNS rule). App **ingress** already admitted these Jobs (same-ns `podSelector:{}`, or immich's explicit `app: immich-admin-setup` rule, or HA all-ns) → change is egress-only + symmetric. Live-proved: re-ran `audiobookshelf-init` under its NP → Complete (resolved DNS + reached app:3005, HTTP 500 "already initialized").

| Job | ns | egress NP | target |
|---|---|---|---|
| audiobookshelf-init | audiobookshelf | `audiobookshelf-init-egress` | DNS + app:3005 |
| home-assistant-admin-setup | home-assistant | `home-assistant-admin-setup-egress` | DNS + app:8123 |
| immich-admin-setup | immich | `immich-admin-setup-egress` | DNS + immich-server:2283 |
| n8n-user-provision | n8n | `n8n-user-provision-egress` | DNS + n8n:5678 |

**Deferred (2, accepted residual):** `mealie-user-provision` (python+`apt-get install` curl/postgresql-client) and `uptime-kuma-setup` (python+`pip install uptime-kuma-api`) bootstrap tooling from the **internet at runtime** → any egress NP must open 443/80→0.0.0.0/0 = barely better than naked (theater). Proper fix = bake deps into a pinned custom image (zero-internet Job) → then a tight NP. User declined custom images (2026-05-29), so these 2 stay naked by decision. Revisit only if a custom-image appetite appears.

### R6 — Collapse passthrough `staging/` dirs (F-14) — ✅ DONE 2026-05-29 (`367fc91d`, same as F-14-infra)
Was the F-14 slice. `infrastructure/controllers/staging/kustomization.yaml` (`[../base]` passthrough) deleted + `base/*` hoisted to `infrastructure/controllers/`; dead `controllers/staging/couchdb/` duplicate dropped. See F-14 (infra) row below.

### R7 — Add CI: kubeconform + yamllint + SOPS-check + shellcheck (CI Gaps) — ✅ DONE 2026-05-24 (subsumed by Wave 7)
Stale duplicate of **W7/CI-1**. All 4 gates shipped in `.github/workflows/validate.yaml` (`d65ad41b`, tag `pre-w7-2026-05-24`): `yamllint`, `shellcheck -S error`, SOPS-presence (`check-sops-encrypted.sh`), `kubeconform -strict` × 5 kustomize roots. Plus 3 not in the R7 brief: `init-resources`, `image-pin` (`image-pin-audit.sh`, F-23), `homelab-analysis-drift`. CI = gate-of-record (`/gitops-workflow` 3c blocks `fr` on red). See Wave 7 block below.

---

## Action Backlog

### ⏭ Resume Here — Outstanding work extracted (as of 2026-05-29)

Every partial (`[~]`) and deferred (`[ ]`) item from the waves below, with the **proper fix that remains**. This is the single resume point — wave sections keep the full context.

**Closed since 2026-05-24:** W7/W8 (all 12 Kyverno policies Enforce), housekeeping batch (F-44, W13-hist/docs/mem), F-38 (host-ns excludes narrowed, `a35481fb`), F-45 (PSS privileged-ns audit — closed not-viable, all 6 justified by hostPath/host-ns/GPU/caps, `9fcae542`), F-39 (claude-telegram RoRFS ×3 + runAsNonRoot + PSS restricted, `3c5ce4aa`+`3d080256`), F-37 (won't-do — uptime-kuma internal-only + own 2FA), F-15 (consolidated blocky DB CRs into infra layer, `002e06f7` — direction inverted: CNPG Database CR is ns-bound to cluster, belongs in infra not apps). **F-30 fully closed 2026-05-29** (`85d39527 → 6da41aa7` — 10 commits: critical+std+batch+ps-op-postRenderers+flux-notif-parity; 35 critical + 52 standard + 8 batch templates; zero NULL-priority Running pods). **F-46 closed 2026-05-29** (`1d473d5f` — redis-operator HR full cnpg-parity remediation/maxHistory/rollback.recreate). **F-47 closed 2026-05-29** (`6da41aa7` — flux notification-controller → system-cluster-critical via gotk-components.yaml). **F-48 closed 2026-05-29** (`88a62e50`+`703c61fa` — redis-operator NP; both brief-assumptions wrong: selector `name:` not `app.kubernetes.io/name:`, and operator dials redis pods directly so minimal egress broke role-checks → added redis/sentinel egress). **F-49 closed 2026-05-29** (`208dd218` — monitoring per-pod NP gaps found by the new `np-coverage.sh`: dropped orphan prometheus NP, added kube-state-metrics + prometheus-operator NPs). **F-24 closed 2026-05-29** (`c21b80a8` — pricebuddy apprise sidecar+init non-root: RoRFS, dropped chown caps, /tmp+/plugin+/attach; v1.4.1 already post-#273, no bump; reviewer fsGroup-blocker was a false-positive, refuted live). **F-23 closed 2026-05-29** (`ba65f445`+`693e41a8`+`519ecead` — claude-telegram build→3-component, `:1.24`→`:1.25.0`; seleniumbase `:v1.0` allowlisted, no sha-pin per user; **new hard CI gate `image-pin` runs `scripts/ci/image-pin-audit.sh`** — closes the major.minor-only gap Kyverno misses). **R5 closed 2026-05-29** (`6229d4ed` P1 + `611b6320` P2 — first Kustomize Component in the repo: `allow-dns-egress`, Job-excluded baseline wired into 14 apps, per-app DNS deduped −122 LOC; only DNS was shareable; blocky+obsidian excluded; surfaced R5-followup = 6 naked provisioning Jobs). **R7 closed 2026-05-24** (stale duplicate of W7/CI-1 — all 4 gates already in `validate.yaml` `d65ad41b` + 3 bonus jobs). **R5-followup 4/6 closed 2026-05-29** (`68dddceb` — tight per-Job egress NPs for audiobookshelf-init/home-assistant-admin-setup/immich-admin-setup/n8n-user-provision: DNS + app container-port, `batch.kubernetes.io/job-name` selector; app ingress already symmetric; live-proved via audiobookshelf-init re-run. mealie+uptime-kuma deferred — runtime apt/pip internet egress, no custom-image appetite). **F-13 + F-14 + R6 closed 2026-05-29** — collapsed the base/overlay split for single-env honesty: apps `apps/base+staging/<app>` → flat `apps/<app>` (`b818b17d`+`9179c956`+`181711ec`, 196 renames, render byte-identical, 2-phase prune); infra-controllers `controllers/staging`[../base] → flat `controllers/` + dropped dead `controllers/staging/couchdb` duplicate (`95b87e53`+`367fc91d`). All proven via empty `kustomize build` oracle-diff → zero Flux churn. CI was billing-blocked for F-13-P2/F-14 → local ladder + cavecrew used as gate (user-authorized bypass, out of CI minutes).

**Tooling added 2026-05-29** (pattern: gap-class → a `.sh` closing the gate's blind spot → it finds/gates the instances): `_shared/np-coverage.sh` (per-pod NP coverage — np-gap.sh + Kyverno F-5 are ns-level; wired into /k8s-diagnostics §5) → found F-49; `scripts/ci/image-pin-audit.sh` (semver image-pin, now a CI gate; /homelab-yaml-validate §4c) → drove F-23.

**No open unattended work** — everything below is attended (live verify) or calendar-bound.

**🔵 Next candidates (pick one):**
- **F-22** — CSP enforcement ramp (calendar, ~2wk left). Day-0 middlewares (`971a27d2`). **Tier A swapped 2026-05-31 (`8de095cd`): paperless-ngx + couchdb (obsidian's only web surface — blocky/claude-telegram/obsidian carry no Ingress). csp-strict Report-Only now rides alongside enforced csp; 7d soak started.** Next ~2026-06-07: check `{app="csp-reporter"}` Loki for both domains → clean ⇒ flip strict→enforced, then Tier B (8 apps) → C (4 apps). Revert = 1 annotation line.
- **F-43** — 2026-06-04: check hass-oidc-auth release for Home Assistant compat; enable HA OIDC if shipped.

**🔴 Scheduled / time-bound (do on date):**

| ID | Done so far | Proper fix remaining | Risk | When |
|---|---|---|---|---|
| **F-4** | ✅ **CLOSED 2026-05-25** (`864231ee`) | Operator/privileged excluded (ns databases/immich/percona-mysql + alloy/node-exporter selectors); both policies **Enforce**, 44 pass/0 fail | — | Done |
| **F-5** | ✅ **CLOSED 2026-05-25** (`864231ee`) | **Enforce**, 160 pass/0 fail, no excludes beyond kube-*/default | — | Done |
| **F-6** | ✅ **CLOSED 2026-05-25** (`8a4295f2`+`60f2a2cb`+`864231ee`) | Fixed homehub-init + uptime-kuma-setup (RoRFS+/tmp); excluded operator/privileged/batch ns + alloy/grafana selectors; **Enforce**, 40 pass/0 fail. claude-telegram RoRFS closed via F-39 (`3c5ce4aa`, 2026-05-27) | — | Done |
| **F-22** | Day-0 (`971a27d2`) + **Tier A swapped `8de095cd` 2026-05-31** (paperless-ngx + couchdb=obsidian surface; blocky/claude-telegram/obsidian have no Ingress). 7d Report-Only soak live | **2026-06-07: check `{app="csp-reporter"}` Loki for `paperless.h0melab.work` + `couchdb.h0melab.work`** (clean ≥48h ⇒ flip Tier A strict Report-Only→enforced, drop report-only token); then Tier B (8 apps) → C (4 apps) | Low (revert = 1 annotation line) | **2026-06-07** |
| **F-43** | — | Check hass-oidc-auth releases for HA compat; enable HA OIDC if shipped | Low | 2026-06-04 |

**🟡 Attended (live verification required — do NOT run unattended):**

| ID | Done so far | Proper fix remaining | Why attended |
|---|---|---|---|
| **F-13** | ✅ **DONE 2026-05-29** (`b818b17d`+`9179c956`+`181711ec`). Flattened 16 `apps/base/<app>/`+`apps/staging/<app>/` → `apps/<app>/` (196 git renames); `apps/base/components` → `apps/components`; per-app kustomizations merged (base resources + staging secrets/certs/jobs, `namespace:` set once, components preserved); new top `apps/kustomization.yaml`; Flux `apps` path `./apps/staging`→`./apps`; CI matrix repointed. **Proof:** `kustomize build` render byte-identical pre/post (oracle diff empty) → Flux adopted every object in place, zero churn (verified live: 16 apps Running, no prune events). **2-phase:** P1 prune:false during repoint, P2 (`181711ec`) flip prune:true + renamed 2 misnamed SOPS Secrets (`blocky/configmap.yaml`→`config-secret.yaml`, `stirling-pdf/custom-settings-configmap.yaml`→`custom-settings-secret.yaml`) so `**/*-secret.yaml` yamllint-ignore glob catches them (path-pin had re-broken CI on the move). | — |
| **F-15** | ✅ **DONE 2026-05-27** (`002e06f7`, direction inverted). Research showed "move into apps/" is wrong — CNPG `Database.spec.cluster` is a `LocalObjectReference` so every CR must be in ns `databases`, and 4/7 apps' kustomizations set `namespace:<app>` which would break the ref. Consolidated the OTHER way: moved blocky's 2 files `apps/staging/blocky` → `infrastructure/configs/staging/databases/postgres`. All 7 in one canonical infra dir. Clean ownership handoff (retain + Flux GC label-protection; adopted by infra-configs, applied=true, AGE preserved, blocky pods unaffected). | — |
| **R5** | ✅ **DONE 2026-05-29** (`6229d4ed` P1 + `611b6320` P2). Only DNS-egress was shareable → 1 component `allow-dns-egress` (Job-excluded), wired 14 apps, removed per-app DNS (−122 LOC). 2-overlay namespace fix (authentik+uptime-kuma). blocky+obsidian excluded. homehub+meilisearch→`egress: []`. 14 NPs live, DNS verified across all shapes. Surfaced R5-followup (6 naked Jobs). | — |
| **F-14 (infra)** | ✅ **DONE 2026-05-29** (`95b87e53`+`367fc91d`; monitoring subset was `b442c098`). Collapsed `infrastructure/controllers/staging` (`[../base]` passthrough) → hoisted `base/*` to `infrastructure/controllers/`; Flux path repointed; CI matrix updated. Render byte-identical (oracle diff empty); backbone unaffected (cert-manager-webhook/kyverno-admission/traefik 2/2). **couchdb wiring traced:** `controllers/staging/couchdb/secret.yaml` (Secret `couchdb-couchdb`) was a **dead duplicate** — referenced by nothing, 0 in controllers build; the LIVE secret is owned by `infrastructure-configs` from `configs/staging/databases/couchdb/admin-secret.yaml` (chart has `createAdminSecret: false`). Dead dir deleted, zero cluster effect. **Gotcha:** deleting the old `staging/` dir in the same commit that repoints `spec.path` causes a brief "path not found" alert (controller ticks against deleted path before flux-system patches the path field) — self-heals on next reconcile; use 2 commits (repoint, then delete) to avoid. | — |
| **F-37** | ❌ **CLOSED won't-do 2026-05-27.** uptime-kuma is internal-only (`uptime.h0melab.work` via internal Traefik, NO Cloudflare Tunnel mapping) and already self-protects with built-in auth + TOTP 2FA. No app in repo uses ForwardAuth (0 hits) — uptime-kuma lacks native OIDC, so ForwardAuth was the only SSO path, i.e. brand-new infra (proxy provider + outpost pod + middleware + outpost→authentik NP) for one internal app. **Net negative: circular dependency** — gating the status dashboard behind Authentik means an Authentik/its-Postgres/outpost outage locks you out of the exact tool needed to diagnose that outage. Edge-auth value applies to internet-exposed apps; this isn't one. Revisit only if uptime-kuma is ever exposed via CF Tunnel. | — |
| **F-38** | ✅ **DONE 2026-05-26** (`a35481fb`) — `databases` exclude removed (0 host-ns pods), `monitoring` → `app.kubernetes.io/name: prometheus-node-exporter` selector. Positive test: hostNetwork pod in `databases` (PSS privileged) now Kyverno-denied — closed a real unguarded gap. Scan 0-fail | — |
| **F-30 (inject)** | ✅ **DONE 2026-05-29.** Final: **35 critical + 52 standard + 8 batch CronJob templates + 6 system-cluster-critical (4 Flux ctrls + 2 k8s) + 6 system-node-critical**. Zero Running pods at NULL priority (verified via `audit-priority-class.sh --missing` = empty). Commits A+B+B'+C+D+E+I=critical; F (`60af77f0`) 18 authored apps; G (`a118d38d`) 8 HR-managed via postRenderers; H (`8a706db0`) 8 batch CronJobs; J (`6da41aa7`) gap-closure — 4 setup Jobs (n8n/mealie/obsidian/immich-init-extensions) + flux notification-controller parity. KPS alertmanager STS verified `homelab-standard` (Prometheus Operator propagated `alertmanagerSpec.priorityClassName` to generated STS). DB primaries pinned W1 (CNPG=main-postgres-12, Percona=mysql-1, Redis=replication-1). | — | Full preemption hierarchy live |
| **F-39** | ✅ **DONE 2026-05-27** (`3c5ce4aa` RoRFS ×3 + `runAsNonRoot` + `/tmp` on sync; `3d080256` ns baseline→restricted). Live `find / -xdev` write-audit on both running containers: only kubelet bind-mounts (`/etc/hosts,hostname,resolv.conf`) touched, zero root-fs writes. Only PSS-restricted gap was `runAsNonRoot != true` (proven via `--dry-run=server` label flip before+after). New pod 2/2, no EROFS. (Init's github SSH-pull `Connection refused` is pre-existing F-12 port-22 drop, `\|\| true`-tolerated, not F-39.) | — |

**🟢 Housekeeping (zero/low risk, batch anytime):**

| ID | Proper fix remaining |
|---|---|
| **F-30 (inject)** | ✅ **DONE 2026-05-29** — see Attended row above for full commit chain. |
| **F-44** | ✅ **DONE 2026-05-25** (`669790ee`) — DR handle + git config-rollback section in `.backup/README.md` |
| **F-23** | ✅ **DONE 2026-05-29** (`ba65f445` workflow + `693e41a8` manifest + `519ecead` CI gate). claude-telegram: rewrote `claude-telegram-build.yml` version generator → **3-component** (`major.minor.patch`, patch auto-increments per scheduled rebuild = dep-refresh, manual input reserved for minor/major; transition-safe glob). Triggered build emitting `1.25.0` (git tag `claude-telegram-v1.25.0` + GHCR image), bumped manifest `:1.24`→`:1.25.0` (all 3 refs), live-verified pod Ready/0-restart on the fresh image. seleniumbase-scrapper stays `:v1.0` — upstream ships only `:latest`+`:v1.0` (no patch), digest-pin declined; documented + allowlisted. **Closed the root gap, not just the instances:** new CI job `image-pin` (hard gate) runs `scripts/ci/image-pin-audit.sh` — asserts every container/init image is `major.minor.patch[-variant]` or `@sha256` (the class Kyverno's `:latest`-only check misses). Allowlist for native-2-component upstreams (postgres/postgresql/seleniumbase-scrapper). Surfaced via `_shared/np-coverage.sh`-style tooling during F-24. Renovate unaffected (default kubernetes manager handles 3-comp; `pinDigests:false` leaves seleniumbase). |
| **F-24** | ✅ **DONE 2026-05-29** (`c21b80a8`). Research correction: `caronc/apprise:v1.4.1` is ALREADY post-#273 (merged Nov 2025; v1.4.0 shipped May 2026) — **no image bump needed**. Hardened both apprise containers to non-root: sidecar `runAsUser:1000`+`runAsNonRoot:true`+`RoRFS:true`, dropped the `[CHOWN,SETUID,SETGID,DAC_OVERRIDE,FOWNER]` cap adds (kept drop ALL), added `/tmp` (emptyDir `medium:Memory`)+`/plugin`+`/attach` emptyDirs per upstream README. Kept the `apprise-init` initContainer but made it **non-root** (`runAsUser:1000`) rather than removing it — simpler + lower-risk than a SOPS-secret config mount, and it eliminates the only remaining root. Pod `fsGroup:33` unchanged (main container needs it); apprise uid 1000 writes the group-writable `/config` emptyDir via supplemental gid 33. **Reviewer raised a false-positive hard-blocker** ("emptyDir+fsGroup = 0o0750, group can't write") — refuted by live evidence: `/config` observed `drwxrwsrwx` (kubelet fsGroup ORs in 0o770+setgid), apprise image user `apprise:x:1000:100` matches `runAsUser:1000`. Live verify: pod recreated, init Completed exit 0, all 3 containers ready/0-restart, apprise uid=1000, `/status`=200, **test POST `/notify/pricebuddy` → HTTP 200 (real telegram delivered)**. |
| **W13-hist** | ✅ **DONE 2026-05-25** (`6790af4a`) — 2025 Oct–Dec changelog (1849 lines) → `docs/archive/HOMELAB_HISTORY_2025.md`; main file 3631→1782 lines + pointer |
| **W13-docs** | ✅ **DONE 2026-05-25** (`79fbca85`) — 10 stale docs `git mv`→`docs/archive/` + `docs/archive/README.md` index; referrers updated |
| **W13-mem** | ✅ **DONE 2026-05-25** (dotfiles `d5ebdd2`) — bidirectional `[[project-ultrareview-learnings]]`↔`[[project-ultrareview-2026-05-23]]` links, chezmoi-synced |
| **F-46** | ✅ **DONE 2026-05-29** (`1d473d5f`) — full cnpg-operator HR parity: install.crds:Create + install.remediation.retries:3 + maxHistory:3 + upgrade.crds:CreateReplace + upgrade.remediation.retries:3 + remediateLastFailure:true + rollback.recreate:true (+ pre-existing rollback.cleanupOnFail). Helm upgrade v2 succeeded; HR Ready=True post-reconcile. |
| **F-48** | ✅ **DONE 2026-05-29** (`88a62e50` NP + `703c61fa` egress fix). Added `redis-operator-network-policy` in `databases` ns. **Two brief-assumptions proven wrong on live cluster:** (1) selector is `name: redis-operator` NOT `app.kubernetes.io/name: redis-operator` (would've matched 0 pods — silent gap); (2) operator does NOT reach redis via API exec — it **dials pods directly** (`checkRedisServerRole` → `dial tcp redis-replication-0:6379`). The minimal egress (DNS + API only) broke role-checks: kube-router REJECTs blocked egress as TCP "connection refused" (not timeout), 56 errors starting exactly at NP-apply. Fix-forward added egress to redis(6379)+sentinel(26379) via `namespaceSelector databases` AND `podSelector app In [redis-replication,redis-sentinel-sentinel]` (matches immich + redis-ha-network-policy precedent). Post-fix: 0 errors/90s, RedisReplication CR MASTER repopulated, operator 0 restarts. Ingress: metrics 8080 from monitoring ns (no webhook — HR `webhook: false`). |
| **F-49** | ✅ **DONE 2026-05-29** (`208dd218`) — surfaced by `_shared/np-coverage.sh` (per-pod NP auditor built post-F-48; np-gap.sh + Kyverno F-5 are ns-level so missed these). Fixed 3 monitoring gaps: (1) deleted orphan `prometheus-network-policy` (KPS `prometheus.enabled: false` → `app.kubernetes.io/name: prometheus` pod never exists; Flux pruned it); (2) added `kube-state-metrics-network-policy` (ingress 8080 from monitoring ns = vmagent scrape; egress DNS + API); (3) added `prometheus-operator-network-policy` (selector `app: kube-prometheus-stack-operator` NOT app.kubernetes.io/name; ingress 10250 all-source = metrics + admission webhook per cnpg precedent; egress DNS + API). Live verify: ksm scrape `health=up`, zero unhealthy targets cluster-wide, both pods Ready/0-restart/0-error, np-coverage.sh clean (only popeye ORPHAN = weekly-CronJob FP). |
| **F-47** | ✅ **DONE 2026-05-29** (`6da41aa7`) — injected `priorityClassName: system-cluster-critical` on `notification-controller` Deployment in `clusters/staging/flux-system/gotk-components.yaml` for parity with the other 3 Flux controllers (source/kustomize/helm — pre-existing system-cluster-critical at lines 2607, 3429, 4985). Live confirmed: notification-controller pod = system-cluster-critical. Upstream Flux gotk omits this from notification-controller only — homelab fix-forward. |

**Operational fixes this session (outside original review scope — logged in HOMELAB_HISTORY):**
- `2ff39465` W1 `swap_path` → stable `by-uuid` (NVMe enum flips on reboot; was flip-flopping nvme0↔nvme1). CP=`/swapfile` + W2=LVM already stable.
- `466b8fca` stirling-pdf startupProbe `failureThreshold` 9→30 (2.11.0-fat cold boot >90s after reboot).

---

### Wave 1 — Closed 2026-05-23

- [x] **F-1** Cloudflare ACCOUNT + TUNNEL UUID → SOPS Secret env vars (no regen needed)
- [x] **F-2a** `paperless-ngx` added to `require-non-root` exclude (s6-overlay constraint)
- [x] **F-2b** `disallow-host-path` + `require-non-root` + `require-resource-limits` → Enforce
- [x] **F-3** `require-resource-limits` covers `initContainers[*]`
- [x] **F-7** `monitoring-controllers/configs` Flux `dependsOn`+`healthChecks`+SOPS parity
- [x] **F-8** dead `healthChecks` block removed from `apps.yaml`
- [x] **F-9** Immich egress RFC1918 except
- [x] **F-10** uptime-kuma DB-port egress scoped to `databases` ns
- [x] **F-11** n8n 443 RFC1918 except
- [x] **F-12** claude-telegram port 22 dropped, port 80 RFC1918 except
- [x] **F-19** claude-telegram ResourceQuota+LimitRange
- [x] **F-27** `setup-node.sh` `set -euo pipefail` + grep guard
- [x] **F-28** `analyze-update.sh:65` precedence rewrite
- [x] **F-29** claude-telegram-build force-tag → pre-existence guard
- [x] **F-41** init container `resources:` for authentik-worker + home-assistant (2 inits) + paperless-ngx
- [x] **F-42** Kyverno `exclude:` for CNPG pooler + vmagent (operator-managed init)
- [x] Doc drift: `HOMELAB_ANALYSIS.md` keyfacts + HOMELAB_HISTORY append

---

## Wave Plan v2 (post-2026-05-23 — informed by Wave 1 learnings)

### Learnings from Wave 1 that shape v2

| # | Learning | Plan adjustment |
|---|---|---|
| L1 | Audit mode IS productive — F-3 surfaced 5 latent gaps that would have crashed Enforce. | Every new Kyverno policy ships Audit first, scan ≥24h, fix, then Enforce. Codify in Wave 8 below. |
| L2 | Operator-managed Pods (CNPG, VM-operator, Kyverno, Percona) are second-class — we can't edit their spec. Exclude by label-selector, not by name. | Wave 8 policies (F-4/F-5/F-6) bake operator label-selector excludes upfront, not as post-hoc patches. |
| L3 | Kyverno autogen propagates pod-level patterns to ReplicaSet/StatefulSet automatically. | Don't write controller-level rules manually; only target `kinds: [Pod]`. |
| L4 | Init containers are hidden footguns — `hacs-install` almost slipped through scan. | Wave 7 CI gate adds explicit `yq` rule: every init must have `resources:`. |
| L5 | Server-side `--dry-run=server` catches admission-webhook rejection; client-side dry-run does NOT. | Standard pre-push validator switches to server-side; the "conflicts" stderr is informational not failure. |
| L6 | Multi-agent reviewer caught REAL bugs (`vm-operator` → `victoria-metrics-operator`) — not theater. | Reviewer remains mandatory for every Flux-touching commit. |
| L7 | Flux dependsOn cascade takes ~5min for full propagation post-push. | Bake 5min sleep into post-push verification scripts; don't ssh-poll Kustomization status faster. |
| L8 | Doc drift accumulates fast — even mid-session, `HOMELAB_ANALYSIS` needed 3 touches. | Wave 7 CI gate: `HOMELAB_ANALYSIS` keyfact line must match live `kubectl` counts (NP, SOPS, Kyverno enforce counts). |
| L9 | Multi-file `git commit` chains break the project's pre-push hook (per-line single quoting). | Sequential per-commit shell calls only. |
| L10 | Kyverno `=()` optional patterns silently pass when field omitted — F-4 still pending applies same root cause as F-3. | Wave 8 policy authoring rule: any field whose absence = security regression must use `deny` not `=()`. |
| L11 | F-2b "fix-forward" worked (Audit surfaced → patch in-repo + label-exclude operator-managed → promote) better than "revert F-3". | Codify "fix-forward over revert" for Audit→Enforce promotions. |
| L12 | The `pre-ultrareview-2026-05-23` annotated tag survived as rollback handle even after 10 commits. | Always tag before multi-commit waves. |

---

### Wave 7 — CI Gates (HIGHEST PREVENTATIVE ROI — do first) ✅ Closed 2026-05-24

**Goal:** every learning from L1, L4, L5, L8 above gets a CI guard so future PRs don't re-introduce.

- [x] **CI-1** `.github/workflows/validate.yaml` — runs on every PR + push to main. Jobs:
  - `yamllint .` (config in `.yamllint.yaml` — SOPS-managed files excluded since the encrypted layout is operator-owned)
  - `shellcheck -S error` on `scripts/**/*.sh` + `docs/scripts/**/*.sh`
  - SOPS encryption presence (`scripts/ci/check-sops-encrypted.sh`): every `*secret*.yaml`, `*credentials*.yaml`, `*-db-user.yaml`, `*.sops.yaml`, etc. must contain `ENC[AES256_GCM`
  - `kubeconform -strict -ignore-missing-schemas -kubernetes-version 1.31.0` per kustomize root (apps/staging, infrastructure/{configs,controllers}/staging, monitoring/{configs,controllers}/staging); pipes through `yq 'del(.sops)'` to strip the SOPS metadata before validation
  - Init container resources guard (`scripts/ci/check-init-resources.sh`): `yq` across every authored Deployment/StatefulSet/DaemonSet/Job/CronJob with `initContainers`, asserts all 4 fields (`resources.{requests,limits}.{cpu,memory}`). HelmRelease + operator CRs (Cluster/Pooler/VMAgent) skipped — rendered server-side
  - `HOMELAB_ANALYSIS` keyfact drift (`continue-on-error: true`): live NP/SOPS/Kyverno counts vs the keyfact line
  - **NOT included:** `flux build kustomization` — needs a live cluster (queries server discovery for API versions), errors `dial tcp [::1]:8080: connect: connection refused` in CI. The kubeconform job exercises the same offline render path via `kustomize build --enable-helm`
- [x] **CI-2** `.pre-commit-config.yaml` — mirrors the same gates locally (yamllint, shellcheck-py, sops-check, init-resources, trailing-whitespace, end-of-file-fixer). Heavy gates (kubeconform per root) stay CI-only
- [x] **CI-3** Yamllint baseline cleanup (commit `7fc45914`) — EOL on 18 files, trailing whitespace strip on 5, flow→block on the authentik `!Find` blueprint
- **Tag:** `pre-w7-2026-05-24` (annotated, signed). **Commits:** `7fc45914` (cleanup) → `d65ad41b` (CI gates) → `6fc3ebe3` (drop flux-build job, needs cluster) → `db4bc940` (pin kustomize v5.5.0, upstream installer flaked on 1/5 matrix) → `cd2c973e` (drop sudo — `/usr/local/bin` writable on ubuntu-latest but `$HOME/.local/bin` via `$GITHUB_PATH` is cleaner). Final run: 9/9 jobs green

### Wave 8 — New Kyverno policies (apply L1/L2/L10 directly) ✅ Closed 2026-05-25 (tag `pre-w8-2026-05-24`)

Each new policy shipped Audit → soak → fix-forward (in-repo `resources:`/labels + operator/ns exclude) → **promoted Enforce 2026-05-25**. Commits: `8a4295f2` (F-4/F-6 excludes + homehub init RoRFS) → `60f2a2cb` (F-6 robust Job handling) → `864231ee` (flip all 4 Audit→Enforce). Post-flip scan: priv-esc 44 pass/0 fail, drop-caps 44/0, networkpolicy 160/0, readonly-rootfs 40/0. Live admission-deny confirmed (`validate.kyverno.svc-fail` blocked a RoRFS-violating test pod).

- [x] **F-4** `=()`→mandatory PSS pattern in `disallow-privilege-escalation` + `require-drop-all-capabilities`. 9 (priv-esc) / 10 (drop-caps) operator/privileged workloads excluded → **Enforce**. Excludes: ns `databases`/`immich`/`percona-mysql` (operator/CRD/Helm, privileged) + label-selectors `loki`→`app.kubernetes.io/name: alloy`, `monitoring`→`prometheus-node-exporter` (Helm DaemonSets, keep rest of ns covered).
- [x] **F-5** `require-networkpolicy.yaml`: apiCall counts NPs in `{{request.namespace}}`, deny if <1. **160 pass / 0 fail**, no excludes beyond kube-*/default → **Enforce**. apiCall + `request.namespace` confirmed working in background scan on Kyverno v1.18.1.
- [x] **F-6** `require-readonly-rootfs.yaml`: mandatory PSS pattern. Soak surfaced **23 workloads** (baseline at soak-start undercounted — background controller had not completed a full cycle). Triage → **Enforce**:
  - Fixed (RoRFS+`/tmp`): **homehub** init `setup-config` (writes only to mounted emptyDir); **uptime-kuma-setup** Job (HOME=/tmp + pip --user → all writes in /tmp; force-recreated, Completed under RoRFS).
  - Excluded ns (operator/privileged/batch can't comply): `databases`, `percona-mysql`, `immich`, `home-assistant`, `paperless-ngx`, `backup-replication`, `claude-telegram` (F-39 write-audit gate), `pricebuddy`, `stirling-pdf`, `mealie` (PSS-baseline; apt-get at runtime). Label-selectors: `loki`→alloy, `monitoring`→grafana.
- **Gotcha (L13):** label-selector excludes on a Pod-matching policy do NOT cover the `autogen-*` rule's Job/controller resource if the label only exists on the pod template (a Job's `metadata.labels` carry only Flux labels). Use ns-scope exclude — or fix the workload — for Jobs. Caught pre-flip via PolicyViolation events on `job/uptime-kuma-setup`.
- **Payoff:** closes 3 documented invariants previously held by manual discipline only. **12 Kyverno policies, all Enforce.**

### Wave 9 — HelmRelease tightening (bulk low-risk) ✅ Closed 2026-05-24

- [x] **F-16** `driftDetection: { mode: enabled }` on 11 HelmReleases (all except KPS which already had it)
- [x] **F-17** Explicit `timeout: 10m` on `kube-prometheus-stack`, `loki`, `cert-manager`, `couchdb`
- [x] **F-18** `rollback: { cleanupOnFail: true }` on `mysql`, `redis-operator`, `traefik`, `vm-operator`, `immich` (postgres/kyverno/alloy/cert-manager/couchdb already had rollback — left untouched)
- [x] **F-20** Standardized HelmRelease `interval: 6h` (dropped `30m` on mysql + redis-operator)
- **Commit** `60a8bf32`. All 5 kustomize roots build green. **Payoff:** removes orphan ConfigMap accumulation + catches manual `kubectl edit` drift.

### Wave 10 — Simple polish (single-line / single-file edits) 🟢 Mostly closed 2026-05-24 (3 deferred → attended)

- [x] **F-21** HSTS middleware: `max-age=31536000; includeSubDomains; preload`
- [x] **F-25** Privileged namespaces `audit/warn: baseline` (immich, home-assistant); `enforce: privileged` kept
- [x] **F-26** Renovate schedule off-hours (`after 10pm and before 6am every weekday`, `every weekend`) + `automerge: true` on `patch` scoped to `apps/**`
- [x] **F-30** Defined `PriorityClass: homelab-{critical=100000,standard=50000,batch=10000}` (globalDefault:false) at `infrastructure/configs/base/priority-classes/`. **Workload `priorityClassName` injection deferred** — separate follow-up (touches ~40 workloads)
- [x] **F-31** `startingDeadlineSeconds: 600` on 6 backup CronJobs; `backoffLimit: 2` where absent (couchdb kept intentional `6`; backup-replication already `2`)
- [x] **F-32** Pinned `fluxcd/flux2/action@main` → `@v2.8.8` (matched live cluster Flux version)
- [x] **F-37 — ❌ CLOSED won't-do 2026-05-27.** uptime-kuma internal-only (no CF Tunnel) + built-in auth + TOTP 2FA already. ForwardAuth = brand-new infra (proxy provider/outpost/middleware/NP) for one internal app, and a circular dependency (status dashboard gated behind the SSO whose outage you'd need it to detect). Edge-auth value is for internet-exposed apps; this isn't one. Revisit only if exposed via CF Tunnel.
- [x] **F-38 — ✅ DONE 2026-05-26** (`a35481fb`). `databases` exclude removed (verified 0 host-ns pods), `monitoring` narrowed to `app.kubernetes.io/name: prometheus-node-exporter`. Closed a real gap: `databases` (PSS privileged) was host-ns-unguarded; now Kyverno-denied (positive dry-run test). Scan 0-fail, node-exporter Running.
- [x] **F-39 — ✅ DONE 2026-05-27** (`3c5ce4aa` RoRFS ×3 + runAsNonRoot + `/tmp` emptyDir; `3d080256` ns baseline→restricted). Live `find / -xdev` write-audit on both running containers confirmed writes only to PVC + `/tmp`. claude-telegram RoRFS + PSS restricted closed — see Resume Attended table.
- [x] **F-44** Document `pre-ultrareview-2026-05-23` DR handle in `.backup/README.md` — ✅ 2026-05-25 (`669790ee`)
- **Commit** `d8ef6891` (6 findings). **Risk:** Per-item low.

### Wave 11 — Structural refactor (highest blast radius — stage carefully) ✅ DONE — F-13 + F-14 (infra `95b87e53`+`367fc91d`, monitoring `b53a4cab`) + R5 + R6 + F-15 all closed

- [x] **R5 / F-13 / F-14 — ✅ ALL DONE** (R5 `6229d4ed`+`611b6320`; F-13 `b818b17d`+`9179c956`+`181711ec`; F-14 `b442c098`+`95b87e53`+`367fc91d`+`b53a4cab`). Decision log below (per-item status superseded — see Resume Attended table):
  - **F-13** = collapse `apps/staging/<app>/` → `apps/<app>/` (single env, 16 apps). Decision: NO multi-cluster roadmap → safe to collapse. ✅ **DONE 2026-05-29** — 196-rename flatten, render byte-identical, zero churn.
  - **F-14** = ✅ **FULLY DONE.** Three slices: (1) monitoring passthrough cleanup `b442c098` (removed per-component overlays); (2) infra-controllers full flatten `95b87e53`+`367fc91d` (`[../base]` → `infrastructure/controllers/`, dead `couchdb/secret.yaml` dropped — traced as unreferenced dup, live secret owned by infra-configs); (3) **monitoring-controllers full flatten 2026-05-31 `b53a4cab`** — `monitoring/controllers/{base,staging}` → flat `<component>/`, kps `namespace: monitoring` folded from the dropped staging overlay. All render byte-identical (empty oracle-diff), zero Flux churn.
  - **R5** = Kustomize components for NP DNS/Postgres/Redis egress. ✅ **DONE 2026-05-29** (`6229d4ed`+`611b6320`) — shipped ONLY the shareable slice: `allow-dns-egress` component (Job-excluded), wired 14 standard apps (−122 LOC). Per-app exceptions (blocky external upstreams `1.1.1.2`/`9.9.9.9`/`149.112.112.112`/`1.0.0.2`; `k8s-app: kube-dns` podSelector; `192.168.1.0/24`) left OUT of the component, not forced in. Postgres/Redis egress not componentized (too varied).
  - **Order (shipped):** R5 (`6229d4ed`) → F-13 (`b818b17d`) → F-14 infra (`95b87e53`) → F-14 monitoring (`b53a4cab`).
- [x] **F-15 — ✅ DONE 2026-05-27** (`002e06f7`, direction inverted). NOT "make all app-owned": CNPG `Database.spec.cluster` is a `LocalObjectReference` (CR must be ns `databases`); 4/7 apps set `namespace:<app>` which would break the ref; Flux canonical treats DB as infra (apps `dependsOn`). Consolidated blocky → `infrastructure/configs/staging/databases/postgres/` instead. All 7 in one canonical infra dir. Handoff clean (retain + Flux GC label-protection; CR adopted by infra-configs, applied=true, AGE preserved, pods unaffected).
- **Effort:** R5 = 2h, F-14 = 30min, F-15 = 2h, F-13 = 4h. **Risk:** F-15 medium (CNPG Database CR), F-13 high (16 dirs renamed, Flux must re-discover). **Payoff:** atomic per-app delete via `prune: true`; clean ownership.

### Wave 12 — CSP 3-tier rollout (calendar-bound, 3 weeks) 🟡 Day-0 setup done 2026-05-24; rollout calendar-bound

- [~] **F-22** 3 middlewares + per-app ingress annotation swap. Existing csp-reporter as observability.
  - **Day 0:** ✅ **DONE (commit `971a27d2`):** Created `csp-strict`/`csp-inline`/`csp-permissive` in `traefik` ns, each emitting `Content-Security-Policy-Report-Only` (script-src 'self' | +'unsafe-inline' | +'unsafe-eval'); all other directives mirror the global enforced CSP; `report-uri` → csp-reporter preserved. NO ingress annotation swaps, current enforced `csp` middleware untouched. **Remaining = calendar-bound** (per-tier ingress swap + 7d soak + enforce flip).
  - **Day 1-2:** ✅ **DONE 2026-05-31 (`8de095cd`):** Appended `,traefik-csp-strict@kubernetescrd` to Tier A ingresses. Real scope = **paperless-ngx + couchdb** (obsidian's only web surface, Fauxton). blocky/claude-telegram/obsidian carry NO Ingress (DNS / outbound bot / couchdb-backed) → nothing to swap. Additive: strict rides `Content-Security-Policy-Report-Only` alongside the unchanged enforced `csp`. Both headers verified live via curl.
  - **Day 3-9:** Soak started 2026-05-31. ~2026-06-07 check `{app="csp-reporter"} |= "paperless.h0melab.work"` / `|= "couchdb.h0melab.work"` in Loki.
  - **Day 10+:** If clean, flip Report-Only → enforced for that tier; drop permissive header.
  - **Repeat** for Tier B (8 apps) then Tier C (4 apps).
- **Effort:** 2h actual edits, ~3 weeks calendar for soak. **Risk:** Low per-app (rollback = revert ingress annotation).

### Wave 13 — Cruft + back-links (housekeeping) 🟢 Mostly closed 2026-05-24 (2 deferred)

- [x] `.DS_Store` — **no-op**: 0 actually tracked in git (review's "13 tracked" was stale; filesystem copies already gitignored)
- [x] Deleted `scripts/analyze-update/baselines/pr-198..pr-208.txt` (10 files) + added `baselines/` to `.gitignore`
- [x] Deleted `docs/POPEYE_CLUSTER_REPORT.txt`
- [x] Archived `docs/superpowers/` (15 plans/specs) → `docs/archive/superpowers/` (git rename, content preserved)
- [x] Rotate `HOMELAB_HISTORY.md` pre-2026 entries → `docs/archive/HOMELAB_HISTORY_2025.md` — ✅ 2026-05-25 (`6790af4a`); 3631→1782 lines
- [x] Stale docs to archive — ✅ 2026-05-25 (`79fbca85`); 10 `git mv`→`docs/archive/` + index, referrers updated
- [x] Memory back-links — ✅ 2026-05-25 (dotfiles `d5ebdd2`); bidirectional ultrareview links, chezmoi-synced
- **Commit** `ba9b1b7d`. **Risk:** Zero (pure cleanup).

### Watch / parking lot (no immediate action)

- [x] **F-23 — ✅ DONE 2026-05-29** (`ba65f445` workflow + `693e41a8` manifest + `519ecead` CI gate). Rewrote claude-telegram version generator → 3-component tags (`major.minor.patch`). See Resume Housekeeping table.
- [x] **F-24 — ✅ DONE 2026-05-29** (`c21b80a8`). `caronc/apprise:v1.4.1` already post-#273 (no bump needed); hardened pricebuddy to non-root + RO-FS, dropped root init. See Resume Housekeeping table.
- [x] **F-40 — ❌ CLOSED not-viable.** `paperless-ngx` fsGroup migration to drop init — s6-overlay requires root-owned writes; verified NOT VIABLE. Documented closed.
- [ ] **F-43** Monthly (next 2026-06-04): check https://github.com/christiaangoossens/hass-oidc-auth/releases for HA compat; enable HA OIDC if shipped.
- [x] **F-45** PSS privileged-ns audit (surfaced F-38). ✅ **CLOSED not-viable 2026-05-26** — all 6 `privileged`-enforce ns are justified; none can tighten to `baseline`.
  - **Disqualifier (the key fact):** PSS **Baseline forbids hostPath volumes** (it's a Baseline "HostPath Volumes" control, not Restricted-only). Verified by live `--dry-run=server` of a hostPath pod into a baseline-enforce ns → `violates PodSecurity "baseline:latest": hostPath volumes`. My first scan wrongly omitted hostPath (believed it baseline-allowed) and falsely flagged 3 ns as tightenable — corrected before any commit (zero changes shipped).
  - **Per-ns justification:** `monitoring` (node-exporter hostNetwork+hostPID+hostPort:9100) · `immich` (`privileged: true`, GPU/HW transcode) · `home-assistant` (`cap:NET_ADMIN`) · `loki` (Alloy DaemonSet hostPath `/var/log/journal`) · `databases` (backup CronJobs couchdb/mysql/postgres mount hostPath `backup-storage`) · `backup-replication` (hostPath backup dir).
  - **Lesson:** any future PSS-baseline scan MUST check hostPath volumes — it's the most common disqualifier here (3 of 6 ns). Existing repo comments in `loki-stack/namespace.yaml` + `backup-replication/namespace.yaml` were correct.

---

### Findings retired

| # | Reason |
|---|---|
| F-2a | Closed Wave 1. |
| F-40 | Verified not viable (s6-overlay). |
| F-44 (would-be) | Already done — tag pushed. Documenting in Wave 10 only. |

### Findings reframed by Wave 1 learnings

| # | Original framing | New framing |
|---|---|---|
| F-4 | "Replace `=()` with deny" | Apply same fix-forward as F-3: ship Audit → scan ≥24h → fix surfaced gaps in-repo + operator-label exclude → Enforce. Expect 5-10 latent gaps. |
| F-5 | "Add require-networkpolicy" | Same. Operator namespaces (kube-system, flux-system, kyverno, monitoring) likely need exclude. |
| F-6 | "Add require-readonly-rootfs" | Same. pricebuddy 3 containers + any uncovered init will surface. |
| F-13 | "Maybe collapse if no prod" | DECIDED: no prod. Proceed but defer — biggest blast radius in backlog. |
| F-22 | "Per-app CSP" | Now: 3-tier (strict/inline/permissive), report-only-first via existing csp-reporter, per-tier rollout cadence specified. |

---

## Decisions (resolved 2026-05-23)

| # | Question | Decision |
|---|---|---|
| 1 | Multi-cluster `prod/` on roadmap? | **NO** — single staging. F-13 collapse path justified. |
| 2 | `require-non-root` Enforce breakers? | **paperless-ngx only** — add to exclude (s6-overlay constraint, prior incident). All other apps verified non-root. |
| 3 | DB ownership rule? | **App-owned (blocky pattern)** — atomic prune wins. Migrate authentik, immich, linkwarden, mealie, n8n, paperless db users into their app dirs. |
| 4 | Cloudflare ACCOUNT_ID/UUID regen? | **NO** — account ID is non-secret; tunnel UUID alone non-credential; real cred (`tunnel-credentials.yaml`) already SOPS-encrypted. F-1 fix is hygiene-only. |
| 5 | n8n egress tightening? | **RFC1918 except block** — stock K3s lacks FQDN egress (would need Cilium/Calico). Same pattern as cert-manager / backup-replication. |
| 6 | CSP per-app needs? | **3 tiers: strict / inline / permissive** — see F-22. Report-only rollout via existing csp-reporter. |

---

## Reviewer Provenance

- **ecc:architect** — folder hierarchy, Kustomize idioms, base/staging split → F-13, F-14, F-15, F-7, R6
- **k8s-devops-reviewer** — Flux, Helm, Kyverno, Renovate, NP duplication → F-7, F-8, F-16, F-17, F-18, F-20, F-26, R5
- **ecc:security-reviewer** — invariants, NPs, Kyverno, SOPS, CSP → F-1, F-2, F-3, F-4, F-5, F-6, F-9, F-10, F-11, F-12, F-21, F-22, F-24, F-25
- **ecc:code-reviewer** — drift, cruft, scripts, CI → F-19 doc, F-27, F-28, F-29, CI Gaps, all cruft
