# Node Config → Ansible: Full Migration Plan

**Goal:** Migrate all hand-cranked node-level config (systemd units, scripts, sudoers, kernel tuning, firewall rules, rebuilderd setup) from one-shot bash scripts into an idempotent ansible playbook that self-heals drift on a schedule. End state: `setup-node.sh`, `setup-rebuilderd-worker-{1,2}.sh`, `setup-ufw-*.sh`, `install.sh` heredocs all retired or reduced to bootstrap-only.

**Architecture:**
- Ansible playbook `ansible/node-config.yml` (multi-play: `control_plane`, `workers`, `all`).
- Per-host vars in `ansible/group_vars/` + `ansible/host_vars/`.
- Templates in `ansible/templates/`.
- New systemd unit `node-maintenance-config.service` + `.timer` (daily 03:00 UTC).
- Hook into `node-maintenance-sync.service` post-pull.
- Drift → Telegram alert.

**Tech Stack:** ansible-core 2.20, `ansible.builtin.*`, `ansible.posix.*`, `community.general.ufw`, systemd timers.

**Phase order + independence:** Phases A→E are sequential (later phases import helper tasks from A). Each phase is committed in isolation, independently deployable + rollback-safe.

**Out of scope:** K3s encryption-config (too risky, leave as bash in `setup-node.sh`). K3s install itself (one-shot, doesn't drift).

---

## Phase Overview

| Phase | Scope | Effort | Risk | Status |
|-------|-------|--------|------|--------|
| **A** | Base config: logrotate, journald, sudoers, rebuilderd-worker override, node-maintenance user | ~2h | Low (already deployed via bash; ansible should emit `changed=0`) | Pending |
| **B** | k3s-image-gc + rebuilderd ancillary (metrics, watchdog, repro-cleanup, reenable-stop, worker-boot) + scripts in `/usr/local/bin/` | ~3h | Medium (active rebuilderd — don't disrupt current build) | Blocked by A |
| **C** | UFW firewall rules | ~2h | Medium (mis-rule = SSH lockout; test via console fallback) | Blocked by A |
| **D** | Kernel/network hardening: SSH sshd_config, sysctls, kubelet timeout | ~4h | High (SSH misconfig = lockout) | Blocked by A |
| **E** | Ad-hoc one-shots: `update-firmware`, `enable-crash-logging`, `setup-claude-telegram` → tagged tasks | ~1h | Low (tag-gated, run on-demand) | Blocked by A-D |

Total: ~12h across sessions.

---

## Cross-Phase File Structure

```
docs/scripts/node-maintenance/
├── ansible/
│   ├── node-config.yml                 # NEW — master config playbook (all phases)
│   ├── inventory.yml                   # MODIFY — add control_plane group
│   ├── group_vars/
│   │   ├── all.yml                     # existing (phase1/2 vars)
│   │   ├── control_plane.yml           # NEW — CP-specific
│   │   └── workers.yml                 # NEW — worker-specific
│   ├── host_vars/
│   │   ├── worker-node.yml             # NEW — W1 rebuilderd config
│   │   └── worker-node-2.yml           # NEW — W2 rebuilderd config
│   ├── roles/                          # NEW — phase boundaries as roles
│   │   ├── base-config/                # Phase A
│   │   ├── rebuilderd/                 # Phase B
│   │   ├── firewall/                   # Phase C
│   │   ├── hardening/                  # Phase D
│   │   └── ad-hoc/                     # Phase E (tag-gated)
│   └── templates/                      # (role-scoped in roles/*/templates/)
├── systemd/
│   ├── node-maintenance-config.service # NEW
│   └── node-maintenance-config.timer   # NEW
├── install.sh                          # MODIFY (phases A, D shrink it)
└── install-worker.sh                   # MODIFY (phases A, B shrink it)

docs/scripts/
├── setup-node.sh                       # SHRINK in Phase D (K3s bootstrap only)
├── setup-rebuilderd-worker-{1,2}.sh    # RETIRE in Phase B
└── setup-ufw-k3s-{cp,worker}.sh        # RETIRE in Phase C
```

---

## Phase A — Base Config (current)

**Targets:** logrotate configs (pacman, node-maintenance, security-tools), journald 99-caps.conf, sudoers NOPASSWD, rebuilderd-worker TimeoutStopSec override, node-maintenance user.

**Current mgmt:** `install.sh` / `install-worker.sh` heredocs; `/tmp/apply-worker-logrotate.sh` one-shot.

### Tasks

**A.1** — Inventory: add `control_plane` group (local connection, 127.0.0.1)
**A.2** — Scaffold `roles/base-config/` with:
  - `tasks/main.yml` — logrotate pkg + configs, journald drop-in, sudoers, user
  - `templates/logrotate-{pacman,node-maintenance,security-tools}.j2`
  - `templates/journald-99-caps.conf.j2`
  - `templates/sudoers-node-maintenance.j2`
  - `handlers/main.yml` — restart journald, daemon-reload
**A.3** — Migrate rebuilderd-worker@.service.d/override.conf (workers) as part of base-config (coupled to rebuilderd).
**A.4** — Add `node-maintenance-config.service` + `.timer` (daily 03:00 UTC).
**A.5** — Hook ansible call into `sync-from-git.sh` post-pull.
**A.6** — Strip migrated heredocs from `install.sh` + `install-worker.sh`. Keep bootstrap-minimal: user creation + SSH key + sudoers (first-run) + logrotate pkg install.
**A.7** — Docs: README section, delete `/tmp/apply-worker-logrotate.sh`, HOMELAB changelog.

### Success criteria
- `ansible-playbook node-config.yml --tags base-config --check` → `changed=0` after initial deploy
- Timer fires, logs to `/var/log/node-maintenance/config.log`
- `install.sh` ≤ 150 lines (from ~200); `install-worker.sh` ≤ 80 (from ~85)

### Rollback
- Revert role commits; `install.sh --sync-only` restores bash heredocs until Task A.6 lands.

---

## Phase B — k3s-image-gc + Rebuilderd Ancillary

**Targets (all 3 nodes):**
- `k3s-image-gc.service` (Type=oneshot, `ExecStart=/usr/local/bin/crictl rmi --prune`)
- `k3s-image-gc.timer` (OnCalendar=`Mon *-*-* 04:00:00`, RandomizedDelaySec=600, Persistent=true)

**Targets (workers only):**
- `rebuilderd-metrics.service/.timer` (5min) + `/usr/local/bin/rebuilderd-metrics.sh` (node-exporter textfile writer — reads `rebuilderd-worker@*` journal, emits `rebuilderd_*` gauges to `/var/lib/node_exporter/textfile/rebuilderd.prom`)
- `rebuilderd-watchdog.service/.timer` (10min) + `/usr/local/bin/rebuilderd-watchdog.sh` (detects stuck builds: ≥5 "Suppressed"/"wait: pid" lines in last 5min + <5 real lines in last 20min → restart `rebuilderd-worker@1.service`)
- `rebuilderd-worker-boot.timer` (OnBootSec=10min, starts `rebuilderd-worker@1.service` after boot)
- `rebuilderd-reenable-stop.service/.timer` (W1 only — daily 09:00, re-enables stop timer)
- `rebuilderd-worker-scheduled.service` (W2 only — scheduled worker run)
- `repro-cleanup.service/.timer` (Sun 08:00) + `/usr/local/bin/cleanup-stale-repro.sh` (removes stale nspawn containers from `/mnt/k8s-storage/repro/`)

**Current mgmt:** hand-placed by `setup-rebuilderd-worker-{1,2}.sh` (one-shot bash, drift-prone, never re-run).

### Tasks

**B.1** — Inventory host_vars for per-worker rebuilderd config (MAX_MEMORY=32G for W1, 14G for W2; reenable-stop enabled on W1 only; worker-scheduled on W2 only; CPU quotas).
**B.2** — Scaffold `roles/rebuilderd/`:
  - `tasks/main.yml` — install/deploy 12 units + 3 scripts
  - `tasks/worker-variants.yml` — conditional reenable-stop (W1) / worker-scheduled (W2)
  - `templates/` — 12 `.j2` unit files + 3 `.j2` script files
  - `handlers/main.yml` — daemon-reload, restart rebuilderd-worker
  - `defaults/main.yml` — sane defaults overridable by host_vars
**B.3** — Scaffold `roles/k3s-image-gc/` (tiny — 2 units, applies to `all`).
**B.4** — Dry-run on workers, compare `/etc/systemd/system/*.service` against templates (expect `changed=0` after bootstrap).
**B.5** — Apply + verify rebuilderd build still healthy (`systemctl status rebuilderd-worker@1`, build job still running if any).
**B.6** — Retire `setup-rebuilderd-worker-{1,2}.sh` → delete with symlink `RETIRED.md` pointing to ansible role.
**B.7** — HOMELAB changelog + README.

### Success criteria
- `ansible-playbook --tags rebuilderd,k3s-image-gc --check --diff` → `changed=0`
- Active rebuilderd build not interrupted
- `rebuilderd-metrics.prom` still emits metrics; VMAgent scrape still works
- `setup-rebuilderd-worker-*.sh` files retired

### Rollback
- Revert role commits; units were placed identically to originals, so no state reset needed.

---

## Phase C — UFW Firewall

**Targets:**
- `setup-ufw-k3s-control-plane.sh` — UFW rules for CP (SSH:65300, K8s API:6443, kubelet:10250, flannel:8472, etc.)
- `setup-ufw-k3s-worker.sh` — UFW rules for workers (SSH:65300, kubelet:10250, flannel:8472, etc.)

**Current mgmt:** one-shot bash, drift-prone, no diff detection.

### Tasks

**C.1** — Read current UFW state on all 3 nodes: `ufw status numbered` → capture.
**C.2** — Define rule set in `group_vars/` (CP + workers split).
**C.3** — Scaffold `roles/firewall/`:
  - `tasks/main.yml` — use `community.general.ufw` module (needs `community.general` collection — add to `requirements.yml`)
  - `defaults/main.yml` — default deny incoming, allow outgoing, policy/logging/reset
**C.4** — Pre-test: from Mac, verify SSH can still reach node under new rule set via ansible check mode.
**C.5** — Add **critical safety:** `ansible.builtin.command: ufw --force enable` only AFTER SSH rule deployed. Emergency recovery via homelab console if locked out.
**C.6** — Apply one node at a time; verify SSH survives after each; rollback via `ufw reset` + re-apply bash if ansible breaks.
**C.7** — Retire `setup-ufw-*.sh`.

### Success criteria
- `ufw status` matches template output on all 3 nodes
- SSH still works from Mac + between nodes
- Ansible re-run → `changed=0`

### Rollback
- Console access: `ufw reset && bash setup-ufw-k3s-<role>.sh` from local fs (keep a copy during migration).

---

## Phase D — Kernel/Network Hardening

**Targets (from `setup-node.sh` ~706 lines):**
- `/etc/ssh/sshd_config` drop-ins: post-quantum kex (`mlkem*`), strong ciphers (`chacha20-poly1305@openssh.com,aes256-gcm@openssh.com`), ETM MACs, port 65300, disable PasswordAuthentication, disable PermitRootLogin.
- sysctls: `/etc/sysctl.d/99-k3s-hardening.conf` (network, kernel, fs, IPv4 forwarding, tcp_*).
- kubelet timeout: `/var/lib/rancher/k3s/agent/etc/kubelet.conf` → `syncFrequency: 5m`, `nodeStatusUpdateFrequency: 5m`.
- `/etc/security/limits.d/` — file descriptor limits.
- `/etc/systemd/system.conf.d/` — default systemd tunings.

**Current mgmt:** `setup-node.sh` one-shot bash, 706 lines, no drift detection.

### Tasks

**D.1** — Audit current state: extract all sshd_config values, sysctls, kubelet params.
**D.2** — Scaffold `roles/hardening/`:
  - `tasks/ssh.yml` — sshd_config drop-in + reload sshd
  - `tasks/sysctl.yml` — `ansible.posix.sysctl` per value + persist
  - `tasks/kubelet.yml` — K3s kubelet override (edit via KUBELET_KUBECONFIG_ARGS or `/etc/rancher/k3s/kubelet.yaml`)
  - `tasks/limits.yml` — /etc/security/limits.d/
  - `templates/sshd_config.d-homelab.conf.j2`
  - `templates/sysctl-99-homelab.conf.j2`
  - `templates/kubelet.yaml.j2`
  - `handlers/main.yml` — reload sshd, sysctl -p, restart k3s / k3s-agent
**D.3** — SSH handling: **deploy drop-in in `/etc/ssh/sshd_config.d/99-homelab.conf`** (doesn't touch main sshd_config), validate with `sshd -t` before reload, have second SSH session open as safety net during first apply.
**D.4** — Test per-node: CP first (least risky — no rebuilderd), then workers.
**D.5** — Shrink `setup-node.sh` to bootstrap-critical only: K3s install, encryption-config (still bash), user groups, initial kubeconfig.

### Success criteria
- `ssh-audit` shows same/better score post-migration
- `sysctl -a` diff pre/post → zero unintended changes
- kubelet still healthy (`kubectl get nodes`), no NotReady
- `setup-node.sh` ≤ 250 lines (from 706)

### Rollback
- SSH drop-in: delete `/etc/ssh/sshd_config.d/99-homelab.conf`, reload sshd
- sysctls: revert file, `sysctl --system`
- kubelet: revert config, restart k3s/k3s-agent

---

## Phase E — Ad-Hoc One-Shots (Tag-Gated)

**Targets:**
- `enable-crash-logging.sh` — enables kernel.core_pattern, systemd-coredump, coredumpctl
- `update-firmware.sh` — fwupd refresh + update (or mark manual)
- `setup-claude-telegram.sh` — Claude Telegram bot cluster deploy helper

**Current mgmt:** ad-hoc scripts run by hand when needed, drift-prone.

### Tasks

**E.1** — Scaffold `roles/ad-hoc/`:
  - `tasks/crash-logging.yml` (tag: `crash-logging`)
  - `tasks/firmware-update.yml` (tag: `firmware`)
  - `tasks/claude-telegram.yml` (tag: `claude-telegram`)
**E.2** — Run on demand: `ansible-playbook node-config.yml --tags firmware --limit workers`
**E.3** — Document in README: tag catalog + when to run each.
**E.4** — Retire original bash scripts (or leave as docs-only references).

### Success criteria
- Each tag runs in isolation, doesn't affect daily drift-heal
- All scripts reproducible via ansible tags

---

## Global Rollout Order

1. **Session 1**: Phase A (commit, test 3-day drift-heal cycle).
2. **Session 2**: Phase B (rebuilderd — land when no active build OR after Sat weekly update).
3. **Session 3**: Phase C (UFW — highest lockout risk, schedule when Mac is physically near nodes).
4. **Session 4**: Phase D (SSH/sysctl — second-highest risk, console access ready).
5. **Session 5**: Phase E (cleanup, no risk).

---

## Drift Detection + Alerting (common to all phases)

- `node-maintenance-config.service` runs `ansible-playbook -D node-config.yml`, appends to `/var/log/node-maintenance/config.log`
- `ExecStopPost=telegram-notify.sh config "${SERVICE_RESULT}"` — parses last `changed=N failed=M` line; alerts if `changed>0` OR `failed>0`
- Alloy `loki.source.journal` already ingests `node-maintenance-config.service` (no extra work needed — unit name prefix match)
- VMRule `NodeConfigDrift` (new, optional): alerts if >N changes per week

---

## Success Criteria (overall)

- [ ] All 5 phases land, `ansible-playbook node-config.yml` → `changed=0` cluster-wide
- [ ] `setup-node.sh` ≤ 250 lines, `setup-rebuilderd-worker-*.sh` retired, `setup-ufw-*.sh` retired
- [ ] Timer fires daily, any drift → Telegram alert
- [ ] Single re-clone + install.sh → bootstraps a fresh node end-to-end (bootstrap remains bash; config remains ansible)
- [ ] Git log: each phase as 5-8 small commits; revert path clear
