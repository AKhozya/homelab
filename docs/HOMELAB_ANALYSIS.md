# HOMELAB COMPREHENSIVE ANALYSIS

**Cluster**: K3s (staging) — 3 nodes (1 CP, 2 workers)
**Node IPs** (static DHCP, k3s pinned to IPv4): gmk-k3s-control-plane=192.168.1.127, worker-node=192.168.1.129, worker-node-2=192.168.1.126
**Infra**: GitOps (Flux), CloudNativePG, Percona MySQL, monitoring stack, SSO (Authentik), Cloudflare Tunnel
**Code Review**: 2026-04-02 — full scan (94/100, A)
**Ultrareview**: 2026-05-23 — 4-agent consensus (arch/k8s/security/cruft). See [REVIEW.md](../REVIEW.md). 1 P0 (Cloudflare IDs plaintext), 11 P1, 17 P2. No operational blocker.

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

**Key facts**: 40 NetworkPolicy resources (31 files, multi-doc). 53 SOPS secrets. **12 Kyverno policies — 8 Enforce + 4 Audit** (Wave 8 soak started 2026-05-24: F-4 `disallow-privilege-escalation`+`require-drop-all-capabilities` flipped to Audit after `=()`→mandatory-pattern rewrite; F-5 `require-networkpolicy` + F-6 `require-readonly-rootfs` new in Audit. Promote target ≥2026-05-25. CNPG pooler + vmagent init excluded via label selectors). 13 HelmReleases. 16 apps. PSS restricted on 14 namespaces; `immich` + `home-assistant` deliberately privileged (GPU/hardware); `paperless-ngx` baseline (s6-overlay /run init). NetworkPolicy coverage manual + F-5 Kyverno backstop (Audit; 40 pass/0 fail). HSTS, SSO, image-pin manually maintained — `claude-telegram:1.22` + `seleniumbase:v1.0` violate major.minor.patch (REVIEW F-23). Open findings: see [REVIEW.md](../REVIEW.md) backlog.

---

## APPS (16 total)

> Grafana = monitoring infra (see `docs/CODEMAPS/monitoring.md`), not an app.

| App | OIDC/SSO | Notes |
|-----|----------|-------|
| Homepage | - | Dashboard |
| Uptime Kuma | - | Uptime monitor, MySQL |
| Authentik | Provider | SSO, PostgreSQL (no Redis — in-memory cache), passkey-first via Conditional UI (password fallback retained) |
| Blocky | - | DNS filter + ad blocking, **HA: 2 replicas (W1+W2), single Deployment, native rolling, Redis cache sync, CNPG Postgres query log** |
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
**Internal**: Blocky local DNS, Traefik Ingress
**Domain**: h0melab.work

---

## STORAGE

- worker-node: 4.22TB LVM (2 NVMe SSDs), 19 PVCs migrated
- worker-node-2: 863GB extra
- NAS: Zettlab 6 Ultra (14TB, 500GB backup cap)

---

## REBUILDERD (Arch contribution)

- worker-node: 6 CPU, 18GB RAM cap, 24/7 (reduced from 32G after host OOM 2026-04-26)
- worker-node-2: 4 CPU, 8GB RAM cap (MemoryHigh=6G), 24/7 (reduced 12G→8G after cosmic-launcher build caused 6 pod CrashLoops 2026-05-22)
- Build timeout 48h, Sun 08:00 cleanup timer

---

## PENDING ITEMS

| Item | Target | Priority |
|------|--------|----------|
| Drop worker-node-2 replication step | ~2026-07-20 | P2 |
| n8n PgBouncer `statement_timeout` fix — re-check #25705 (verified OPEN 2026-05-07, last upstream update 2026-04-28; rescheduled to align with monthly review) | 2026-06-04 | P3 |
| High-pri secret rotation (PG: authentik/immich/n8n, MySQL: HA, Redis: immich) | 2026-07-01 | P1 |
| HA OIDC — review [hass-oidc-auth releases](https://github.com/christiaangoossens/hass-oidc-auth/releases) for HA-compat fix, enable OIDC SSO on `home-assistant` if shipped (REVIEW.md F-43) | 2026-06-04 | P3 |
| Re-evaluate Authentik 2026.5 client hints (#20700) — upstream release dependent (latest stable 2026.2.2 / RC 2026.2.3-rc1 as of 2026-05-08; ~3-4mo cadence implies 2026.5 ~mid-2026) | Backlog (watch releases) | P3 |
| Watch Authentik #18232 (TOTP/WebAuthn pk collision in MFA Devices UI) | Backlog | P3 |
| Watch Authentik #19580 (multi-passkey wrong-pick) — relevant if enrolling 2nd passkey | Backlog | P3 |
| Consider removing default-authentication-password binding once 1+ month clean passkey ops | 2026-06 | P3 |
| Blocky memory-limit review — soak (2026-05-07) peak 307Mi blocks 256Mi; reduce 512Mi → 384Mi (25% headroom) instead | 2026-05-26 | P3 |
| Redis HA operator health check (master/replica/sentinel quorum, alerts firing only on real outages) | 2026-05-26 | P3 |
| Redis HA failover smoke test (re-verify Sentinel-driven master promotion + app reconnect, post-Phase-1 stability check) | 2026-05-26 | P2 |
| Validate UFW silent-disable auto-heal on next W1 kernel upgrade — UFW heal v5 shipped 2026-05-16: 5-layer defence (modules-load, k3s-wait-ready, boot-time healer, preflight role, 5min watchdog timer). Phase2 now retries 3x at 15min (Restart=on-failure). Stale phase2-pending flag auto-clears after 2h if Flux healthy (ExecCondition on config.service). Previous incident: phase2 Flux source-controller SSH timeout blocked drift-heal all day → UFW stayed disabled 12h. Now: L1 ansible retries+180s timeout, L2 systemd retry, L3 stale flag auto-clear. PASS = kernel upgrade + reboot → UFW recovers automatically, watchdog catches stragglers. FAIL = repeat outage. Watch: `journalctl -t ufw-heal --since reboot`, `systemctl is-active ufw-heal-watchdog.timer`, telegram drift-heal alerts. | next W1 kernel upgrade | P2 |
| Cluster CPU/memory right-sizing analysis — VMSingle PVC bound 2026-04-06; 90d data depth reached ~2026-07-05. Run after monthly cron cycles captured (security scan 1st, weekly Sat reboot, paccache, log rotation). Workload: per-namespace p95/p99 CPU + memory vs requests/limits, identify over/under-provisioned (use `vmq` helper). | 2026-07-06 | P2 |

**Next Review**: 2026-06-04 (monthly) — 2026-05-02 review run early in lieu of 2026-05-04

### Monthly Review Checklist

**1. Security scan rollup** — pull security-scan summaries from 3 nodes, diff prior month, doc deltas in review commit.

```bash
for node in "akhozya@gmk-k3s-control-plane" "akhozya@worker-node" "z3us@worker-node-2"; do
  echo "=== $node ==="
  ssh -p 65300 "$node" "sudo cat /var/log/node-maintenance/security-scan-$(date -u +%Y-%m).log 2>/dev/null | tail -120"
done
```

Source of truth:
- `/var/log/node-maintenance/security-scan-YYYY-MM.log` (per-node summary, 12mo retention)
- `/var/log/lynis-report.dat`, `/var/log/rkhunter.log` (full output, 6mo via logrotate)
- Timer: `node-maintenance-security-scan.timer` — 1st of month 04:00 UTC, all 3 nodes

**2. Skill stocktake** — actualise homelab skills against current cluster state. Catches stale tool refs (e.g. removed pods), missing frontmatter, content drift vs CLAUDE.md.

```
/skill-stocktake          # quick scan if results.json present
/skill-stocktake full     # full re-eval, 20-30 min
```

Cache: `~/.claude/skills/skill-stocktake/results.json`. Cleanup pattern: Retire/Improve/Update verdicts → user-confirmed batch fix.

**3. CODEMAPS refresh** — actualise `docs/CODEMAPS/*.md` against current cluster state. Snapshots drift silently (image bumps, ns moves, version pins, app add/remove, helm chart bumps). Dispatch parallel agents (one per codemap) with a pre-gathered live-cluster fact block to avoid redundant `kubectl` runs.

```bash
# Live-state snapshot to brief agents
kubectl get nodes -o wide
kubectl get helmrelease -A
kubectl get clusters.postgresql.cnpg.io,redisreplication,redissentinel -A
kubectl get cronjob,networkpolicy,clusterpolicy -A
kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort -u
cat apps/staging/kustomization.yaml
```

Files: `architecture.md`, `apps.md`, `networking.md`, `databases.md`, `monitoring.md`, `backup-restore.md`. Each agent: read current codemap → diff against source-of-truth dirs (apps/, infrastructure/, monitoring/, .backup/) → Write updated content. Last refresh: 2026-05-22.

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
- 2026-05-23: **Ultrareview** — 4-agent consensus (arch + k8s/Flux + security + cruft). See [REVIEW.md](../REVIEW.md). Findings: 1 P0 (Cloudflare ACCOUNT_ID + tunnel UUID plaintext in `cloudflared.yaml:53-54` `command:` field, SOPS does not cover commands — move to encrypted Secret env vars; no regen needed, account ID is non-secret + tunnel credentials JSON already SOPS-encrypted), 11 P1, 17 P2, 9 P3. Top P1: 3 Kyverno policies in Audit not Enforce (`disallow-host-path`, `require-non-root`, `require-resource-limits`); `require-resource-limits` skips `initContainers`; `disallow-privilege-escalation` + `require-drop-all-capabilities` use optional `=()` patterns (containers omitting fields pass); no Kyverno for NetworkPolicy presence or `readOnlyRootFilesystem`; `monitoring-*` Flux Kustomizations lack `dependsOn`+`healthChecks` (bootstrap race); `apps.yaml` `wait: false` + `healthChecks` contradict (dead config); Immich/uptime-kuma/n8n/claude-telegram egress gaps. Doc drift: 44 NPs → 40, "100% PSS" misleading. 13 .DS_Store tracked + closed-PR baselines + stale Popeye report + `docs/superpowers/` archive candidates. CI gaps: no kubeconform/yamllint/SOPS-check/shellcheck.
- 2026-05-22: Backup overhaul — +5 PVCs (mealie, n8n, audiobookshelf-config+metadata) added to daily, stale uptime-kuma removed, claude-telegram + immich-ML + loki + vmsingle + stirling-pipeline/tessdata documented as expendable. NEW `immich-backup` weekly CronJob Sunday 03:00 UTC (uncompressed tar+sha256, 62.5G in 18m21s, keep-2). Retention enforced: W1 source 30d (`find -mtime +30`), NAS prune Step 5b for both layouts — `prune_nas_file` (rsync filter `--include=<file> --exclude='*'` against empty source) for postgres/mysql/couchdb files, `prune_nas_dir` for pvc + immich. File-vs-dir bug found mid-test + fixed (commit `73f7a611`). Redis cache+queue/broker confirmed via key inspection (BullMQ + Celery + Django sessions + TTL'd cache) — **no backup needed**, documented.
- 2026-05-22: Drift-heal mid-flight ansible-core upgrade race — manual `pacman -Syu` (ansible-core 2.20.5→2.21.0) collided with 10-min drift-heal timer; in-memory ConfigManager stayed on old import while reloaded `copy.py` passed `templar=` kwarg → TypeError on `base_config : Deploy /etc/logrotate.d/pacman`. Fix (commit `3b5696d7`): drift-heal gets `ExecCondition='[ ! -e /var/lib/pacman/db.lck ]'` (skip cycle if pacman locked); phase1 gets `ExecStartPre=pacman -Sy --noconfirm --needed ansible ansible-core` (pre-upgrade runtime so `yay -Syu` inside playbook can't bump it mid-flight). No version pinning — Arch stays rolling.
- 2026-05-19: IPv6 flap fix — pinned `node-ip` to IPv4 on all 3 nodes (ansible `k3s_config` role, `host_vars`). Root cause: two IPv6 addresses (ISP GUA `2a01:4b00:…` with ~1hr preferred lifetime vs eero ULA `fd00::…` permanent) fought for primary position → kubelet updated Node object ~8K times/week. Fix: `node-ip: <ipv4>` in `/etc/rancher/k3s/config.yaml` → k3s ignores IPv6 entirely. OS-level IPv6 intentionally kept (ISP provides it, no functional dependency in cluster but no reason to disable). Residual info-level "NodeIPs changed" log noise (~1/min) is harmless — kubelet sees NIC IPv6 but pin excludes it, zero API churn.
- 2026-05-16: UFW heal v5 + phase2 resilience overhaul — 3-layer fix for stale phase2-pending flag blocking drift-heal. L1: Flux reconcile retries+180s timeout+source-controller pre-gate in phase2.yml. L2: Restart=on-failure on phase2.service (3x at 15min). L3: ExecCondition stale-flag auto-clear (>2h + Flux healthy) on config.service. Added check-phase2-flag-age.sh. Root cause: source-controller SSH hang post-reboot (#1154) + 60s CLI timeout.
- 2026-04 → 2026-05: archived to [HOMELAB_HISTORY.md](./HOMELAB_HISTORY.md#2026-04--2026-05-detailed-changelog--archived-from-homelab_analysismd-2026-05-15-) (24 detailed entries: ansible migration, UFW heal v2-v4, drift-heal firewall race fix, kubelet lease bump, cardinality trim, UK rework, W1 incident, Blocky soak, monthly review, code review, Authentik passkey, SearXNG retire, claude-telegram bot, VM migration).
- 2026-03-16: SearXNG deploy, Authentik-CF Access IdP integration.
- 2026-03-11: NetworkPolicy K8s API egress audit (fixed Loki, Traefik, Homepage).
- 2026-03-09: Unified setup-node.sh, full node audit.
- 2026-03-07: March code review (94/100), 4 new NetworkPolicies.
