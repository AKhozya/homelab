# HOMELAB COMPREHENSIVE ANALYSIS

**Cluster**: K3s v1.36.1+k3s1 (upgraded 2026-06-05) — single-env **production** (no staging; merge to `main` = deploy to prod) — 3 nodes (1 CP, 2 workers)
**Node IPs** (static DHCP, k3s pinned to IPv4): gmk-k3s-control-plane=192.168.1.127, worker-node=192.168.1.129, worker-node-2=192.168.1.126
**Infra**: GitOps (Flux), CloudNativePG, Percona MySQL, monitoring stack, SSO (Authentik), Cloudflare Tunnel
**Code Review**: 2026-04-02 — full scan (94/100, A)
**Ultrareview**: 2026-05-23 — 4-agent consensus (arch/k8s/security/cruft). 1 P0 + 11 P1 + 17 P2 + refactors — **all closed by 2026-06-05**; REVIEW.md retired (full record in git history).
**Ultrareview 2 (UR2)**: 2026-06-06 — 8-dimension multi-agent scan + 2-lens adversarial verify. 16 confirmed (3 P1 + 13 P2, all live-re-verified), 1 refuted, 18 P3 deferred. **All 16 shipped + live-tested 2026-06-06** in 5 gated batches (`2843c86e`→`5286a2c1`) + 2 alert-fallout hotfixes (`5d217282`,`03711ab7`). Detail in HOMELAB_HISTORY 2026-06-06. Deferred: 18 P3 leads + seccomp re-Enforce (22-pod remediation).

---

## CURRENT STATE

**Overall Grade: A+ (97/100)**

| Category | Score |
|----------|-------|
| Security | 98/100 |
| Backup/DR | 98/100 |
| Maintainability | 95/100 |
| Performance | 94/100 |
| Best Practices | 92/100 |
| Database | 90/100 |
| Infrastructure | 88/100 |

**Key facts**: 64 NetworkPolicy resources (42 files, multi-doc; R5 2026-05-29 `6229d4ed`+`611b6320` added the repo's first Kustomize Component `apps/components/allow-dns-egress` — Job-excluded DNS-egress baseline wired into 14 apps, per-app DNS blocks deduped −122 LOC; R5-followup `68dddceb` added 4 tight per-Job egress NPs (audiobookshelf-init/home-assistant-admin-setup/immich-admin-setup/n8n-user-provision — DNS + app container-port, selected by `batch.kubernetes.io/job-name`); mealie+uptime-kuma Jobs deferred — runtime apt-get/pip needs internet egress, can't tighten without baking images). 53 SOPS secrets. **12 Kyverno policies — 11 Enforce + 1 Audit** (`require-seccomp-runtimedefault` → Audit UR2-4 2026-06-06: `=()` soft anchors made it toothless-Enforce; hard-anchored now, ~22 operator/chart pods lack `seccompProfile` and need remediation before re-Enforce. The other 11 — Wave 8 closed 2026-05-25, commit `864231ee`: F-4 `disallow-privilege-escalation`+`require-drop-all-capabilities`, F-5 `require-networkpolicy`, F-6 `require-readonly-rootfs` promoted Audit→Enforce after clean fix-forward scan. Operator/privileged/batch workloads excluded by ns + label-selector; homehub init + uptime-kuma-setup fixed to RoRFS. CNPG pooler + vmagent init excluded via label selectors; `disallow-host-namespaces` excludes tightened F-38 2026-05-26 — `databases` whole-ns dropped, `monitoring`→node-exporter label selector). 13 HelmReleases (all `driftDetection: enabled` as of W9 2026-05-24; targeted timeouts + rollback.cleanupOnFail). 3 PriorityClasses defined (homelab-critical/standard/batch); **F-30 fully closed 2026-05-29** — Commits A+B+B'+C+D+E+F+G+H+I+J. **35 critical** + **52 standard** + **8 batch templates** + 6 system-cluster-critical (4 Flux + 2 k8s) + 6 system-node-critical. **Zero un-annotated Running pods.** Critical: 18 DBs (4 CNPG + 7 Percona + 2 CouchDB + 5 Redis) + 4 DB operators (cnpg×2 + redis + ps-operator via postRenderers) + 4 ingress + 4 SSO + 2 DNS + 3 monitoring-core. Standard via Commits F (18 authored) + G (8 HR-managed via postRenderers) + J gap-closure (4 setup Jobs — n8n/mealie/obsidian/immich-init-extensions). Batch via Commit H (8 CronJobs). Flux notification-controller fixed to system-cluster-critical (F-47) for parity with other 3 Flux controllers. KPS alertmanager STS verified homelab-standard via Prometheus Operator field propagation. DB primaries pinned W1 (CNPG=main-postgres-12, Percona=mysql-1, Redis=replication-1). CSP: global permissive `csp` is the default; **Tier A+B enforced 2026-06-04** (`c8c5fbaa`+`e5ee973a`), all browser-console verified — the report-only `csp-reporter` soak gate is **non-functional** (report-uri is cluster-internal HTTP → Mixed-Content + unresolvable from a browser, Loki always empty), so `report-uri` was dropped from the enforced middlewares. **6 apps on tighter enforced CSP:** strict `script-src 'self'` = couchdb; inline `'self' 'unsafe-inline'` (drops `unsafe-eval`) = paperless-ngx + homepage + mealie + homehub + audiobookshelf. **8 apps need eval/wasm → explicit `csp-permissive-enforced`:** authentik, linkwarden, stirling-pdf, n8n + Tier-C home-assistant/immich/pricebuddy/uptime-kuma. **Default INVERTED 2026-06-04** (`1d7eb372` A + B): the global `csp` middleware flipped permissive→inline (`'self' 'unsafe-inline'`, no eval) and the 8 moved to explicit `csp-permissive-enforced` (zero behavior change, live-verified) — a new app whose ingress lists `traefik-csp` can no longer silently inherit `unsafe-eval`; eval is now an explicit opt-in. report-only `csp-strict`/`csp-inline`/`csp-permissive` soak middlewares **deleted 2026-06-05** (referenced by zero ingresses; report path dead). Optional leftover: `https` report endpoint for standing soaks. 16 apps in flat `apps/<app>/` layout — F-13 2026-05-29 (`b818b17d`+`9179c956`+`181711ec`) collapsed the `apps/base`+`apps/staging` overlay split into one dir per app (single-env, no prod roadmap; render byte-identical → zero churn; Flux `apps` path → `./apps`); `apps/components/` holds the shared component. F-14 (`95b87e53`+`367fc91d`) likewise flattened `infrastructure/controllers/staging`[../base] → `infrastructure/controllers/` and dropped a dead `controllers/staging/couchdb` secret duplicate. Monitoring controllers followed 2026-05-31 (`b53a4cab`): `monitoring/controllers/{base,staging}` → flat `monitoring/controllers/<component>` (kps `namespace: monitoring` folded from the dropped staging overlay; render byte-identical, 17 resources, zero churn). **Configs layer flattened 2026-06-04** (`081934c0` mon + `87deba9e` infra) — the LAST base/staging splits: `monitoring/configs/{base,staging}`→`monitoring/configs/` + `infrastructure/configs/{base,staging}`→`infrastructure/configs/`; render byte-identical (63 mon / 133 infra res), zero churn; dropped redundant `namespace:` transforms (kps + databases/couchdb), deleted dead `base/resource-governance`, renamed colliding mysql `serviceaccount.yaml`→`jobs-serviceaccount.yaml` (`main-mysql` vs `mysql-jobs`). No base/staging overlay splits remain repo-wide. PSS enforce (live 2026-05-27): 12 ns `restricted`, 9 `baseline` (cert-manager/kyverno/percona-mysql/popeye/traefik infra + mealie/paperless-ngx/pricebuddy/stirling-pdf apps — s6-overlay/init constraints; claude-telegram promoted restricted F-39 2026-05-27 — RoRFS ×3 + runAsNonRoot), 6 `privileged` — all justified (F-45 verified not-tightenable 2026-05-26): `monitoring` (node-exporter hostNetwork+hostPID+hostPort), `immich`+`home-assistant` (GPU/HW: `privileged`/`NET_ADMIN`), and hostPath holders `loki` (Alloy `/var/log/journal`), `databases` (backup CronJobs `backup-storage`), `backup-replication` (backup dir) — PSS baseline forbids hostPath, so none can drop to baseline. NetworkPolicy coverage manual + F-5 Kyverno backstop (Enforce; 160 pass/0 fail); F-48 2026-05-29 closed the redis-operator NP gap (`redis-operator-network-policy`, selector `name: redis-operator` — operator dials redis/sentinel pods directly on 6379/26379, not via API exec). F-49 2026-05-29 closed monitoring per-pod gaps found by the new `_shared/np-coverage.sh` per-pod auditor (np-gap.sh/Kyverno are ns-level): dropped orphan `prometheus-network-policy` (prometheus server disabled, pod never exists), added `kube-state-metrics-network-policy` + `prometheus-operator-network-policy`. HSTS (`includeSubDomains; preload`) + SSO manually maintained; image-pin CI-gated since F-23 (`image-pin-audit.sh` hard gate; `seleniumbase:v1.0` allowlisted — upstream ships no patch tags). `claude-telegram` ns removed from `require-readonly-rootfs` excludes 2026-06-05 (RoRFS-compliant since F-39). Ultrareview backlog fully closed 2026-06-05 — REVIEW.md retired (git history).

---

## APPS (16 total)

> Grafana = monitoring infra (see `docs/CODEMAPS/monitoring.md`), not an app.

| App | OIDC/SSO | Notes |
|-----|----------|-------|
| Homepage | - | Dashboard |
| Uptime Kuma | - | Uptime monitor, MySQL |
| Authentik | Provider | SSO, PostgreSQL (no Redis — in-memory cache), passkey-only via Conditional UI (password binding removed 2026-06-05; recovery = username+TOTP or email flow) |
| Blocky | - | DNS filter + ad blocking, **HA: 2 replicas (W1+W2), single Deployment, native rolling, Redis cache sync, CNPG Postgres query log**. Serves **LAN clients only** (via router DHCP → .129/.126 servicelb); nodes + CoreDNS upstream = public DNS since 2026-06-04 (circular-dep break) |
| Stirling PDF | OIDC | PDF toolkit |
| HomeHub | - | Family dashboard, local only |
| Immich | OIDC | Photo mgmt |
| Paperless-NGX | OIDC | Doc mgmt |
| Home Assistant | OIDC | Smart home, MySQL |
| LinkWarden | OIDC | Bookmarks + Meilisearch |
| Mealie | OIDC | Recipes |
| N8N | OIDC | Automation (community edition) |
| Audiobookshelf | OIDC | Audiobook library |
| Obsidian | - | CouchDB sync |
| PriceBuddy | - | Price track, MySQL |
| Claude Telegram | - | AI bot (Agent SDK), Telegram DM only |

---

## DATABASES

| Engine | Replicas | HA | Proxy | Key Apps |
|--------|----------|-----|-------|----------|
| PostgreSQL (CNPG) | 2 | Streaming repl | PgBouncer | Authentik, Immich, Paperless, Grafana, N8N, Mealie, LinkWarden, Audiobookshelf |
| MySQL (Percona) | 2 | Async repl | HAProxy | Home Assistant, Uptime Kuma, PriceBuddy |
| Redis (OT-operator v0.24.0) | 1 master + 1 replica + 3 Sentinels | Sentinel quorum (2 of 3) | Sentinel (Immich) / static master Service (Paperless) | Paperless, Immich, Blocky (planned). Authentik does NOT use Redis. |
| CouchDB | 2 | Active-active | - | Obsidian sync |

---

## BACKUPS

- PG 3:00, CouchDB 3:05, PVC 3:10, MySQL 3:15 (30-day retention)
- Replication 3:30: worker-node-2 (SSH) → NAS (rsync daemon, 500GB cap)
- Validate: SHA256 + tar + size + age. Telegram failure-only alerts.

---

## MONITORING

- **VictoriaMetrics**: VMSingle + VMAgent + VMOperator, ~113k series, ~487Mi (71% RAM save vs Prometheus)
- **Grafana**: dashboards + OIDC
- **Loki + Alloy**: log aggregation (DaemonSet)
- **Alertmanager**: Telegram alerts
- **Popeye**: weekly CronJob (Sun 6 AM), 100/100
- **Kyverno**: daily violation summaries

---

## EXTERNAL ACCESS

**Cloudflare Tunnel** (9 svcs): authentik, couchdb, audiobooks, linkwarden, stirling-pdf, mealie, paperless, immich, n8n
**Internal**: Blocky LAN-client DNS (nodes + CoreDNS use public upstream since 2026-06-04 — see Blocky row), Traefik Ingress. Cluster DNS = `coredns-ha` **DaemonSet** (2026-06-05, was Deployment whose soft-spread skewed to 0-on-a-node → 06-04 wn2 pod-DNS outage): 1 replica/node behind kube-dns `10.43.0.10`
**Domain**: h0melab.work

---

## STORAGE

- worker-node: 4.22TB LVM (2 NVMe SSDs), 19 PVCs migrated
- worker-node-2: 863GB extra
- NAS: Zettlab 6 Ultra (14TB, 500GB backup cap)

---

## REBUILDERD (Arch contribution)

- worker-node: 6 CPU, 18GB RAM cap, 24/7 (reduced from 32G after host OOM 2026-04-26). repro+worker on `/mnt/k8s-storage` (4.2T).
- worker-node-2: 4 CPU, 8GB RAM cap (MemoryHigh=6G), 24/7 (reduced 12G→8G after cosmic-launcher build caused 6 pod CrashLoops 2026-05-22). repro+worker on cramped `/mnt/extra-storage` (863G) = kubelet nodefs → **DiskPressure-prone** (2026-05-25 reboot-orphaned nspawn roots evicted pods; relocate to `/mnt/k8s-storage` is the root fix, PENDING).
- Build timeout 48h. **Daily** repro-cleanup timer (weekly `Sun 08:00`→daily 2026-05-25): orphan nspawn build-roots + `.#machine.root*` snapshots + `paccache -rk2` of the per-name worker dep-cache (archlinux-repro never prunes it → W2 287G / W1 319G unbounded before fix). Both workers via `roles/rebuilderd/`.

---

## PENDING ITEMS

| Item | Target | Priority |
|------|--------|----------|
| Drop worker-node-2 replication step | ~2026-07-20 | P2 |
| n8n PgBouncer `statement_timeout` fix — re-check #25705 (re-verified OPEN 2026-06-05, no upstream movement since 2026-04-28) | 2026-07-04 | P3 |
| High-pri secret rotation (PG: authentik/immich/n8n, MySQL: HA, Redis: immich) | 2026-07-01 | P1 |
| Evaluate enabling WebAuthn client hints in Authentik blueprints — #20700 CLOSED upstream 2026-03-13, cluster on 2026.5.2 since 2026-05-28 (unblocked at 2026-06-05 review) | 2026-07-04 | P3 |
| Watch Authentik #18232 (TOTP/WebAuthn pk collision in MFA Devices UI) | Backlog | P3 |
| Watch Authentik #19580 (multi-passkey wrong-pick) — relevant if enrolling 2nd passkey | Backlog | P3 |
| Passkey-only login watch — real login verified 2026-06-05 (user, immich→Authentik OIDC); close 06-19 if no lockout edge cases (new device, post-reboot, Conditional UI) | 2026-06-19 | P3 |
| Relocate worker-node-2 rebuilderd (repro + worker dep-cache) off cramped 863G `/mnt/extra-storage` → spacious 3.6T `/mnt/k8s-storage` (mirror W1) — eliminates DiskPressure recurrence at the source; daily `paccache -rk2` is the interim mitigation. Needs finding the workdir knob (rebuilderd-worker internal default / conf `[build]`) + data migration. | Backlog | P2 |
| Cluster CPU/memory right-sizing analysis — VMSingle PVC bound 2026-04-06; 90d data depth reached ~2026-07-05. Run after monthly cron cycles captured (security scan 1st, weekly Sat reboot, paccache, log rotation). Workload: per-namespace p95/p99 CPU + memory vs requests/limits, identify over/under-provisioned (use `vmq` helper). Popeye 2026-06-05 POP-109/110 warns (PODS section 19%) = input data | 2026-07-06 | P2 |
| Image-CVE scanning decision — NO scanner in stack (trivy absent from cluster/CI/nodes; renovate freshness ≠ CVE scan). Options: trivy-operator (in-cluster, costs resources), trivy in CI (image list scan, free), or accept-as-is documented | 2026-07-04 | P3 |
| Investigate `databases/main-mysql-mysql-proxy` Service — Popeye POP-1100 "no pods match selector" (proxy disabled in Percona CR → operator still creates svc?); also POP-1106 named-port lints on Percona/Redis operator svcs (cosmetic, services work live) | 2026-07-04 | P3 |
| UR2-4 seccomp Audit→Enforce: `require-seccomp-runtimedefault` hard-anchored but Audit (UR2 2026-06-06); ~22 operator/chart pods lack `seccompProfile:RuntimeDefault` (couchdb, mysql/orc, redis-op, immich-server, loki+alloy, node-exporter, ps-operator). Add via chart values/postRenderer, track PolicyReport fails→0, then flip Enforce (kyverno-policy-promotion skill) | 2026-07-04 | P2 |
| UR2 audit-found DEAD alerts (predate UR2; via `_shared/vmrules-metric-audit.sh`): `mysql_slave_status_*`×3 (mysql-exporter scrapes the primary/haproxy, replica never directly scraped → SHOW REPLICA STATUS empty), `certmanager_certificate_renewal_failure_count` (wrong/absent metric name), `loki_compactor_running` (compactor not running in current Loki mode). Verify each live + fix metric or remove alert | 2026-07-04 | P3 |
| UR2 P3 security leads (verify-then-fix): 3 Kyverno `=()` soft-anchor footguns (require-labels / require-non-root / require-non-default-serviceaccount — same class as the seccomp toothless bug, pair with the Audit pass); homepage + claude-telegram ClusterRoles grant cluster-wide secret get/list (scope down or document); home-assistant NP admits ALL namespaces to UI port 8123 (scope ingress to traefik + cloudflare-tunnel) | 2026-07-04 | P3 |
| UR2 P3 DR/backup: CouchDB restore in `.backup/README.md` calls `couchrestore` inside the couchdb pod (no such binary — run from a node container w/ @cloudant/couchbackup); CNPG has no WAL archiving/PITR/ScheduledBackup (decision: add barman objectStore, or document pg_dump-only + drop empty backup dashboard panels) | 2026-07-04 | P3 |
| UR2 P3-1 + cleanup: Flux healthCheck-gated Kustomizations `timeout: 45s` < dependency cold-start budget (false-failed reconciles on reboot) → raise to ≥2m on infra-configs/monitoring-configs; delete orphaned `scripts/analyze-update/` Go reimpl (dependabot gomod already removed 2026-06-06; workflow uses the `.sh`) | Backlog | P3 |
| UR2 monitoring watch: confirm no NEW false-positive alert storms from the ~13 newly-live VMAlert rules (Batch A 2026-06-06 made dead alerts live; 4 latent false-positives already fixed). Run `_shared/vmalert-state.sh` at next review; close if clean | 2026-07-04 | P3 |

**Next Review**: 2026-07-04 (monthly + quarterly automation audit, same day). Last: 2026-06-05.

### Monthly Review Checklist

**Canonical procedure = `homelab-monthly-review` skill** (`~/.claude/skills/homelab-monthly-review/SKILL.md`, since 2026-06-05). Phases: prep → **posture sweep** (node security scans no-sudo, Kyverno polr, Popeye score diff, alerts, Flux/CI, certs, backups, disk, DB health + primary-pin drift, stale resources, renovate) → stocktake + CODEMAPS (parallel agents + fact block) → pending sweep + upstream re-checks → actions (worktree + /gitops-workflow, decisions batched via one ask) → docs/memory/chezmoi-sync.

Why skill, not inline list: 2026-06-05 review followed the old 3-item checklist (scan rollup, stocktake, CODEMAPS) and missed Kyverno/Popeye/image-CVE posture until asked — checklist-following ≠ completeness. Skill holds the full surface table + commands; this section stays a pointer so the two never drift.

CODEMAPS last refresh: 2026-06-05.

### Quarterly Review (every 3 months — next: 2026-07-04)

**Automation audit** — full inventory of cron/timers/CronJobs/GHA workflows/hooks/MCP servers/connectors. Finds overlap, breakage, stale automations that built up since last review.

```
ECC skill: /automation-audit-ops
```

Output: keep / merge / cut / fix-next per surface. Run quarterly OR post-incident. Monthly = noise (audit takes ~30min, value is in delta over weeks).

---

## CHANGELOG

*Monthly reviews, full changelog, done items: [HOMELAB_HISTORY.md](./HOMELAB_HISTORY.md) + `git log --all -- docs/HOMELAB_ANALYSIS.md`*

**Recent highlights** (2026):
- 2026-06-05: **Monthly review** — security-scan rollup June vs May: warnings 95→32/94→31/94→31 (CP/W1/W2, −66%, propupd baseline effect), 0 rootkits all nodes. UFW heal v5 **validated PASS** (W1 kernel 6.18.33-1-lts upgrade + reboot 2026-05-31 22:35, UFW + watchdog active, no outage). Blocky memory-limit review closed **keep 512Mi** (30d peak 365Mi — 384Mi target would leave 5% headroom; limit ≠ reservation). Redis HA operator health verified (3-sentinel quorum OK, full alert ruleset). n8n #25705 still open (no movement since 04-28) → 07-04. Authentik client-hints unblocked (#20700 closed upstream, cluster on 2026.5.2) → evaluate 07-04. Redis failover smoke test **PASS** (sentinel promotion replication-0→1, quorum held, replica lag=0, immich ioredis self-recovered <3min) + master re-pinned wn2→W1. Authentik **password binding removed** (passkey-only main flow, blueprint `40-remove-password-binding.yaml`; TOTP = recovery + new weakest path, accepted). Skill stocktake: 21 OK / 3 Improve (cluster-roll DaemonSet lines, monitoring-check baselines, np-coverage REVIEW.md ref) — fixed same day. CODEMAPS refreshed (6 agents — KPS 86.1.1, NP 64 breakdown, CNPG hardening backfill, 9 app image rows).
- 2026-06-04: **Configs base/staging flatten** (`081934c0` mon + `87deba9e` infra) — flattened the last two overlay splits (`monitoring/configs` + `infrastructure/configs`) to flat single-env dirs. Render byte-identical (63 mon / 133 infra res) → zero churn. Dropped redundant ns transforms (kps + databases/couchdb), deleted dead `base/resource-governance`, renamed colliding mysql SA file (`main-mysql` vs `mysql-jobs`). No base/staging splits remain repo-wide.
- 2026-05-23: **Ultrareview** — 4-agent consensus (arch + k8s/Flux + security + cruft). REVIEW.md retired 2026-06-05 after full closure (record in git history). Findings: 1 P0 (Cloudflare ACCOUNT_ID + tunnel UUID plaintext in `cloudflared.yaml:53-54` `command:` field, SOPS does not cover commands — move to encrypted Secret env vars; no regen needed, account ID is non-secret + tunnel credentials JSON already SOPS-encrypted), 11 P1, 17 P2, 9 P3. Top P1: 3 Kyverno policies in Audit not Enforce (`disallow-host-path`, `require-non-root`, `require-resource-limits`); `require-resource-limits` skips `initContainers`; `disallow-privilege-escalation` + `require-drop-all-capabilities` use optional `=()` patterns (containers omitting fields pass); no Kyverno for NetworkPolicy presence or `readOnlyRootFilesystem`; `monitoring-*` Flux Kustomizations lack `dependsOn`+`healthChecks` (bootstrap race); `apps.yaml` `wait: false` + `healthChecks` contradict (dead config); Immich/uptime-kuma/n8n/claude-telegram egress gaps. Doc drift: 44 NPs → 40, "100% PSS" misleading. 13 .DS_Store tracked + closed-PR baselines + stale Popeye report + `docs/superpowers/` archive candidates. CI gaps: no kubeconform/yamllint/SOPS-check/shellcheck.
- 2026-05-22: Backup overhaul — +5 PVCs (mealie, n8n, audiobookshelf-config+metadata) added to daily, stale uptime-kuma removed, claude-telegram + immich-ML + loki + vmsingle + stirling-pipeline/tessdata documented as expendable. NEW `immich-backup` weekly CronJob Sunday 03:00 UTC (uncompressed tar+sha256, 62.5G in 18m21s, keep-2). Retention enforced: W1 source 30d (`find -mtime +30`), NAS prune Step 5b for both layouts — `prune_nas_file` (rsync filter `--include=<file> --exclude='*'` against empty source) for postgres/mysql/couchdb files, `prune_nas_dir` for pvc + immich. File-vs-dir bug found mid-test + fixed (commit `73f7a611`). Redis cache+queue/broker confirmed via key inspection (BullMQ + Celery + Django sessions + TTL'd cache) — **no backup needed**, documented.
- 2026-05-22: Drift-heal mid-flight ansible-core upgrade race — manual `pacman -Syu` (ansible-core 2.20.5→2.21.0) collided with 10-min drift-heal timer; in-memory ConfigManager stayed on old import while reloaded `copy.py` passed `templar=` kwarg → TypeError on `base_config : Deploy /etc/logrotate.d/pacman`. Fix (commit `3b5696d7`): drift-heal gets `ExecCondition='[ ! -e /var/lib/pacman/db.lck ]'` (skip cycle if pacman locked); phase1 gets `ExecStartPre=pacman -Sy --noconfirm --needed ansible ansible-core` (pre-upgrade runtime so `yay -Syu` inside playbook can't bump it mid-flight). No version pinning — Arch stays rolling.
- 2026-05-19: IPv6 flap fix — pinned `node-ip` to IPv4 on all 3 nodes (ansible `k3s_config` role, `host_vars`). Root cause: two IPv6 addresses (ISP GUA `2a01:4b00:…` with ~1hr preferred lifetime vs eero ULA `fd00::…` permanent) fought for primary position → kubelet updated Node object ~8K times/week. Fix: `node-ip: <ipv4>` in `/etc/rancher/k3s/config.yaml` → k3s ignores IPv6 entirely. OS-level IPv6 intentionally kept (ISP provides it, no functional dependency in cluster but no reason to disable). Residual info-level "NodeIPs changed" log noise (~1/min) is harmless — kubelet sees NIC IPv6 but pin excludes it, zero API churn.
- 2026-05-16: UFW heal v5 + phase2 resilience overhaul — 3-layer fix for stale phase2-pending flag blocking drift-heal. L1: Flux reconcile retries+180s timeout+source-controller pre-gate in phase2.yml. L2: Restart=on-failure on phase2.service (3x at 15min). L3: ExecCondition stale-flag auto-clear (>2h + Flux healthy) on config.service. Added check-phase2-flag-age.sh. Root cause: source-controller SSH hang post-reboot (#1154) + 60s CLI timeout.
- 2026-04 → 2026-05: archived to [HOMELAB_HISTORY.md](./HOMELAB_HISTORY.md#2026-04--2026-05-detailed-changelog--archived-from-homelab_analysismd-2026-05-15-) (24 detailed entries: ansible migration, UFW heal v2-v4, drift-heal firewall race fix, kubelet lease bump, cardinality trim, UK rework, W1 incident, Blocky soak, monthly review, code review, Authentik passkey, SearXNG retire, claude-telegram bot, VM migration).
- 2026-03-16: SearXNG deploy, Authentik-CF Access IdP integration.
- 2026-03-11: NetworkPolicy K8s API egress audit (fixed Loki, Traefik, Homepage).
- 2026-03-09: Unified setup-node.sh, full node audit.
- 2026-03-07: March code review (94/100), 4 new NetworkPolicies.
