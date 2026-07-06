# Ansible Review & Improvement Plan — CLOSED 2026-04-28

**Status:** ✅ COMPLETE. All actionable items shipped or dropped with rationale.
**Commits:** `0cd01203` → ... → `c4a50a18` (10 commits + final closure).
**Verified:** 6+ drift-heal cycles `failed=0`, idempotent on 2nd run.

**Date:** 2026-04-28
**Scope:** `docs/scripts/node-maintenance/ansible/` — node OS layer drift-heal.
**Context:** Setup runs on CP under `node-maintenance` user via systemd timers (sync 10min, drift-heal daily 03:00, weekly Sat 04:30, security-scan monthly).

## Verified Baseline

- 11 roles, 3 playbooks (`phase1.yml`, `phase2.yml`, `node-config.yml`).
- Drift-alerting wired: `node-maintenance-config.service` `ExecStopPost` → `node-config-notify.sh` → Telegram on `failed>0` OR `changed>0`.
- Sudoers validated via `visudo -c -f`.
- Journald caps configured (500M / 30d / 1week).
- Firewall pre-heal + `firewall_preflight` split is intentional (defense-in-depth, documented in script header).
- timesyncd active with `System clock synchronized: yes`. No drift, just unmanaged.

## Confirmed Gaps (read-verified)

| # | Gap | Risk |
|---|-----|------|
| 1 | `authorized_keys` for `node-maintenance` not deployed (only `~/.ssh` dir created, `base_config:96-103`) | Reprovision = manual SSH key copy |
| 2 | `/etc/hosts` unmanaged — IPs hardcoded in inventory but never reflected to nodes | Silent DNS divergence |
| 3 | timesyncd not asserted by ansible; no clock-skew metric | Operator could disable, drift undetected |
| 4 | `/etc/pacman.conf` + mirrorlist unmanaged (set once via `setup-node.sh`) | Mirror drift undetected |
| 5 | SSH host keys never managed/backed-up/audited | No key rotation, fingerprint drift unauditable |
| 6 | Admin user (`akhozya`/`z3us`) sudoers hand-edited (only `node-maintenance` sudoers managed) | Lockout risk on reprovision |
| 7 | K3s `tls-san` not in `config.yaml.j2` template | IP/hostname change = manual cert regen |
| 8 | K3s data-dir (`/var/lib/rancher/k3s`) perms never validated | World-readable secrets risk |
| 9 | resolved.conf upstream DNS not declared (only LLMNR-disable) | Silent resolver drift |
| 10 | K3s server flags drift undetected (only config.yaml diffed) | Runtime args can drift from template |
| 11 | fail2ban package installed, config defaults | No SSH brute-force protection tuned |
| 12 | Hardening sysctl handler `changed_when: false` masks applied values | Audit-trail blind spot |
| 13 | `packages` retry collapses lock vs corruption | Real errors retried 3x silently |
| 14 | Phase2 `Failed` pod GC has no namespace filter | Risk of nuking user-namespace test pods |
| 15 | rebuilderd cleanup scripts duplicated per worker | DRY violation |
| 16 | No idempotency CI — playbook 2nd run could `changed>0` | Drift-heal cries wolf |
| 17 | Role meta dependencies not declared | Implicit ordering, breaks if reordered |
| 18 | CNI/flannel runtime config not fingerprinted | Silent network drift |
| 19 | Telegram tokens plaintext at `/etc/node-maintenance/telegram-token` (mode 0600) | Acceptable for solo homelab; vault-encryption optional |
| 20 | system-wide logrotate.conf unmanaged | Per-app drops sufficient — leaving as-is |

## Triage

### NOW — ✅ DONE 2026-04-28 (commits `0cd01203` → `820d1c2b` → `04ec29be`)
- ✅ **#1** `authorized_keys` template — `base_config` slurps CP pubkey via `delegate_to+run_once`, deploys to workers (mode 0600, exclusive). **Bug caught:** `when:` on slurp + `run_once` traps task into skip when first batch host fails condition (memory: `gotchas.md#ansible-when-runonce-trap`).
- ✅ **#3** timesyncd assert + skew metric — `base_config` ensures enabled+active. `timesyncd-metric.{sh,service,timer}` emits `node_time_sync_synchronized`, `node_time_sync_active`, `node_time_sync_drift_seconds` to `/var/lib/node_exporter/textfile/time_sync.prom` every 60s. **Verified live**: all 3 nodes synchronized=1, CP drift ≈15ms.
- ✅ **#7** K3s `tls-san` — block added to `config.yaml.j2`, var `k3s_tls_san` in `group_vars/control_plane.yml` (127.0.0.1, localhost, gmk-k3s-control-plane, 192.168.1.127). Drift-alert auto-fires on template change. K3s restart needed to regenerate cert.
- ❌ **#8** K3s data-dir perms — DROPPED. K3s sets `<data-dir>` AND all top-level subdirs (`server/`, `agent/`, `server/cred/`, `server/db/`) to 0755 by design. Real secrets live in individual files (mode 0600), K3s manages those. Directory-level audit = false positives. Memory: `gotchas.md#k3s-subdir-0755`.
- ✅ **#14** Phase2 Failed-pod GC — restricted via `phase2_pod_gc_namespaces` list (system+infra ns only: kube-system, flux-system, kyverno, monitoring, traefik, cert-manager, databases, cloudflare-tunnel, backup-replication, node-maintenance). User-app ns (immich, paperless, n8n, mealie, etc.) skipped.

### 1–2 DAYS (next session)
- **#2** `/etc/hosts` blockinfile from inventory loop.
- **#5** SSH host key fingerprint capture + diff alerting (read-only).
- ~~**#9** systemd-resolved upstream DNS pinning — DROPPED (would bypass Blocky for node-side traffic: image pulls, pacman).~~ **REVERSED + IMPLEMENTED 2026-06-04** (`c4fcd922`): nodes pinned to public DNS 1.1.1.1/9.9.9.9 via networkd `UseDNS=no` + resolved global drop-in (hardening role). The earlier "keep the Blocky chain at node level" call was outweighed by breaking the node→Blocky→kube-proxy **circular DNS dep** — cluster-external DNS (CoreDNS `forward . /etc/resolv.conf`, `dnsPolicy: Default`) must NOT depend on a cluster pod (blocky also hard-deps redis). Node-side adblock loss judged near-zero (node queries = registries/NTP, not ad domains); LAN-client adblock unchanged (router DHCP untouched).
- ~~**#12** sysctl handler — surface real changes.~~ DROPPED on review: `changed_when: false` on a handler is correct semantics — handler running means upstream task already reported `changed=1` (notify trigger). `command:` module still fails on non-zero rc, so invalid sysctl propagates as failure → telegram alert. Original critique was overcooked.
- **#15** rebuilderd cleanup — single template with `inventory_hostname`.
- ~~**#17** role `meta/main.yml` dependencies declared.~~ DROPPED on review: `dependencies:` forces dep role to run on EVERY invocation (slow + noisy when packages already ran via playbook). Playbook role list already enforces correct order. `.ansible-lint` passes production profile without meta files — no lint pressure. Real protection (someone deletes `packages` from playbook) requires intentional action, not accidental drift.

### LATER — RESEARCHED 2026-04-28, mostly DROPPED
- ❌ **#4 pacman_config role** — DROP. `pacman.conf` is Arch default + harmless tweaks (VerbosePkgLists/Color/ParallelDownloads=10/SigLevel=Required). Mirrorlist owned by **active `reflector.timer`** (auto-regenerated, last 2026-04-27). Ansible would fight reflector.
- ✅ **#6 admin sudoers** — KEEP. File exists+works (akhozya pwd-sudo functional). Ansible-ize once user pastes current `/etc/sudoers.d/*` content. Risk: medium (sudoers mistake = lockout); mitigated by `validate: visudo -c -f`.
- ❌ **#10 K3s server flags drift** — DROP. `/proc/<k3s-pid>/cmdline` is bare `/usr/local/bin/k3s server`. All config lives in `config.yaml` which is already managed + drift-alerted via existing `node-config-notify.sh`.
- ✅ **#11 fail2ban tuning** — PARTIAL/KEEP. Active+installed (1.1.0-8). `jail.local` + `jail.d/` already exist → already tuned. Just needs ansible-ize so config is reproducible. Need user paste.
- ❌ **#13 packages retry semantics** — DROP. 3×30s retries + lock-aware guards in phase1/2. No observed flakes since 2026-04-21 hardening. Solving non-problem.
- ❌ **#16 idempotency CI** — DROP. Prod runs already observed `changed=0` on 2nd pass (verified across 6+ drift-heal cycles this session). 4h CI build duplicates what prod already shows. Solo homelab — close.
- ❌ **#18 CNI fingerprint diagnostic** — DROP. K3s flannel config (`<data-dir>/agent/etc/flannel/net-conf.json`) is K3s-runtime-managed. Drift would mean K3s self-mutated — won't happen.
- ❌ **#19 ansible-vault for secrets** — DROP. telegram-token sourced from k8s secret (`backup-replication/backup-telegram`) which is already SOPS-encrypted in flux source. ansible-vault layer would be redundant.

### NEW gaps verified during research (not in original plan)
- ✅ **swap config** — DONE.
- ❌ **zram** — DROP. Not loaded.
- ✅ **kernel boot params audit** — DONE (`base_config` asserts `expected_kernel_params` in `/proc/cmdline`).
- ❌ **MTU settings** — DROP. All correct (enp3s0=1500, flannel/cni=1450).
- ❌ **/etc/rancher/k3s state backup** — DROP. K3s-managed.

### POWER-DOWN PREVENTION SHIPPED 2026-04-28 (commits `c54e9020` → `7b4e0ea9`)
- ✅ **NIC tuning generalized** — replaces `igc-tune@.service` with `nic-tune@.service`. Always disables EEE + Wake-on-LAN. Speed-force conditional via per-iface `EnvironmentFile` (CP only: `FORCE_SPEED=1000` for igc gigabit-bug workaround).
  - **CP** enp3s0 igc — was already EEE-off via legacy igc-tune. Migrated cleanly.
  - **W1** enp4s0 igc — declarative EEE-off (was already off, now under ansible).
  - **W2** enp2s0 r8169 — flipped `enabled-active → disabled`. Verified live.
- ✅ **PCIe runtime PM rule** — `udev-60-pci-no-runtime-pm.rules` replaces nvme-only file. Class codes covered: `0x010601` (SATA), `0x010802` (NVMe), `0x020000` (Ethernet). Belt-and-suspenders to `pcie_aspm=off` cmdline (which only handles ASPM link level).
- ✅ **Bug caught + saved**: `copy: content:` rejects empty/whitespace-only Jinja output. Workers without `nic_tuning_force_speed` failed first run with "src (or content) is required". Fix: gate task with `when: nic_tuning_force_speed defined` + sibling task removes file otherwise. Memory: `gotchas.md#ansible-copy-content-empty`.

### Coverage now (4-layer defense)
| Component | Layer 1 | Layer 2 | Layer 3 | Layer 4 |
|---|---|---|---|---|
| **NVMe SSD** | `nvme_core.default_ps_max_latency_us=0` cmdline (workers) | `modprobe-nvme-no-apst.conf` | `udev-60-pci-no-runtime-pm.rules` (class 0x010802) + `tmpfiles-nvme-no-pm.conf` | block-device runtime PM=on |
| **SATA SSD** | `udev-60-sata-no-alpm.rules` (max_performance) | `udev-60-pci-no-runtime-pm.rules` (class 0x010601) | — | — |
| **PCIe link** | `pcie_aspm=off` cmdline (all 3 nodes) | `udev-60-pci-no-runtime-pm.rules` (per-class runtime PM=on) | — | — |
| **Ethernet** | `pcie_aspm=off` cmdline | `udev-60-pci-no-runtime-pm.rules` (class 0x020000) | `nic-tune@iface.service` (EEE off + WoL off) | CP: speed-force 1Gbps |

### LATER BUCKET LANDED 2026-04-28 (commits `ade9894f` → `49ecf545` → next)
- ✅ **#6 admin sudoers** — `base_config` deploys `00_<admin_user>` via `admin_user` host_var (akhozya/akhozya/z3us), content `<user> ALL=(ALL) ALL`, validate via visudo, mode 0440. Live state matches → idempotent.
- ✅ **swap config** — `base_config` asserts host-specific fstab entry (lineinfile) + active swap path (resolves symlinks for LVM LV → dm-N before grep against `swapon --show`). Vars: `swap_kind/path/fstab_entry` per host_var.
- ✅ **#11 fail2ban** — `hardening` deploys `jail.local` (LAN whitelist 192.168.1.0/24, bantime 1h, sshd jail port 65300 maxretry 3, **systemd backend**). W2 had stray `logpath = /var/log/auth.log` — drift-heal removed.
- ✅ **kernel cmdline audit** (NEW): `base_config` asserts `expected_kernel_params` present in `/proc/cmdline`. Universal subset in `group_vars/all.yml` (4 params), workers add 2 AMD-specific in `group_vars/workers.yml`. Read-only — failed task = telegram alert. Operator fixes via `/boot/loader/entries/*.conf` edit + reboot.
- ✅ **K3s secrets-encryption runtime verification** (NEW): `k3s_config` asserts `k3s secrets-encrypt status` shows `Encryption Status: Enabled`. CP-only, gated on `k3s_secrets_encryption: true`. Catches silent encryption-disable post-restart.

### NEVER
- **#20** logrotate.conf system-wide tuning.
- K3s cert SAN auto-renewal (K3s handles internally).
- Firewall + firewall_preflight consolidation (split is intentional, documented).

## Cross-References

- Live tracker: `docs/HOMELAB_ANALYSIS.md`
- Append-only changelog: `docs/HOMELAB_HISTORY.md`
- Role map: memory `reference_ansible_roles.md`
- Maintenance schedules: memory `project_maintenance_schedules.md`
