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

**Key facts**: 0 P0/P1. 44 NetworkPolicies. 55 SOPS secrets. 10 Kyverno policies (7 enforce, 3 audit, 0 violations). 100% PSS, NetworkPolicy, HSTS, SSO, image-pin coverage.

---

## APPS (17 total)

| App | OIDC/SSO | Notes |
|-----|----------|-------|
| Homepage | - | Dashboard |
| Uptime Kuma | - | Uptime monitor, MySQL |
| Authentik | Provider | SSO, PostgreSQL (no Redis — in-memory cache), passkey-first via Conditional UI (password fallback retained) |
| Blocky | - | DNS filter + ad blocking, **HA: 2 replicas (W1+W2), single Deployment, native rolling, Redis cache sync, CNPG Postgres query log** |
| Stirling PDF | OIDC | PDF toolkit |
| HomeHub | - | Family dashboard, local only |
| Grafana | OIDC | Monitoring dashboard |
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
- worker-node-2: 4 CPU, 14GB RAM cap, 24/7
- Build timeout 48h, Sun 08:00 cleanup timer

---

## PENDING ITEMS

| Item | Target | Priority |
|------|--------|----------|
| Drop worker-node-2 replication step | ~2026-05-20 | P2 |
| n8n PgBouncer `statement_timeout` fix — re-check #25705 (verified OPEN 2026-05-07, last upstream update 2026-04-28; rescheduled to align with monthly review) | 2026-06-04 | P3 |
| High-pri secret rotation (PG: authentik/immich/n8n, MySQL: HA, Redis: immich) | 2026-07-01 | P1 |
| Re-check HA OIDC when hass-oidc-auth stable lands | Backlog | P3 |
| Re-evaluate Authentik 2026.5 client hints (#20700) — upstream release dependent (latest stable 2026.2.2 / RC 2026.2.3-rc1 as of 2026-05-08; ~3-4mo cadence implies 2026.5 ~mid-2026) | Backlog (watch releases) | P3 |
| Watch Authentik #18232 (TOTP/WebAuthn pk collision in MFA Devices UI) | Backlog | P3 |
| Watch Authentik #19580 (multi-passkey wrong-pick) — relevant if enrolling 2nd passkey | Backlog | P3 |
| Consider removing default-authentication-password binding once 1+ month clean passkey ops | 2026-06 | P3 |
| Blocky memory-limit review — soak (2026-05-07) peak 307Mi blocks 256Mi; reduce 512Mi → 384Mi (25% headroom) instead | 2026-05-26 | P3 |
| Redis HA operator health check (master/replica/sentinel quorum, alerts firing only on real outages) | 2026-05-26 | P3 |
| Redis HA failover smoke test (re-verify Sentinel-driven master promotion + app reconnect, post-Phase-1 stability check) | 2026-05-26 | P2 |
| Validate UFW silent-disable auto-heal on next W1 kernel upgrade — two-layer defence shipped 2026-05-02, NOT re-tested in real conditions. Layer 1 (prevention): `kernel-modules-hook` AUR pkg installed via commit `6e01c7d0` — preserves `/lib/modules/<running-kernel>` across pacman upgrades. Layer 2 (recovery): UFW heal v4 commit `476ec535` — `phase_ufw_state_recover` (firewall-preflight) + `phase_b_reload` flush-all+force-enable (ufw-heal-post-k3s). Trigger = kernel pkg upgrade + reboot (Sat 04:30 UTC weekly maintenance, or unscheduled). Original incident: pacman removed `/lib/modules/<old-kernel>` while kernel running → modprobe `ip6table_filter` failed → ufw silently disabled → host INPUT DROP → W1 NotReady 25min, recovered manually. PASS = kernel-modules-hook keeps modules dir intact, OR (if hook fails) layer 2 auto-recovers, W1 stays Ready, 0 manual ops. FAIL = repeat 25-min outage. Watch: `journalctl -t ufw-heal --since reboot`, `pacman.log` for kernel-modules-hook, kubectl node Ready transitions, telegram drift-heal alerts. | next W1 kernel upgrade | P2 |
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

Files: `architecture.md`, `apps.md`, `networking.md`, `databases.md`, `monitoring.md`, `backup-restore.md`. Each agent: read current codemap → diff against source-of-truth dirs (apps/, infrastructure/, monitoring/, .backup/) → Write updated content. Last refresh: 2026-05-08.

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
- 2026-05-08: **CODEMAPS refresh + monthly cadence + pending sweep** (commit `aa941721`). All 6 `docs/CODEMAPS/*.md` snapshots actualised against live cluster via 6 parallel agents (one per file) briefed with pre-gathered live-state (kubectl + helm + images + cronjobs). Major drift fixes: `databases.md` PXC→Percona Server for MySQL (`ps-operator` 1.1.x), 3 mysql nodes→2+haproxy 2+orc 3 with image pins; `monitoring.md` retention 30d→90d (vmsingle 50Gi PVC), Loki+Alloy moved to own `loki` ns, VMServiceScrape 37→26+2 VMPodScrape, helm + image pins (kps 84.5.0, vm-op 0.62.1, vm v1.140.0); `apps.md` 17→16 apps (Grafana → infra section), all live image tags refreshed, Immich noted as Helm chart, middleware chain expanded; `architecture.md` Traefik ns kube-system→traefik, Kyverno 10 split 7 Enforce + 3 Audit; `networking.md` Traefik chart 40.0.0, NP per-ns counts; `backup-restore.md` CRITICAL_PVCS list verified vs YAML (10/8 apps), W2 chain noted pending. Added monthly cadence: `CODEMAPS/README.md` "When to update" lists Monthly review; `HOMELAB_ANALYSIS.md` Monthly Review Checklist new item #3 CODEMAPS refresh with kubectl snapshot commands + agent dispatch pattern, "Last refresh: 2026-05-08". Pending sweep: nothing strictly overdue (today 2026-05-08; next event = W2 replication drop 2026-05-20). Authentik 2026.5 row retargeted to "Backlog (watch releases)" — upstream still on 2026.2.x (latest 2026.2.3-rc1). UFW heal umbrella row updated to reference both layers: layer 1 prevention `kernel-modules-hook` (commit `6e01c7d0`) + layer 2 recovery heal v4 (commit `476ec535`). 2026-05-02 incident sub-items (P1 ufw line-2, P2 heal v3 ufw-disabled probe, P3 nic_tuning enp3s0→enp4s0) verified covered: P1+P2 in 476ec535 + heal v4, P3 already correct in `host_vars/worker-node.yml` (`nic_tuning_iface: enp4s0`); CP host_vars correctly retains `enp3s0` (no rename on CP).
- 2026-05-07: **Blocky soak observation closed (4d late vs 2026-05-03)**. Window 2026-04-30→2026-05-07: peak RSS 307Mi/283Mi (60% headroom on 512Mi), avg 140-156Mi, p95 latency 4.96 ms / p50 2.61 ms, log_entries 797k rows / 238 MB / ~110k/day stable, CPU throttle ≤0.24%, 0 active alerts. Restarts (4 rqbjj / 1 wwzgn) all on Sat 2026-05-04 maintenance window — Redis transient-unavail at boot (`dial 10.43.191.88:6379 connect: connection refused`), expected; pods stable 3d+ since. **Memory-limit review** (2026-05-26 row): peak 307Mi blocks 256Mi target; 384Mi acceptable (~25% headroom).
- 2026-05-04: **RebuilderdHighFailureRate flap fix**. Alert flapped firing/resolved every ~40min. Source = 2h-window gauge (`rebuilderd-metrics.sh`), denominator straddles old `total >= 20` floor on W1 (~8-25 builds/2h). Reworked: `avg_over_time((bad/clamp_min(total,1))[1h:5m]) > 0.8 and avg_over_time(total[1h:5m]) >= 50`, `for: 30m → 1h`, added `keep_firing_for: 1h` for hysteresis. Description updated to reflect 1h-smoothed ratio.
- 2026-05-03: **Drift-heal firewall race fix — Tier A + lease bump**. Root cause for 2026-05-02 W2 NotReady mid-drift-heal at 23:42:05 UTC: `firewall` role ran against `hosts: all` in **parallel** — all 3 nodes reloaded UFW simultaneously. Each `community.general.ufw` policy task triggers `ufw reload` → `iptables-restore` rebuilds all UFW chains. During rebuild window, INPUT chain transiently lacks K3s/flannel jump rules → kubelet→API HTTP/2 watch streams RST. Five sequential default-policy + rules tasks compounded the disruption beyond kubelet lease grace (40s default). Ships: (1) **`node-config.yml` 3-play split**: non-disruptive roles parallel, **firewall serial:1**, post-firewall parallel — quorum (2/3) always preserved during drift-heal. (2) **Drift fingerprint gate** in `firewall/tasks/main.yml`: pre-task hashes (`/etc/default/ufw` + `ufw status verbose` + sha256 of all ufw_rules_* vars), compares to cache at `/var/lib/ufw-state/ufw-fingerprint`. UFW rules block gated `when: ufw_drift_detected`. Cache updated post-block only when no rescue ran (clean state). Daily drift-heal on healthy node = pure no-op, zero reload. To force re-run after manual edit: `rm /var/lib/ufw-state/ufw-fingerprint`. (3) **Kubelet lease bump 40s→60s** in `roles/hardening/files/k3s-kubelet.yaml` (`nodeLeaseDurationSeconds: 60`, bare int, NOT duration string — common footgun) + `nodeStatusReportFrequency: 1m` (force status post 5m→1m for faster silent-hang detection). (4) **Lockstep CM grace 50s→75s** in `k3s_config/templates/config.yaml.j2` via `kube-controller-manager-arg: node-monitor-grace-period=75s` + `node-monitor-period=5s` — required because kubelet lease bump is no-op without CM grace bump (CM uses default 50s threshold otherwise). Vars in `group_vars/control_plane.yml`. Rule: grace ≥ lease + 1 renewal (60 + 15 = 75). (5) **`rolling-restart-k3s.yml`** new top-level playbook with `serial:1` to restart k3s/k3s-agent CP-first then workers, waits Ready per node, verifies `nodeLeaseDurationSeconds=60` + `nodeStatusReportFrequency=1m0s` via `/api/v1/nodes/<n>/proxy/configz` (defends against historical k3s field-stripping bugs #7578/#8266). Net effect: 99% of drift-heals = zero UFW reload (pure gate skip). Rare drift detected = serial:1 + full L0-L5 safety. Real-failure detection NotReady delayed ~25s (50s→75s).
- 2026-05-02: **Cardinality trim + UK rework + W1 incident**. (1) **Cardinality**: VMAgent `inlineUrlRelabelConfig` added to drop `flag` (1892, VM CLI flag introspection), `config_parameter` (801, VM env vars), `kube_pod_tolerations` (1081), `etcd_bookmark_counts` (364), 6 noisy histogram `_bucket` metrics (apiserver_watch_list/kyverno x2/controller_runtime/workqueue x2/rest_client/vm_promscrape — ~22k series), low-value cAdvisor (`container_memory_(mapped_file|max_usage_bytes|swap|total_inactive_file_bytes)|container_(sockets|threads)|container_spec_cpu_(period|shares)|container_cpu_(system|user)_seconds_total` — ~7k), and loop-device filesystem metrics. Estimated -33-35k series (204k→~170k, 17%). VMSingle 537Mi → unchanged short-term, will trim with retention roll. Verified live: `rate(flag[1m])` empty, `count(flag)` aging out. (2) **Uptime Kuma**: replaced stale standalone Redis monitor with `Redis HA Master` + `Redis HA Sentinel` TCP probes + `Blocky DNS W1` (192.168.1.129) + `Blocky DNS W2` (192.168.1.126) DNS-via-resolver probes. Originally tried via uptime-kuma-api in setup-job — flaky across lib versions and pre-existing data was in MySQL not SQLite, so reverted to admin-only setup-job and added monitors directly via MySQL INSERT. NetworkPolicy: extended `192.168.1.0/24` ipBlock egress to allow TCP+UDP 53 for Blocky DNS LB probes. Pinned UK Deployment + setup-job to control-plane (`nodeSelector: node-role.kubernetes.io/control-plane=true` + matching toleration) so worker-node probes always traverse external network — fixes "monitor blind to its own node failure" (UK was on W1 during incident, W1 SSH/kubelet probes stayed 100%/99.86% green via pod-local loopback while host INPUT was DROPing external L3). PVC dropped (`/app/data` → emptyDir; real state in MySQL). Helm releases audit closed (12 active, kube-prometheus-stack already trimmed). Skill stocktake quick (11 changed): chezmoi-sync L59, monitoring-check VMAlert jq + port-forward + baselines, networkpolicy-helper VMAgent wording — fixed + pushed. Security scan rollup all 3 nodes: 0 rootkits, hardening 77/78/77, baseline drift absorbed via `rkhunter --propupd`. (3) **W1 incident** (~22:48 UTC): post `yay -Syyu` weekly maintenance, kernel pkg upgraded 6.18.26-1-lts → -2-lts, pacman post-install removed `/lib/modules/6.18.26-1-lts` while kernel still running → modprobe couldn't find ip6table_filter → ufw runtime `ip6tables` error → ufw silently disabled → host INPUT chain DROP'd 8260 packets → W1 NotReady (~25 min). UFW heal v3 ran post-reboot and probe-set UNHEALTHY (`missing ufw6-logging-deny ufw6-user-input`); after manual `ufw enable`, `disable;enable` cycle hit `iptables-restore line 2 failed: No chain/target/match by that name`. Recovered via reboot + emergency `iptables -P ACCEPT && iptables -F INPUT` while UFW debug deferred. Pods rescheduled to W1 cleanly post-recovery. NIC udev-renamed `enp3s0` → `enp4s0` on -2-lts boot — ansible `nic_tuning` role now references stale name. **Issues tracked above** (resolution verified 2026-05-08): P1 ufw line-2 failure ✅ FIXED via heal v4 commit `476ec535` (flush-all + force-enable bypasses iptables-restore line 2 error); P2 heal v3 needs ufw-disabled state probe ✅ FIXED via `phase_ufw_state_recover` in firewall-preflight (same commit `476ec535`); P3 nic_tuning interface-name ✅ NOT-DRIFT — `host_vars/worker-node.yml` already had `nic_tuning_iface: enp4s0`, CP `host_vars/gmk-k3s-control-plane.yml` correctly retains `enp3s0` (no rename on CP). Re-test pending = umbrella row "Validate UFW silent-disable auto-heal" tracking. Layer 1 prevention added via `kernel-modules-hook` commit `6e01c7d0` (prevents `/lib/modules/<running-kernel>` wipe). Next Review bumped 2026-05-04 → 2026-06-04. Quarterly automation audit still 2026-07-04.

- 2026-05-02: **Monthly review + audit (early, vs scheduled 2026-05-04)**. Security scan rollup all 3 nodes: 0 rootkits, hardening 77/78/77, baseline drift (egrep/fgrep/ldd→scripts, telnet, W2 hostname) absorbed by `rkhunter --propupd`. April logs 0-byte (ansible deploy initialised them empty 2026-04-18); May = first real scan, June = first real diff baseline. Skill stocktake quick (11 changed since 2026-04-29 caveman compress): 8 Keep, 3 Improve fixed inline — chezmoi-sync L59 Templates gotcha clarified, monitoring-check VMAlert jq path unified to `.data.alerts[]?` + port-forward pattern (direct exec hits Connection refused) + baselines refreshed (VMSingle 537Mi / series 204k, up from 113k @ 2026-04 — flag cardinality growth), networkpolicy-helper L104 "scraped by Prometheus"→"scraped by VMAgent". Zombie helm release audit closed: 12 releases all active, kube-prometheus-stack confirmed trimmed (`prometheus.enabled=false`; operator + grafana + AM + KSM + node-exporter retained — operator manages AM STS); 5 empty kube-prometheus-stack CRDs + 13 empty VM-operator CRDs bundled with chart, risky-to-remove for marginal benefit, no actionable cleanup. Next Review bumped 2026-05-04 → 2026-06-04. Quarterly automation audit still 2026-07-04.
- 2026-04-28: **Ansible review + NOW + 1-2 day + Later + power-down prevention** (10 commits, full session). Final landed list: #1 authorized_keys, #2 /etc/hosts, #3 timesyncd assert+metric, #5 SSH host fingerprint baseline, #6 admin sudoers, #7 K3s tls-san, #11 fail2ban jail.local (systemd backend), #14 phase2 pod-GC ns filter, #15 rebuilderd cleanup template DRY, swap config 3-host, kernel cmdline audit, K3s secrets-encrypt runtime verify, nic_tuning generalized to all 3 nodes (CP igc + W1 igc + W2 r8169 EEE-off), PCIe runtime PM udev rule (SATA + NVMe + Ethernet classes). Dropped after research: #4 pacman_config (reflector owns), #8 K3s data-dir perms (subdir 0755 design), #9 resolved DNS (Blocky chain works), #10 K3s server flags (config.yaml drift-alert covers), #12 sysctl handler (correct semantics), #13 packages retry (works), #16 idempotency CI (deferred), #17 meta deps (cost > benefit), #18 CNI fingerprint (K3s-runtime), #19 ansible-vault (already SOPS), #20 logrotate.conf (per-app sufficient), zram (unused), MTU (correct), /etc/rancher/k3s backup (K3s handles). 4 gotchas saved to memory. Full audit + plan (`docs/scripts/node-maintenance/ANSIBLE_REVIEW_PLAN.md`, 20 confirmed gaps triaged). Verified baseline: drift-alerting wired (`node-config-notify.sh` Telegram on `failed>0` OR `changed>0`), sudoers visudo-validated, journald caps configured, firewall+preflight split intentional. **NOW bucket shipped** (commits `0cd01203` → `820d1c2b` → `04ec29be`): (1) #1 `authorized_keys` template — `base_config` slurps CP pubkey via `delegate_to+run_once`, deploys to workers exclusive 0600. (2) #3 timesyncd assert + textfile metric (`node_time_sync_synchronized`, `_active`, `_drift_seconds`, 60s) — verified live, all 3 nodes synced. (3) #7 K3s `tls-san` block in template, var in `group_vars/control_plane.yml` — drift-alert auto-fires. (4) #8 data-dir perms audit DROPPED — K3s sets `<data-dir>` + all top-level subdirs to 0755 by design (containerd traversal); secrets live in individual mode-0600 files inside. (5) #14 phase2 Failed-pod GC scoped to `phase2_pod_gc_namespaces` (system+infra only, user-app ns skipped). 2 gotchas saved: `when:` on `run_once+delegate_to` skip-trap, K3s subdir 0755 false-positive. **1-2 day bucket shipped (commit `739a578b`)**: #2 `/etc/hosts` blockinfile (with CP `node_ip` override since `ansible_connection: local` makes `ansible_host=127.0.0.1`), #5 SSH host key fingerprint baseline + drift alert, #15 rebuilderd cleanup template (single `cleanup-stale-repro.sh.j2`, deletes per-host duplicates). **Dropped on review**: #9 resolved upstream pinning (would bypass Blocky — verified DHCP already pushes Blocky to nodes), #12 sysctl `changed_when:false` on handler is correct, #17 role meta deps add cost without protection. Later: pacman_config/admin-sudo/fail2ban/idempotency-CI. Never: logrotate.conf system-wide, K3s cert SAN auto-renewal, firewall+preflight consolidation.
- 2026-04-28: **UFW heal v3 — readiness barrier + preflight role + module + ufw-chains-only settle**. Sequel to 2026-04-26 v2: W2 hit `ufw status verbose: ERROR: problem running ip6tables` again at drift-heal 17:54 BST despite v2's modules-load.d entry (`ip6_tables`/`ip6table_filter`/`iptable_filter` were loaded). Root cause: missing nat/mangle/raw table modules — ufw's `iptables-restore` on `before6.rules` references `*mangle`/`*nat` tables; auto-load fails under K3s/fail2ban iptables lock contention. Shipped: (1) **modules-load.d expanded** to 10 modules (added `ip6table_nat`/`ip6table_mangle`/`ip6table_raw` + v4 nat/mangle/raw + `nf_conntrack`); firewall role modprobe loop matched. (2) **`k3s-wait-ready.service`** new oneshot barrier (After=k3s/k3s-agent, RemainAfterExit=yes, 200s budget) that polls API healthz (CP) + critical pods Ready (kube-router/coredns CP-only) + ufw-chain hash stability, touches `/run/k3s-ready` sentinel. `ufw-heal-post-k3s.service` now `After=k3s-wait-ready.service Wants=k3s-wait-ready.service ConditionPathExists=/run/k3s-ready`. Replaces naive `After=k3s.service` (started ≠ ready). (3) **`firewall_preflight` role** — new role inserted before `firewall` in node-config.yml all-hosts play AND before rebuilderd in workers play. Runs `firewall-preflight.sh`: settle wait + modprobe expanded modules + per-chain repair. Defends any role transitively invoking `community.general.ufw`. (4) **Phase A v2 in `ufw-heal-post-k3s.sh`** — replaced old `nft monitor 0-events` gate with `ufw_chains_hash` (sha256 of `:ufw-`/`-A ufw-` lines from iptables-save) stability across 3× 5s windows, max 90s. Workers always churn kube-* chains so full-ruleset hash never converged on first test (W2 reboot 18:41-18:45) — ufw-only hash bounded drift. Same hash fn shared with k3s-wait-ready + firewall-preflight. (5) **fail2ban detected** as deployed-but-unmanaged-by-ansible (active on W2, pacman 1.1.0-8). Race source documented; no role added yet. (6) **Lint cleanup**: pre-existing `risky-shell-pipe` in firewall pre-heal block (added `set -o pipefail`), `name[casing]` in nic_tuning handler, `yaml[commas]` alignment in group_vars/all.yml all fixed — repo passes `production` profile clean. **W2 reboot test 18:41 BST**: all 10 modules loaded post-boot, `/run/k3s-ready` touched at 181s (settle timed out via fallback), heal exit 0 with "ufw active — heal OK" (probe-set healthy, reload attempt 1/3 succeeded), no UfwDisabled/UfwChainsUnhealthy alerts. Refinement: ufw-chains-only hash deployed via second commit. CP + W1 inherit on next drift-heal cycle (15:00 UTC).
- 2026-04-26: **UFW heal v2 + drift-heal cadence 1x→2x/day**. W2 hit `ufw status verbose: ERROR: problem running ip6tables` 30+h after boot — boot-time `ufw-heal-post-k3s.service` doesn't catch runtime drift. Root cause re-audited: real CNI is K3s default flannel + kube-proxy (NOT kube-router as old comments claimed); heal Phase A's `KUBE-ROUTER-INPUT` quiescence probe always timed out. Plus `ip6_tables` kernel module had unloaded mid-runtime. Shipped: (1) heal script v2 — `nft monitor` event-based quiescence (max 60s, 5s windows), phase reorder A→C→B→E→D→F (per-chain `iptables -N` BEFORE `ufw reload`); (2) `/etc/modules-load.d/ufw-iptables.conf` (`ip6_tables`/`ip6table_filter`/`iptable_filter`) + `ufw.service.d/modules.conf` (`After=systemd-modules-load.service`); (3) ansible firewall pre-heal task reordered repair-first; (4) `node-maintenance-config.timer` 1x→2x/day (03:00 + 15:00 UTC, drift window ≤12h). Hourly probe-then-heal pattern researched + rejected (`-w` no-op on iptables-nft, double-heal risk, pacman/rebuilderd lock contention). W2 canary applied 20:27 UTC, `ufw_chains_healthy=1`. Roll W1 + CP next 03:00 UTC drift-heal.
- 2026-04-26: **W2 rebuilderd memory cap 14G→12G**. Reduced `MemoryMax 14G→12G` / `MemoryHigh 13G→11G` / `MAX_MEMORY=12G` to leave more headroom for K8s pods on W2. Updated via ansible (`roles/rebuilderd/files/resources-worker-node-2.conf` + `host_vars/worker-node-2.yml`), drift-applied via `node-maintenance-config.service`, verified live (`MemoryMax=12G`). Also added `docs/scripts/ansible-apply.sh` helper (sync + drift-heal + per-host rebuilderd verify) deployed to CP `~/ansible-apply.sh`.
- 2026-04-26: **W1 rebuilderd memory cap 32G→18G**. Host-level OOM on W1 — rebuilderd cgroup pressure spilled past `MemoryMax=32G`/`MemoryHigh=31G` and triggered host OOM-kills on K8s pods. Reduced to `MemoryMax=18G`/`MemoryHigh=17G` (+`MAX_MEMORY=18G` env for nspawn). Trade-off accepted: heavy LTO builds (python-triton ~40GB, openvdb ~34GB) will OOM inside rebuilderd cgroup again — same failures as pre-2026-02-21 — but K8s stability preserved. Updated via ansible (`roles/rebuilderd/files/resources-worker-node.conf` + `host_vars/worker-node.yml`), drift-applied to W1 live, verified `MemoryMax=19327352832` (=18*1024^3).
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
- 2026-04-27: **claude-telegram HTTP trigger** — bot accepts loopback `POST /trigger` (header `X-Trigger-Secret`) that replays prompt as if first allowed user sent it via Telegram. Wired into `node-maintenance-phase2.service` ExecStopPost: on success, CP runs `telegram-notify-claude.sh` → `kubectl exec` curl into pod loopback → bot autonomously reviews alerts + clears stale resources in user's normal DM. Failure path unchanged (alerts chat). Image bumped 1.11 → 1.12 (PR `AKhozya/claude-telegram-bot#1`). Secret added to SOPS `claude-telegram-env.trigger-secret`. Bound to 127.0.0.1 — no Service/NetworkPolicy needed.
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
