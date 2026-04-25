# HOMELAB COMPREHENSIVE ANALYSIS

**Cluster**: K3s (staging) — 3 nodes (1 CP, 2 workers)
**Node IPs** (static DHCP): gmk-k3s-control-plane=192.168.1.127, worker-node=192.168.1.129, worker-node-2=192.168.1.126
**Infra**: GitOps (Flux), CloudNativePG, Percona MySQL, monitoring stack, SSO (Authentik), Cloudflare Tunnel
**Code Review**: 2026-04-02 — full scan (94/100, A)

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

**Key facts**: 0 P0/P1. 40 NetworkPolicies. 51 SOPS secrets. 10 Kyverno policies (7 enforce, 3 audit, 0 violations). 100% PSS, NetworkPolicy, HSTS, SSO, image-pin coverage.

---

## APPS (17 total)

| App | OIDC/SSO | Notes |
|-----|----------|-------|
| Homepage | - | Dashboard |
| Uptime Kuma | - | Uptime monitor, MySQL |
| Authentik | Provider | SSO, PostgreSQL + Redis, passkey-first via Conditional UI (password fallback retained) |
| AdGuard Home | - | DNS filter, **HA: 2 pods (W1+W2), per-instance LB IPs 192.168.1.129/126** |
| Stirling PDF | OIDC | PDF toolkit |
| HomeHub | - | Family dashboard, local only |
| Grafana | OIDC | Monitoring dashboard |
| Immich | OIDC | Photo mgmt |
| Paperless-NGX | OIDC | Doc mgmt |
| Home Assistant | OIDC | Smart home, MySQL |
| LinkWarden | OIDC | Bookmarks + Meilisearch |
| Mealie | OIDC | Recipes |
| N8N | Enterprise | Automation (SSO = Enterprise) |
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
| Redis | 1 | No (cache) | - | Authentik, Paperless, Immich |
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

**Cloudflare Tunnel** (10 svcs): authentik, couchdb, audiobooks, linkwarden, stirling-pdf, mealie, paperless, immich, n8n, search
**Internal**: AdGuard local DNS, Traefik Ingress
**Domain**: h0melab.work

---

## STORAGE

- worker-node: 4.22TB LVM (2 NVMe SSDs), 19 PVCs migrated
- worker-node-2: 863GB extra
- NAS: Zettlab 6 Ultra (14TB, 500GB backup cap)

---

## REBUILDERD (Arch contribution)

- worker-node: 6 CPU, 32GB RAM cap, 24/7
- worker-node-2: 4 CPU, 14GB RAM cap, 24/7
- Build timeout 48h, Sun 08:00 cleanup timer

---

## PENDING ITEMS

| Item | Target | Priority |
|------|--------|----------|
| Drop worker-node-2 replication step | ~2026-05-20 | P2 |
| n8n PgBouncer `statement_timeout` fix — re-check #25705 | 2026-05 | P3 |
| High-pri secret rotation (PG: authentik/immich/n8n, MySQL: HA, Redis: immich) | 2026-07-01 | P1 |
| Re-check HA OIDC when hass-oidc-auth stable lands | Backlog | P3 |
| Re-evaluate Authentik 2026.5 client hints (#20700) | 2026-06 | P3 |
| Watch Authentik #18232 (TOTP/WebAuthn pk collision in MFA Devices UI) | Backlog | P3 |
| Watch Authentik #19580 (multi-passkey wrong-pick) — relevant if enrolling 2nd passkey | Backlog | P3 |
| Consider removing default-authentication-password binding once 1+ month clean passkey ops | 2026-06 | P3 |

**Next Review**: 2026-05-04 (monthly)

### Monthly Review Checklist

Pull security-scan summaries from 3 nodes, diff prior month, doc deltas in review commit.

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

---

## CHANGELOG

*Monthly reviews, full changelog, done items: [HOMELAB_HISTORY.md](./HOMELAB_HISTORY.md) + `git log --all -- docs/HOMELAB_ANALYSIS.md`*

**Recent highlights** (2026):
- 2026-04-22: **W1 canary reboot + phase2 rebuilderd fleet-wide pause**. Canary-rebooted W1 to validate L1 `ufw-heal-post-k3s.service` under real kube-router race — healer fired at 18:52:19, phase-a hit 120s cap (settle timeout fallback), phase-b reload attempt 1 success, phase-c chain repair clean, phase-e final reload success, probe set healthy, UFW active post-heal. `ufw_state.prom` → 1/1/1. L1 validated end-to-end. Blast radius: zero (2 authentik pods evicted from W1 rescheduled to W2, cold image pull took 7m51s on busy rebuilderd box). Root cause of slow pull: W2's `rebuilderd-worker@1.service` was running 13x python3 build fan-out at ~330% CPU + mem tight (1.1G free, 3.6G swap in use) — disk/network contention. **Fix**: added PLAY 0.5 to `ansible/phase2.yml` (fires post-CP-stabilize, mass-stops `rebuilderd-worker@1.service` on all workers in parallel). `rebuilderd-worker-boot.timer` re-arms each worker at +10min post-its-own-reboot — no explicit restart needed. Per-node stop in PLAY 1 kept as belt-and-suspenders no-op.
- 2026-04-21: **UFW resilience overhaul + drift-heal retry policy**.
  - **Weekly cluster update** ran successfully (phase1 CP + phase2 rolling workers, 0 failures, 16min total). Added CP stabilize pause (4min, Flux + kube-system + traefik + flux-controllers readiness gates) to phase2 PLAY 0 before worker rollout. Bumped CP + per-node stabilize to 4min for DB (CNPG + Percona) failover safety.
  - **W1 post-update UFW broke** again — identified deeper root cause via research (UFW #1987227/#1294544 + K3s #1280/#9807): `ufw-init`'s `ip6tables-restore` silently partial-loads when kube-router + fail2ban race-mutate kernel nft state at boot, leaving `ufw6-logging-deny` + `ufw6-user-*` chains missing. Shipped **3-layer fix**:
    - **L1 — boot healer** `ufw-heal-post-k3s.service` (replaces flaky `ufw-reload-after-k3s.service`): 6-phase bash script — poll kube-router quiescence → `ufw reload` ×3 → per-chain `ip6tables -N` repair (race-free) → verify canary probe set → final reload → status check. 5min timeout.
    - **L2 — drift-heal pre-heal hardened**: `ufw reload` ×3 + detect missing chains + per-chain `iptables -N` / `ip6tables -N` recovery from UFW rules files. Also added `until/retries=5, delay=10s` to every `community.general.ufw` task (SSH rule, default policies, rules loop, routes loop, enable) — survives transient races during module's internal `ufw status verbose`.
    - **L3 — Prometheus alerts**: new VMRule `firewall-alerts` group (UfwDisabled/UfwServiceInactive/UfwChainsUnhealthy, all critical, `for: 5m`). Metrics from `ufw-state-metric.sh` (60s timer, textfile collector) — `ufw_enabled`/`ufw_service_active`/`ufw_chains_healthy` per node. VMRule path: `monitoring/configs/base/victoria-metrics/vmrules.yaml` (vm-operator doesn't auto-convert PrometheusRule → VMRule is source of truth).
  - **Drift-heal retry policy** (Wave 1 + 2): `until/retries` added to all pacman installs (`retries=3, delay=30` — mirror 5xx/GPG/lock races), `fwupdmgr update` (`retries=3, delay=20` — LVFS 5xx), `systemd-resolved` restart handler (`retries=2, delay=5`). Not retried (fail-loud): sshd config validate, preflight health gates, local file ops.
  - **Sync service timeout bump**: `node-maintenance-sync.service TimeoutStartSec=5min → 20min`. 5min was tight when inner config playbook retries stack; two syncs got killed mid-run during 5x stability test even though playbooks finished OK. 20min gives 5min headroom over config's 15min cap.
  - 5x idempotency stress test: 4 consecutive playbook runs, 0 failed, 0 retries triggered — UFW module + pacman passed first attempt every time. Retry machinery = safety net, not routine path.
  - All metrics `1/1/1` on CP, W1, W2 after fix. VMRule `firewall-alerts` loaded in vmalert, 3 rules `inactive/ok`.
  - Memory: existing `gotcha_ufw_ip6tables_post_reboot.md`; retry policy documented in `docs/scripts/node-maintenance/README.md` under "Resilience".
- 2026-04-24: **claude-telegram chezmoi-init OOM fix** — init container OOMKilled at 512Mi limit during `npm update -g @anthropic-ai/claude-code` + `bun update @anthropic-ai/claude-agent-sdk`. Bumped to `requests 256Mi / limits 1Gi` (cpu `100m/1000m`). Rolled clean on worker-node-2. Commit `3b2d77e8`.
- 2026-04-20: **W1 post-reboot UFW ip6tables heal** — drift-heal started failing on worker-node at firewall role (`ufw status verbose` → `ERROR: problem running ip6tables`) after W1 reboot 2026-04-19 15:06 BST. Manual `sudo ufw default deny routed` on W1 triggered ufw reload → rebuilt ip6tables → state clean. Re-ran `node-maintenance-config.service` → `worker-node: ok=66 failed=0`. Prevention: added `ufw-reload-after-k3s.service` (oneshot, `After=k3s.service k3s-agent.service ufw.service`, `sleep 15` + `ufw reload`) to `firewall` role tasks + `Reload systemd` handler. Deployed to all 3 nodes via drift-heal. **Superseded 2026-04-21 by `ufw-heal-post-k3s.service`** (6-phase healer — original was too naive for kube-router race window). Memory: `gotcha_ufw_ip6tables_post_reboot.md`.
- 2026-04-20: **Authentik passkey-first migration** — `IdentificationStage.webauthn_stage` (Conditional UI autofill since 2025.12) + `passwordless_flow` (button fallback) wired via 4 custom blueprints in ConfigMap `authentik-blueprints-custom` mounted at `/blueprints/custom/` on server + worker. WebAuthn setup stage tightened to `resident_key_requirement=required` + `user_verification=required`, bound to `default-user-settings-flow` at order 30 for voluntary enrollment. MFA validate enforces `device_classes=[webauthn, totp]` (TOTP retained as recovery 2FA method) + `not_configured_action=configure` + inline `configuration_stages=[webauthn-setup]` (new users still forced to enroll passkey, TOTP not auto-enrolled). Password stage at order 20 of main flow retained as recovery path. RPID stays `authentik.h0melab.work` (preserved). Fresh akadmin passkey re-enrolled 2026-04-20 (zombie 2025-10-21 row had `rp_id=null`, deleted via API). Smoke: 6a Conditional UI + 6b passwordless button + 6c password fallback + 6d OIDC delegation all pass. API path for blueprint instances is `/api/v3/managed/blueprints/?page_size=100` (not `/blueprints/instances/`). Spec: `docs/superpowers/specs/2026-04-19-authentik-passkey-design.md`. Plan: `docs/superpowers/plans/2026-04-19-authentik-passkey.md`. Runbook: `docs/scripts/runbooks/authentik-passkey-rollback.md`.
- 2026-04-19: Docs cleanup — deleted 5 stale .md (3 reports + 2 superseded telegram plans v1/v2); HA+PriceBuddy label fix MariaDB→MySQL; caveman-compress 37 repo + 20 memory .md; HOMELAB_ANALYSIS changelog consolidated. MariaDB orphan CRD/CR purge (Phase F fallout): stripped finalizers on 3 sibling CRDs + 13 CRs, cascade-deleted.
- 2026-04-25: **SearXNG retired** — Google rate-limit (429) + low-quality fallback engines. Removed: ns/searxng, `apps/{base,staging}/searxng/`, NetworkPolicy egress (traefik + cloudflared), CF tunnel `search.h0melab.work` route. Manual cleanup needed: Cloudflare DNS CNAME for `search.h0melab.work`. Apps 18 → 17.
- 2026-04-18 → 04-19: **Node config → ansible migration complete** (Phases A-F, 9 roles, plan closed). Roles (apply order): `packages` (pacman declarative + per-host ucode/GPU via host_vars), `base_config` (logrotate/journald 99-caps.conf/sudoers/node-maintenance user/rebuilderd TimeoutStopSec), `k3s_config` (templated config.yaml, drift-alert only, no auto-restart), `k3s_image_gc`, `firewall` (UFW, community.general.ufw additive, lockout-safe), `hardening` (15 configs: sshd/3 sysctls/kubelet/3 k3s service.d/systemd watchdog/resolved LLMNR/NVMe-APST/2 udev/2 tmpfiles.d), `security_scan` (monthly lynis+rkhunter, `/var/log/node-maintenance/security-scan-YYYY-MM.log`, first run 2026-05-01), `rebuilderd` (workers-only resources.conf + units), `ad_hoc` (tag-gated `never` firmware task). Daily drift-heal `node-maintenance-config.timer` (03:00 UTC) → Telegram on `changed>0`/fail. W2 `k3s_data_dir: /mnt/k8s-storage/k3s` host_var captured live state (would have wiped first apply). W1 `/var/lib/rancher` symlink replaced by explicit `data-dir` (zero data move). Drift caught first run: CP missing `inetutils/mesa/vulkan-intel/ufw-extras`; W2 missing `ethtool/go/mesa/vulkan*`. setup-node.sh 706→218 lines (-69%), bootstrap-only (ansible stack CP-only + AUR yay + optional firmware). install-worker.sh 182→50 (-72%). Retired scripts: `setup-ufw-k3s-*`, `setup-rebuilderd-worker-*`, `enable-crash-logging`. Legacy configs ansible-cleaned: 51-kptr-restrict, 99-security-hardening, cpu-governor. Plan: `docs/superpowers/plans/2026-04-18-node-config-ansible.md`.
- 2026-04-18: **Node-maintenance system live** — weekly updates `node-maintenance.timer` (Sat 04:30 UTC, Ansible-driven phase1 CP→reboot→phase2 worker loop, SOPS SSH key, Telegram alerts, node-maintenance user). Auto-sync `*:0/10` via read-only GH deploy key (`/root/.ssh/homelab-deploy`), runs `install.sh --sync-only` on HEAD change. Observability: Alloy `loki.source.journal` ingests phase1/2 + sync logs; Grafana dashboard (7 panels, VM+Loki); `NodeMaintenanceMissedRun` VMRule (>8d). E2E fixes: amtool silences (bundled Alertmanager pod), ExecStopPost `$SERVICE_RESULT` check, `ansible_facts['*']` (2.24 prep), `inject_facts_as_vars=False`. First weekly fire 2026-04-25.
- 2026-04-18: PodDisruptionBudgets for 9 HA workloads (authentik server/worker, traefik, cloudflared, main-postgres-rw-pooler, main-mysql-haproxy, main-mysql-orc, couchdb, alertmanager). `minAvailable: 1` 2-replica; `maxUnavailable: 1` 3-replica. CNPG/Percona/Kyverno operator PDBs cover primaries. Node cron/timer audit closed (P3) — no migration candidates.
- 2026-04-13: All 3 nodes → zsh + chezmoi dotfiles (portable .zshrc template, modern CLI tools).
- 2026-04-11: Claude Telegram bot live (Agent SDK, fork of linuz90/claude-telegram-bot).
- 2026-04-09: VictoriaMetrics migration (71% RAM save).
- 2026-04-02: April monthly review, full secrets rotation.
- 2026-03-16: SearXNG deploy, Authentik-CF Access IdP integration.
- 2026-03-11: NetworkPolicy K8s API egress audit (fixed Loki, Traefik, Homepage).
- 2026-03-09: Unified setup-node.sh, full node audit.
- 2026-03-07: March code review (94/100), 4 new NetworkPolicies.
