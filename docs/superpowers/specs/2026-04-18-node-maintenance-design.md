# Node Maintenance — Design Spec

**Date**: 2026-04-18
**Author**: akhozya (via brainstorming session)
**Status**: Draft → User review
**Related**:
- Pending item added to `docs/HOMELAB_ANALYSIS.md` (cron/timer migration follow-up)
- Secret registered in `docs/SECRETS_ROTATION.md` (`node-maintenance-ssh`, annual rotation)

---

## 1. Purpose

Automate weekly Arch Linux package updates (official repos + AUR via `yay`) across all 3 K3s nodes with sequential reboots, failure-safe orchestration, and observability.

**Goals**:
- Hands-off weekly `yay -Syu` on control-plane (CP), worker-node (W1), worker-node-2 (W2).
- Strict ordering: CP → W1 → W2 (per user spec).
- Per-node stabilize + 5min final stabilize.
- `flux reconcile` post-update.
- Fix alerts (silence transients + report lingering post-run).
- Cleanup stale artifacts.
- Telegram notifications: start + success + failure.

**Non-goals** (deferred follow-ups):
- K3s version upgrades (use `system-upgrade-controller` separately).
- Migration of existing cleanup cron/timers to `node-maintenance` user ownership.
- Grafana dashboard + `NodeMaintenanceMissedRun` alert rule.
- Conditional reboot (only if kernel/glibc/systemd changed) — reconsider after 6 months ops data.

---

## 2. Decisions Made (during brainstorm)

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | Orchestrator = **control-plane** (two-phase systemd) | CP idle (load 0.28), always-on, natural phase break at reboot. |
| D2 | Tooling = **Ansible** end-to-end (`phase1.yml` + `phase2.yml`) | Industry standard for homelab k8s rolling updates; cleaner than bash; good error semantics. |
| D3 | Skip `kubectl drain`, rely on **K3s graceful shutdown** (`shutdownGracePeriod: 2m0s`) | All 19 PVCs on worker-node local LVM → local-path PV pins pods → drain can't reschedule anyway. Graceful shutdown sufficient. |
| D4 | **Cordon** workers before reboot (no drain) | Cheap; prevents new pods landing during reboot window. |
| D5 | Frequency = **Weekly** | Arch rolling = small diffs; failures surface fast. |
| D6 | Schedule = **Saturday 04:30 UTC** | Post-backup (replication done ~04:00 UTC), pre-Sunday Popeye/rebuilderd-cleanup. |
| D7 | Pause rebuilderd pre-reboot; auto-resume via existing `rebuilderd-worker-boot.timer` (+10min) | Preserves graceful abort; no explicit resume step needed. |
| D8 | AUR strategy = **A (full `yay -Syu --noconfirm --answerdiff=None --answerclean=None`)** | 8 AUR pkgs all trusted (firmware, flux-bin, yay, viddy, zsh-you-should-use); low attack surface. |
| D9 | Failure — update fail = **retry once, then abort**; reboot hang = **abort + alert**; crashloop = **continue (self-heal)** | Balanced safety. |
| D10 | Reboot = **always** (not conditional) | Homelab simplicity > reboot-save complexity. |
| D11 | Notifications = **Start + Success + Failure** via `backup-replication` Telegram bot secret (reused) | Consistent with backup pattern. |
| D12 | Fix alerts = **silence transients 30min + report lingering post-run** (no auto-remediation) | Safe — no risky auto-fix loops. |
| D13 | Cleanup = **pacman cache (`paccache -rk2`) + orphans + `crictl rmi --prune` + Failed pods + stale ReplicaSets (>14d) + Flux source GC** | Matches scope; RS 14-day safety window preserves rollback. |
| D14 | Dedicated user = **`node-maintenance`** (system account on all 3 nodes) | Single consistent identity; scoped sudoers; clean audit trail; future-proofs cleanup job ownership. |
| D15 | SSH key = **option B (SOPS-encrypted in repo, decrypted by install.sh to disk)** | Matches existing 51-SOPS-secret pattern; encrypted-at-rest in git; plain on CP disk during runtime (same tier as `/etc/rancher/k3s/k3s.yaml`). |
| D16 | Log filename = `phaseN-DD-MM-YYYY.log` with **UTC date** | Consistent with backup naming. |
| D17 | Repo path = `docs/scripts/node-maintenance/` | Matches existing `docs/scripts/` pattern (folder rename to `scripts/` deferred). |

---

## 3. Architecture

```
                    ┌─────────────────────────────────────────┐
                    │  control-plane (gmk-k3s-control-plane)  │
                    │                                          │
   systemd timer    │  Phase 1 (Sat 04:30 UTC):                │
   ─────────────▶   │  preflight → silence alerts 30min →      │
                    │  yay -Syu → touch flag → systemctl reboot│
                    │                                          │
                    │     (REBOOT — kubelet graceful shutdown) │
                    │                                          │
   on-boot unit     │  Phase 2 (ConditionPathExists=flag):     │
   ─────────────▶   │  wait k3s /readyz → SSH W1 (cordon →    │
                    │  yay → reboot → wait Ready → uncordon →  │
                    │  stabilize) → SSH W2 same → 5min stabil. │
                    │  → flux reconcile → cleanup → alert      │
                    │  recheck → Telegram summary → rm flag    │
                    └──────────┬──────────────────────────────┘
                               │ SSH (port 65300, dedicated key)
                               ▼
                    ┌─────────────────┐     ┌─────────────────┐
                    │  worker-node    │     │  worker-node-2  │
                    │  node-maintenance user                  │
                    └─────────────────┘     └─────────────────┘
```

---

## 4. File Layout

### Repo (source of truth)

```
docs/scripts/node-maintenance/
├── README.md                               # Operator runbook
├── ansible/
│   ├── phase1.yml                          # CP self-update
│   ├── phase2.yml                          # Worker loop + post-tasks
│   ├── inventory.yml                       # Workers + connection config
│   ├── group_vars/all.yml                  # Paths, timeouts, Telegram refs
│   ├── tasks/telegram.yml                  # Shared notification include
│   └── requirements.yml                    # `kubernetes.core` collection
├── systemd/
│   ├── node-maintenance.timer
│   ├── node-maintenance-phase1.service
│   ├── node-maintenance-phase2.service
│   └── rebuilderd-worker-override.conf     # Drop-in: TimeoutStopSec=60s (workers only)
├── lib/
│   ├── telegram-notify.sh                  # Bash helper (used by systemd ExecStopPost)
│   └── known_hosts                         # Baked SSH host keys for workers
├── secrets/
│   └── id_ed25519.enc                      # SOPS-encrypted SSH private key
└── install.sh                              # Bootstrap script (root on CP)
```

### Deployed on control-plane (by `install.sh`)

```
/etc/node-maintenance/
├── ansible/                                # rsync from repo
├── known_hosts                             # SSH host keys (0644)
├── telegram-token                          # SOPS-decrypted (0400 root)
└── telegram-chat-id                        # SOPS-decrypted (0400 root)

/etc/systemd/system/
├── node-maintenance.timer
├── node-maintenance-phase1.service
└── node-maintenance-phase2.service

/var/lib/node-maintenance/                  # home dir for node-maintenance user
├── .ssh/
│   ├── id_ed25519                          # SOPS-decrypted (0600, node-maintenance)
│   └── known_hosts                         # -> /etc/node-maintenance/known_hosts
└── phase2-pending                          # runtime flag (created phase1, removed phase2)

/var/log/node-maintenance/                  # 0750 root:adm
├── phase1-DD-MM-YYYY.log
└── phase2-DD-MM-YYYY.log

/usr/local/sbin/telegram-notify.sh          # 0750 root:root
```

### Deployed on workers (by one-time manual bootstrap)

```
/etc/systemd/system/rebuilderd-worker@.service.d/override.conf
/etc/sudoers.d/node-maintenance
/var/lib/node-maintenance/.ssh/authorized_keys    # pub-key-only
```

---

## 5. User + Permissions

### `node-maintenance` user (all 3 nodes)

```bash
useradd -r -s /usr/bin/nologin -m -d /var/lib/node-maintenance node-maintenance
```

### Sudoers (`/etc/sudoers.d/node-maintenance`, mode 0440)

```
node-maintenance ALL=(root) NOPASSWD: /usr/bin/pacman, /usr/bin/paccache, /usr/bin/systemctl reboot, /usr/bin/systemctl stop rebuilderd-worker@1.service, /usr/bin/crictl
```

### File permissions

| Path | Owner | Mode |
|------|-------|------|
| `/etc/node-maintenance/ansible/*` | root:root | 0644 |
| `/etc/node-maintenance/inventory.yml` | root:root | 0600 |
| `/etc/node-maintenance/telegram-token` | root:root | 0400 |
| `/etc/node-maintenance/telegram-chat-id` | root:root | 0400 |
| `/var/lib/node-maintenance/` | node-maintenance:node-maintenance | 0750 |
| `/var/lib/node-maintenance/.ssh/id_ed25519` | node-maintenance:node-maintenance | 0600 |
| `/var/lib/node-maintenance/phase2-pending` | root:root | 0600 |
| `/var/log/node-maintenance/` | root:adm | 0750 |
| `/var/log/node-maintenance/*.log` | root:adm | 0640 |

---

## 6. Ansible Inventory

```yaml
# /etc/node-maintenance/ansible/inventory.yml
all:
  vars:
    ansible_ssh_common_args: '-o UserKnownHostsFile=/etc/node-maintenance/known_hosts -o StrictHostKeyChecking=yes'
    ansible_ssh_private_key_file: /var/lib/node-maintenance/.ssh/id_ed25519
    ansible_user: node-maintenance
    ansible_port: 65300
  children:
    workers:
      hosts:
        worker-node:
          ansible_host: 192.168.1.129
          k3s_service: k3s-agent.service
        worker-node-2:
          ansible_host: 192.168.1.126
          k3s_service: k3s-agent.service
```

CP is not in inventory — phase1 runs `connection: local` on CP itself.

---

## 7. Phase 1 Playbook (`phase1.yml`)

Runs on control-plane, `connection: local`, `become: true`.

**Tasks**:
1. **Preflight**:
   - Assert no active backup job (`kubectl get jobs -A | jq ...`)
   - Assert `/` free ≥ 5 GB, `/var` free ≥ 3 GB
   - Assert Flux kustomizations all `Ready=True`
   - Assert SSH reachability to both worker IPs via `node-maintenance` key
2. **Notify Telegram — run starting**.
3. **Silence transient alerts** via Alertmanager API (POST `/api/v2/silences`, 30min):
   - Matchers: `alertname =~ "KubePodCrashLooping|KubeNodeNotReady|TargetDown|KubePodNotReady|KubeletDown"`
   - Persist `silenceID` to `/var/lib/node-maintenance/silence-id`.
4. **Upgrade**:
   ```yaml
   - name: Upgrade via yay (pacman + AUR)
     ansible.builtin.shell: |
       sudo -u node-maintenance yay -Syu --noconfirm --answerdiff=None --answerclean=None --removemake
     register: yay_result
     changed_when: "'there is nothing to do' not in yay_result.stdout"
   ```
5. **Stage phase 2**:
   - Write `yay_result.stdout` to `/var/lib/node-maintenance/updated-packages.log`
   - `touch /var/lib/node-maintenance/phase2-pending` (mode 0600, root)
6. **Exit 0** → systemd `ExecStartPost=systemctl reboot` triggers reboot.

**On failure** (any task): playbook exits non-zero → systemd skips `ExecStartPost` (no reboot) → `ExecStopPost` sends Telegram failure alert → cluster remains healthy → operator intervenes.

---

## 8. Phase 2 Playbook (`phase2.yml`)

Runs on control-plane after boot. Two plays:

### Play 1: `hosts: workers, serial: 1`

```yaml
- name: Wait SSH reachability (sanity)
  ansible.builtin.wait_for_connection:
    timeout: 120

- name: Stop rebuilderd-worker (boot timer re-enables +10min)
  ansible.builtin.systemd_service:
    name: rebuilderd-worker@1.service
    state: stopped
  failed_when: false

- name: Cordon node
  kubernetes.core.k8s:
    kubeconfig: /etc/rancher/k3s/k3s.yaml
    state: patched
    kind: Node
    name: "{{ inventory_hostname }}"
    definition:
      spec:
        unschedulable: true
  delegate_to: localhost
  become: false

- name: Upgrade (with retry-once)
  block:
    - name: Upgrade via yay
      ansible.builtin.shell: |
        sudo -u node-maintenance yay -Syu --noconfirm --answerdiff=None --answerclean=None --removemake
      register: yay_result
      changed_when: "'there is nothing to do' not in yay_result.stdout"
  rescue:
    - name: Pause 30s then retry
      ansible.builtin.pause: { seconds: 30 }
    - name: Upgrade via yay (retry)
      ansible.builtin.shell: |
        sudo -u node-maintenance yay -Syu --noconfirm --answerdiff=None --answerclean=None --removemake

- name: Reboot node
  ansible.builtin.reboot:
    reboot_timeout: 400
    post_reboot_delay: 30
    test_command: "systemctl is-active {{ k3s_service }}"

- name: Wait node Ready in k8s
  kubernetes.core.k8s_info:
    kubeconfig: /etc/rancher/k3s/k3s.yaml
    kind: Node
    name: "{{ inventory_hostname }}"
  register: node_info
  until: >
    node_info.resources[0].status.conditions
    | selectattr('type','equalto','Ready')
    | selectattr('status','equalto','True')
    | list | length > 0
  retries: 40
  delay: 10
  delegate_to: localhost
  become: false

- name: Uncordon node
  kubernetes.core.k8s:
    kubeconfig: /etc/rancher/k3s/k3s.yaml
    state: patched
    kind: Node
    name: "{{ inventory_hostname }}"
    definition:
      spec:
        unschedulable: false
  delegate_to: localhost
  become: false

- name: Stabilize pause
  ansible.builtin.pause: { minutes: 3 }

- name: Observe crashloops (report-only, continue per D9)
  ansible.builtin.shell: |
    kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get pods -A -o json \
      | jq -r '.items[] | select(.status.containerStatuses[]?.state.waiting.reason=="CrashLoopBackOff")
              | "\(.metadata.namespace)/\(.metadata.name)"'
  register: crashloops
  delegate_to: localhost
  become: false
  changed_when: false
```

### Play 2: `hosts: localhost` (post-tasks)

```yaml
- name: 5-minute final stabilize
  ansible.builtin.pause: { minutes: 5 }

- name: Flux reconcile kustomizations
  ansible.builtin.shell: |
    for ks in flux-system infrastructure-controllers infrastructure-configs apps monitoring-configs monitoring-controllers; do
      flux reconcile kustomization $ks --timeout=60s || echo "FAILED: $ks"
    done
  register: flux_result
  changed_when: false

- name: Cleanup — per-node via SSH
  ansible.builtin.shell: |
    ssh -p 65300 -i /var/lib/node-maintenance/.ssh/id_ed25519 \
        -o UserKnownHostsFile=/etc/node-maintenance/known_hosts \
        node-maintenance@{{ item }} '
      sudo paccache -rk2 && sudo paccache -ruk0
      ORPHANS=$(pacman -Qtdq || true)
      [ -n "$ORPHANS" ] && sudo pacman -Rns --noconfirm $ORPHANS || true
      sudo crictl rmi --prune || true
    '
  loop:
    - 127.0.0.1
    - 192.168.1.129
    - 192.168.1.126
  changed_when: false

- name: Cleanup — Failed/Evicted pods
  ansible.builtin.shell: |
    kubectl delete pod -A --field-selector=status.phase=Failed --ignore-not-found
  changed_when: false

- name: Cleanup — stale ReplicaSets (>14 days, 0/0)
  ansible.builtin.shell: |
    CUTOFF=$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ)
    kubectl get rs -A -o json | jq -r --arg c "$CUTOFF" '
      .items[] | select(.spec.replicas==0 and .status.replicas==0 and .metadata.creationTimestamp < $c)
      | "-n \(.metadata.namespace) \(.metadata.name)"' |
    while read args; do kubectl delete rs $args; done
  changed_when: false

- name: Cleanup — Flux source GC trigger
  ansible.builtin.shell: flux reconcile source git flux-system --timeout=60s
  changed_when: false

- name: Re-check firing alerts
  ansible.builtin.uri:
    url: "http://alertmanager-operated.monitoring.svc.cluster.local:9093/api/v2/alerts?filter=alertstate%3Dfiring"
    return_content: true
  register: firing_alerts

- name: Delete auto-silence
  ansible.builtin.uri:
    url: "http://alertmanager-operated.monitoring.svc.cluster.local:9093/api/v2/silence/{{ lookup('file','/var/lib/node-maintenance/silence-id') }}"
    method: DELETE
    status_code: [200, 404]

- name: Write node_exporter textfile metrics
  ansible.builtin.copy:
    dest: /var/lib/node_exporter/textfile/node_maintenance.prom
    mode: '0644'
    content: |
      # HELP node_maintenance_last_run_unixtime Unix time of last successful run
      # TYPE node_maintenance_last_run_unixtime gauge
      node_maintenance_last_run_unixtime {{ ansible_date_time.epoch }}

- name: Build + send Telegram summary
  ansible.builtin.include_tasks: tasks/telegram.yml
  vars:
    tg_message: |
      Node maintenance complete.
      Packages updated: see /var/lib/node-maintenance/updated-packages.log
      Crashloops during run: {{ hostvars | dict2items | map(attribute='value.crashloops.stdout_lines') | flatten | default([]) | length }}
      Alerts still firing: {{ (firing_alerts.json | default([])) | length }}
      Log: /var/log/node-maintenance/phase2-{{ '%d-%m-%Y' | strftime(ansible_date_time.epoch) }}.log

- name: Remove phase2 flag
  ansible.builtin.file:
    path: /var/lib/node-maintenance/phase2-pending
    state: absent
```

---

## 9. Shared Telegram Task (`tasks/telegram.yml`)

```yaml
- name: Send Telegram message
  ansible.builtin.uri:
    url: "https://api.telegram.org/bot{{ lookup('file', '/etc/node-maintenance/telegram-token') }}/sendMessage"
    method: POST
    body_format: json
    body:
      chat_id: "{{ lookup('file', '/etc/node-maintenance/telegram-chat-id') }}"
      text: "{{ tg_message }}"
      parse_mode: Markdown
    status_code: 200
  no_log: true
```

---

## 10. systemd Units

### `node-maintenance.timer`

```ini
[Unit]
Description=Node maintenance — weekly trigger
Documentation=file:///etc/node-maintenance/README.md

[Timer]
OnCalendar=Sat *-*-* 04:30:00 UTC
Persistent=true
RandomizedDelaySec=60
Unit=node-maintenance-phase1.service

[Install]
WantedBy=timers.target
```

### `node-maintenance-phase1.service`

```ini
[Unit]
Description=Node maintenance — Phase 1 (CP self-update)
ConditionPathExists=!/var/lib/node-maintenance/phase2-pending
Wants=network-online.target
After=network-online.target k3s.service
Documentation=file:///etc/node-maintenance/README.md

[Service]
Type=oneshot
User=root
WorkingDirectory=/etc/node-maintenance/ansible
ExecStartPre=/bin/sh -c 'install -d -m 0750 -o root -g adm /var/log/node-maintenance; echo "ANSIBLE_LOG_PATH=/var/log/node-maintenance/phase1-$(date -u +%%d-%%m-%%Y).log" > /run/node-maintenance.env'
EnvironmentFile=-/run/node-maintenance.env
ExecStart=/usr/bin/ansible-playbook -i inventory.yml phase1.yml
ExecStartPost=/bin/sh -c 'systemctl reboot'
ExecStopPost=/bin/sh -c '[ "$EXIT_STATUS" != "0/SUCCESS" ] && /usr/local/sbin/telegram-notify.sh "❌ node-maintenance phase1 failed (exit $EXIT_STATUS). No reboot. Log: /var/log/node-maintenance/phase1-$(date -u +%%d-%%m-%%Y).log" || true'
TimeoutStartSec=30min
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
```

### `node-maintenance-phase2.service`

```ini
[Unit]
Description=Node maintenance — Phase 2 (post-reboot workers + cleanup)
ConditionPathExists=/var/lib/node-maintenance/phase2-pending
Wants=network-online.target
After=network-online.target k3s.service
Documentation=file:///etc/node-maintenance/README.md

[Service]
Type=oneshot
User=root
WorkingDirectory=/etc/node-maintenance/ansible
ExecStartPre=/bin/sh -c 'install -d -m 0750 -o root -g adm /var/log/node-maintenance; echo "ANSIBLE_LOG_PATH=/var/log/node-maintenance/phase2-$(date -u +%%d-%%m-%%Y).log" > /run/node-maintenance.env'
EnvironmentFile=-/run/node-maintenance.env
ExecStartPre=/bin/bash -c 'for i in {1..60}; do kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get --raw /readyz 2>/dev/null | grep -q ok && exit 0; sleep 5; done; exit 1'
ExecStart=/usr/bin/ansible-playbook -i inventory.yml phase2.yml
ExecStartPost=/bin/rm -f /var/lib/node-maintenance/phase2-pending
ExecStopPost=/bin/sh -c '[ "$EXIT_STATUS" != "0/SUCCESS" ] && /usr/local/sbin/telegram-notify.sh "❌ node-maintenance phase2 failed (exit $EXIT_STATUS). Flag retained. Log: /var/log/node-maintenance/phase2-$(date -u +%%d-%%m-%%Y).log" || true'
TimeoutStartSec=90min
Nice=10

[Install]
WantedBy=multi-user.target
```

### `rebuilderd-worker-override.conf` (workers only)

```ini
# Drop-in at /etc/systemd/system/rebuilderd-worker@.service.d/override.conf
[Service]
TimeoutStopSec=60s
```

Overrides upstream `TimeoutStopUSec=2h` so reboot flow doesn't hang.

---

## 11. Install Script Outline (`install.sh`)

Runs as root on CP. Idempotent.

1. Preconditions: running as root; `ansible --version` works; `kubectl` on PATH; `/etc/rancher/k3s/k3s.yaml` readable; SOPS + age key available for decryption.
2. `useradd -r -s /usr/bin/nologin -m -d /var/lib/node-maintenance node-maintenance` (if not exists)
3. `ansible-galaxy collection install -r requirements.yml`
4. `rsync -a --delete docs/scripts/node-maintenance/ansible/ /etc/node-maintenance/ansible/`
5. Decrypt SOPS artifacts:
   - `secrets/id_ed25519.enc` → `/var/lib/node-maintenance/.ssh/id_ed25519` (0600 node-maintenance)
   - Telegram token + chat-id (decrypted from existing `backup-replication` secret or dedicated new SOPS file) → `/etc/node-maintenance/telegram-*` (0400 root)
6. Copy `known_hosts` to `/etc/node-maintenance/known_hosts` (0644 root)
7. Install `telegram-notify.sh` → `/usr/local/sbin/` (0750 root)
8. Install systemd unit files → `/etc/systemd/system/`
9. `systemctl daemon-reload`
10. `systemctl enable --now node-maintenance.timer`
11. `systemctl enable node-maintenance-phase2.service` (not `--now` — only boot-trigger)
12. Print bootstrap instructions for workers (user runs manually):
    - Create `node-maintenance` user
    - Append pub key to `/var/lib/node-maintenance/.ssh/authorized_keys`
    - Install sudoers file
    - Install `rebuilderd-worker-override.conf`
    - `systemctl daemon-reload`
13. Print next scheduled run time.

---

## 12. Observability

### Logs
- systemd journald: `journalctl -u node-maintenance-phase{1,2}.service`
- Ansible file: `/var/log/node-maintenance/phaseN-DD-MM-YYYY.log` (UTC)
- Alloy DaemonSet collects journald → Loki (existing — no change required for base visibility).

### Metrics
- `node_exporter --collector.textfile.directory=/var/lib/node_exporter/textfile` (already configured).
- phase2 writes `node_maintenance.prom` with `node_maintenance_last_run_unixtime` gauge.
- Follow-up PR: add `NodeMaintenanceMissedRun` alert (>10d since last success).

### Notifications
- **Start**: "🔧 Node maintenance starting on {{ hostname }} (phase 1)"
- **Success**: summary with packages updated, crashloops observed, lingering alerts, log path
- **Failure**: systemd `ExecStopPost` handler sends specific phase failure + log path
- Channel: `backup-replication-telegram-secret` (or dedicated — decide at implementation)

---

## 13. Risk Register

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|-----------|--------|------------|
| R1 | CP kernel panic on reboot | Low | Critical | Pre-flight; workers untouched; manual IPMI recovery. |
| R2 | Worker stuck cordoned | Low | Medium | Retained cordon visible; runbook has recovery steps. |
| R3 | Half-upgraded system (pacman ok, yay fail) | Very Low | Critical | Pacman atomic; yay fail → reboot aborted. |
| R4 | Compromised AUR PKGBUILD | Low | High | Accepted (D8); annual SSH key rotation limits blast radius. |
| R5 | Backup overlap | Low | Medium | Preflight aborts if active backup job. |
| R6 | Phase 2 unit disabled | Very Low | High | `install.sh` enables + verifies. |
| R7 | HA DB failover fails | Low | High | Graceful shutdown 2min; tested HA path. |
| R8 | SSH key compromise | Low | Critical | Annual rotation; scoped sudoers. |
| R9 | Silence not cleaned | Low | Medium | 30min cap (auto-expires). |
| R10 | Rebuilderd 2h stop blocks reboot | Medium (pre-fix) | High | **Resolved** via `TimeoutStopSec=60s` override. |

---

## 14. Rollout Plan

| Stage | Description | Duration |
|-------|-------------|----------|
| 0 | Pre-deploy: verify user/sudoers on one worker; SOPS decrypt test | 1h |
| 1 | Dry-run phase2 (`--check --diff --limit worker-node`) | 10min |
| 2 | Manual single-node run per worker (timer disabled) | 30min each |
| 3 | Manual full run (phase1 + phase2, off-schedule) | 90min |
| 4 | Enable timer; monitor 2 scheduled runs closely | 2 weeks |
| 5 | Steady state; monthly review | ongoing |

---

## 15. Runbook (Essential Ops)

```bash
# Next scheduled run
systemctl list-timers node-maintenance.timer

# Last run status
journalctl -u node-maintenance-phase{1,2}.service -n 200

# Manual full run (off-schedule)
systemctl start node-maintenance-phase1.service

# Skip this week's run
systemctl stop node-maintenance.timer        # re-enable: systemctl start

# Dry run (no changes)
cd /etc/node-maintenance/ansible
ansible-playbook -i inventory.yml phase2.yml --check --diff --limit worker-node

# Recovery — phase2 failed, flag retained
# Fix root cause (cordoned node, flux issue, etc.), then:
rm /var/lib/node-maintenance/phase2-pending

# Recovery — node stuck cordoned
kubectl uncordon <node>

# Rollback a bad package
ssh -p 65300 node-maintenance@<node> 'sudo pacman -U /var/cache/pacman/pkg/<pkg>-<prev>.pkg.tar.zst'

# SSH key rotation (annual; update docs/SECRETS_ROTATION.md)
# 1. ssh-keygen -t ed25519 -f /tmp/new_key -N ""
# 2. sops encrypt --age <age-public-key> /tmp/new_key > docs/scripts/node-maintenance/secrets/id_ed25519.enc
# 3. Append new pub to authorized_keys on all workers
# 4. Run install.sh on CP
# 5. Test: sudo -u node-maintenance ssh -p 65300 node-maintenance@worker-node true
# 6. Remove old pub from workers
# 7. Update SECRETS_ROTATION.md
```

---

## 16. Open Items / Follow-up PRs

| # | Item | Priority |
|---|------|----------|
| F1 | Migrate existing node cleanup cron/timers to `node-maintenance` user | P3 |
| F2 | Alloy journal label customization for `job=node-maintenance` | P3 |
| F3 | Grafana dashboard (last run, duration trend, pkg count, logs panel) | P3 |
| F4 | `NodeMaintenanceMissedRun` alert rule | P3 |
| F5 | Fix stale flux kustomization list in `CLAUDE.md` | P3 |
| F6 | Revisit conditional-reboot policy after 6 months of ops data | P4 |

---

## 17. Acknowledged Limitations

1. `yay --removemake` may leave orphan deps — covered by cleanup step but imperfect.
2. ReplicaSet 14-day cleanup heuristic is arbitrary; won't match Deployment `revisionHistoryLimit` for low-change apps.
3. Silence alert list (5 names) may miss cluster-specific alerts — refine after first runs.
4. 90min `TimeoutStartSec` is estimate; adjust after observed P95.
5. Ansible-playbook hang risks 90min silence before `ExecStopPost` alert — acceptable.
6. Existing node cleanup jobs not enumerated — deferred to F1.

---

*End of spec.*
