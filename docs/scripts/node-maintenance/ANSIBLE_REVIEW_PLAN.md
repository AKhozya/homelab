# Ansible Review & Improvement Plan

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

### NOW (~2h, this session)
- **#1** `authorized_keys` template — `base_config` task, deploy from `group_vars/all.yml` keys, mode 0600.
- **#3** timesyncd assert + skew metric — small role or `base_config` extension. Assert `enabled+active`. Textfile metric: `timedatectl show -p NTPSynchronized,TimeUSec` → `node_maintenance_clock_synced` gauge.
- **#7** K3s `tls-san` — extend `config.yaml.j2`, list IPs+hostnames in `group_vars/control_plane.yml`. Drift-alert auto-fires on template change.
- **#8** K3s data-dir perms check — `k3s_config` task: `stat -c %a /var/lib/rancher/k3s`, fail if not `0700`.
- **#14** Phase2 Failed-pod GC — restrict `--field-selector` to system + ops namespaces, leave user namespaces alone.

### 1–2 DAYS (next session)
- **#2** `/etc/hosts` blockinfile from inventory loop.
- **#5** SSH host key fingerprint capture + diff alerting (read-only).
- **#9** systemd-resolved upstream DNS pinning.
- **#12** sysctl handler — surface real changes.
- **#15** rebuilderd cleanup — single template with `inventory_hostname`.
- **#17** role `meta/main.yml` dependencies declared.

### LATER (when scaling / scheduled)
- **#4** pacman_config role (mirror migration trigger).
- **#6** admin sudoers (batch with #11).
- **#10** K3s server flags drift detection.
- **#11** fail2ban tuning (only if SSH brute force seen).
- **#13** packages retry semantics (refactor when phase1 actually flakes).
- **#16** idempotency CI (4h investment, needs lab node).
- **#18** CNI fingerprint diagnostic.
- **#19** ansible-vault for secrets (current 0600 plaintext acceptable solo).

### NEVER
- **#20** logrotate.conf system-wide tuning.
- K3s cert SAN auto-renewal (K3s handles internally).
- Firewall + firewall_preflight consolidation (split is intentional, documented).

## Cross-References

- Live tracker: `docs/HOMELAB_ANALYSIS.md`
- Append-only changelog: `docs/HOMELAB_HISTORY.md`
- Role map: memory `reference_ansible_roles.md`
- Maintenance schedules: memory `project_maintenance_schedules.md`
