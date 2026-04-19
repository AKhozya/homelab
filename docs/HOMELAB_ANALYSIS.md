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

## APPS (18 total)

| App | OIDC/SSO | Notes |
|-----|----------|-------|
| Homepage | - | Dashboard |
| Uptime Kuma | - | Uptime monitor, MySQL |
| Authentik | Provider | SSO, PostgreSQL + Redis |
| AdGuard Home | - | DNS filter |
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
| SearXNG | - | Privacy search |
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
- 2026-04-19: Docs cleanup — deleted 3 stale reports (CODE_REVIEW_2025_12_23, BACKUP_VALIDATION_REPORT, ANALYSIS_IMPROVEMENT_PLAN) + 2 superseded telegram plans (v1 hostPath, v2 PVC). HA + PriceBuddy label fix MariaDB→MySQL. Caveman-compress 37 repo + 20 memory .md files.
- 2026-04-19: MariaDB orphan CRD/CR cleanup (Phase F K3s restart). `mariadbs.k8s.mariadb.com` CRD already deleted but 3 sibling CRDs (`databases`/`grants`/`users.k8s.mariadb.com`) + 13 CRs (3 Database + 5 Grant + 5 User) left in etcd w/ operator-owned finalizers. Stripped finalizers via `kubectl patch metadata.finalizers:null`, cascade-deleted CRDs. Orphan `main-mariadb` CR (UID 64311e99-...) stuck in GC — reinstalled minimal `mariadbs` CRD, CR auto-cleaned on cascade, removed CRD. GC error loop benign, clears next K3s restart.
- 2026-04-19: Node config → ansible Phase F live (consolidation) — 3 new roles. (1) `roles/packages`: declarative pacman list (30 base + 2 worker-only + per-host ucode via host_vars + per-host GPU stack via `gpu_vendor: intel|amd`). Drift caught first run: CP missing `inetutils/mesa/vulkan-intel/ufw-extras`; W2 missing `ethtool/go/mesa/vulkan*`. setup-node.sh Section 1 -35 lines → bootstrap-only (ansible stack CP-only + AUR `yay` + optional firmware). (2) `roles/k3s_config`: `/etc/rancher/k3s/config.yaml` templated per-group/host, drift-alert only (no auto-restart, mirrors kubelet.yaml). W2 `k3s_data_dir: /mnt/k8s-storage/k3s` host_var captures live state setup-node.sh heredoc missed (would have wiped first apply). W1 explicit `data-dir: /mnt/k8s-storage/rancher/k3s` replaces `/var/lib/rancher` symlink (same physical path, zero data move). (3) `roles/security_scan`: canonical `security-scan.sh` + timer + service moved `bin/` + `systemd/` → role `files/`; `install-worker.sh` 182→50 lines (-72%, dropped 100-line heredoc + unit gen). Also: `PermitEmptyPasswords no` → `sshd-99-hardening.conf` drop-in (OpenSSH first-value-wins); `fstrim.timer` + `paccache.timer` enable → `base_config`. install.sh Preconditions → fail-fast check (ansible stack bootstrapped via setup-node.sh CP-only block). Post-apply: W1 `sudo rm /var/lib/rancher` symlink (no-op dead code). Plan closed.
- 2026-04-19: Node config → ansible Phase E live — `roles/ad_hoc` tag-gated `never` tasks (skipped by daily drift-heal). Firmware task: fwupd refresh + get-updates (non-interactive), apply guarded `-e ad_hoc_firmware_apply=true`. Invoke: `sudo ansible-playbook -t firmware ... --limit <host>`. `enable-crash-logging.sh` retired — content subsumed by Phase D hardening (watchdog.conf + 99-watchdog.conf) + setup-node.sh bootloader (EFI pstore, printk dump, panic=10). `setup-claude-telegram.sh` kept Mac-side one-shot (user-env bootstrap, interactive GH token, not drift-heal target). Verify: default run skips ad_hoc (`skipped=4/5/5`, `changed=0`); `-t firmware` on W1 works. Plan closed — all 5 phases done.
- 2026-04-19: Node config → ansible Phase D live — `roles/hardening` owns 15 drift-prone configs all 3 nodes: sshd_config drop-in (post-quantum kex, strong ciphers, ETM MACs), 3 sysctl drop-ins (unified-hardening + k8s-performance + watchdog), kubelet.yaml (eviction/log rotation/streaming-idle-timeout), 3 k3s(-agent) service.d drop-ins (shutdown-timeout, conntrack-fix, network-hardening), systemd system.conf.d/watchdog.conf + DefaultTimeout{Start,Stop}Sec lineinfile, resolved LLMNR disable, modprobe NVMe-no-APST, 2 udev rules (NVMe + SATA no-PM), 2 tmpfiles.d (CPU power + NVMe). Legacy files ansible-cleaned: 51-kptr-restrict.conf, 99-security-hardening.conf, cpu-governor.conf. SSH drop-in validated `sshd -t` before reload handler. Byte-exact codify: dry-run + apply both `changed=0` all 3, SSH W1/W2 intact. setup-node.sh 706→400 lines (-43%), bootstrap-only. Orphan rebuilderd-watchdog heredoc (Phase B leftover) removed. Plan: `docs/superpowers/plans/2026-04-18-node-config-ansible.md`
- 2026-04-18: Node config → ansible Phase C live — `roles/firewall` owns UFW 3 nodes. Policies (deny in / allow out / deny routed, logging low) + base/group/host rule split (`group_vars/all.yml` 12-rule common, `group_vars/control_plane.yml` CP extras, `host_vars/worker-node*.yml` per-worker extras). `community.general.ufw`, idempotent-additive (never resets, lockout-safety). Lockout-safety SSH rule applied before policies. Rollout node-by-node CP → W1 → W2 with SSH verify between; final `changed=0` all 3. Retired `setup-ufw-k3s-{control-plane,worker}.sh`; setup-node.sh hints updated.
- 2026-04-18: Node config → ansible Phase B live — `roles/rebuilderd` (workers) owns resources.conf drop-in (host_vars per-worker CPU/mem/repro-dir), rebuilderd-metrics + watchdog + worker-boot + repro-cleanup units/scripts. `roles/k3s_image_gc` all 3. Orphan units removed: `rebuilderd-reenable-stop.*` (W1), `rebuilderd-worker-scheduled.service` (W2). Retired `setup-rebuilderd-worker-{1,2}.sh`. Live builds (qemu/scribus) uninterrupted — resources.conf byte-identical.
- 2026-04-18: Node config → ansible Phase A live — `roles/base_config` owns logrotate (pacman + node-maintenance + security-tools), journald 99-caps.conf, sudoers, node-maintenance user, rebuilderd-worker TimeoutStopSec override. New `node-maintenance-config.timer` (daily 03:00 UTC) self-heals drift; also runs post-pull via `sync-from-git.sh`. Telegram alert on `changed>0` or fail. install.sh / install-worker.sh stripped migrated heredocs (49 lines cut from worker).
- 2026-04-18: Monthly security scan live — `node-maintenance-security-scan.timer` all 3 nodes (1st of month 04:00 UTC, ±1h jitter). `lynis audit system --quick` + `rkhunter --check --sk --rwo`; writes compact summary `/var/log/node-maintenance/security-scan-YYYY-MM.log` (12mo, logrotate/security-tools). No Telegram — reviewed monthly. First run 2026-05-01; first review 2026-05-04.
- 2026-04-18: PodDisruptionBudgets added for 9 HA workloads (authentik server/worker, traefik, cloudflared, main-postgres-rw-pooler, main-mysql-haproxy, main-mysql-orc, couchdb, alertmanager). `minAvailable: 1` 2-replica; `maxUnavailable: 1` 3-replica (orc). CNPG/Percona/Kyverno operator PDBs already cover primary pods.
- 2026-04-18: Node cron/timer audit — no migration candidates. k3s-image-gc (crictl/CRI socket), logrotate (root paths), repro-cleanup (rebuilderd nspawn) need root; rebuilderd-* already run as rebuilderd user. No plain cron anywhere. P3 closed.
- 2026-04-18: Logrotate + journald caps rollout (3 nodes) — `logrotate` pkg + `logrotate.timer` enabled, `/var/log/pacman.log` + `/var/log/node-maintenance/*` + `/var/log/security-tools/*` rotated monthly/weekly, journald drop-in `99-caps.conf` (SystemMaxUse=500M, MaxRetentionSec=30d, Compress=yes).
- 2026-04-18: Node-maintenance observability (F2/F3/F4) — Alloy `loki.source.journal` ingests `node-maintenance-phase{1,2}.service` + sync.service logs (Loki hostPath /run/log/journal + /etc/machine-id, loki ns PSS enforce=privileged); Grafana dashboard (7 panels, VM + Loki); `NodeMaintenanceMissedRun` VMRule alert (>8d threshold).
- 2026-04-18: Node-maintenance E2E stabilized — silence add/expire via `amtool` (bundled Alertmanager pod, busybox wget lacked `--method=DELETE`); ExecStopPost fixed ($SERVICE_RESULT != "success" vs broken $EXIT_STATUS); `ansible_facts['*']` swap (ansible-core 2.24 prep); ansible.cfg enforces `inject_facts_as_vars=False`.
- 2026-04-18: Weekly node auto-updates live — Sat 04:30 UTC, Ansible-driven, node-maintenance user, SOPS-encrypted SSH key, Telegram alerts. Live-tested full run (all 3); next fire 2026-04-25.
- 2026-04-18: Node-maintenance auto-sync online — systemd timer CP (`*:0/10`), pulls `main` via read-only GH deploy key (`/root/.ssh/homelab-deploy`), runs `install.sh --sync-only` if HEAD changed, Telegram alert on fail. Manual trigger: `sync-node-maintenance.sh`.
- 2026-04-13: All 3 nodes → zsh + chezmoi dotfiles (portable .zshrc template, modern CLI tools).
- 2026-04-11: Claude Telegram bot live (Agent SDK, fork of linuz90/claude-telegram-bot).
- 2026-04-09: VictoriaMetrics migration (71% RAM save).
- 2026-04-02: April monthly review, full secrets rotation.
- 2026-03-16: SearXNG deploy, Authentik-CF Access IdP integration.
- 2026-03-11: NetworkPolicy K8s API egress audit (fixed Loki, Traefik, Homepage).
- 2026-03-09: Unified setup-node.sh, full node audit.
- 2026-03-07: March code review (94/100), 4 new NetworkPolicies.
