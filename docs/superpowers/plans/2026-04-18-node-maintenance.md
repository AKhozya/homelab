# Node Maintenance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automate weekly Arch Linux node updates (official repos + AUR via `yay`) across 3 K3s nodes with sequential reboots, failure-safe orchestration, and observability.

**Architecture:** Two-phase systemd-driven Ansible flow on control-plane. Phase 1 = CP self-update + reboot. Phase 2 = worker loop (SSH, cordon, `yay -Syu`, reboot, wait-Ready, uncordon) + cleanup + Telegram notify. Saturday 04:30 UTC weekly. Dedicated `node-maintenance` system user on all 3 nodes.

**Tech Stack:** Ansible 2.19+ with `kubernetes.core` collection, systemd timers + services, SOPS + age for SSH key encryption, bash wrappers, K3s 1.33.x, Arch Linux 6.18 LTS.

**Spec:** `docs/superpowers/specs/2026-04-18-node-maintenance-design.md`

---

## File Structure

```
docs/scripts/node-maintenance/
├── README.md                               # Operator runbook
├── install.sh                              # CP bootstrap (root)
├── install-worker.sh                       # Worker bootstrap (root)
├── ansible/
│   ├── requirements.yml                    # Collection dependencies
│   ├── inventory.yml                       # Worker connection data
│   ├── group_vars/
│   │   └── all.yml                         # Shared paths, timeouts
│   ├── phase1.yml                          # CP self-update playbook
│   ├── phase2.yml                          # Worker loop + post-tasks
│   └── tasks/
│       └── telegram.yml                    # Shared notification include
├── systemd/
│   ├── node-maintenance.timer
│   ├── node-maintenance-phase1.service
│   ├── node-maintenance-phase2.service
│   └── rebuilderd-worker-override.conf
├── lib/
│   ├── telegram-notify.sh                  # Bash helper for ExecStopPost
│   └── known_hosts                         # Baked SSH host keys
└── secrets/
    └── id_ed25519.enc                      # SOPS-encrypted SSH key
```

### Responsibility boundaries

| File | Responsibility |
|------|----------------|
| `ansible/phase1.yml` | CP preflight, alert silencing, `yay -Syu` on CP, flag file creation |
| `ansible/phase2.yml` | Per-worker update loop (`serial: 1`) + cluster-level cleanup |
| `ansible/tasks/telegram.yml` | Reusable Telegram API POST task |
| `ansible/inventory.yml` | Worker IP + user + port + SSH key path |
| `ansible/group_vars/all.yml` | Cross-playbook vars (alertmanager URL, timeouts) |
| `systemd/*.{timer,service}` | Scheduling + failure alerting glue |
| `systemd/rebuilderd-worker-override.conf` | Drop-in to cap rebuilderd stop timeout at 60s |
| `lib/telegram-notify.sh` | CLI helper invoked by systemd `ExecStopPost` |
| `install.sh` | CP-side idempotent bootstrap (user, dirs, SOPS decrypt, systemd enable) |
| `install-worker.sh` | Per-worker idempotent bootstrap (user, sudoers, override) |
| `secrets/id_ed25519.enc` | SOPS-encrypted SSH private key for `node-maintenance@CP` → `node-maintenance@workers` |

---

## Phase A — Scaffolding (structure + config)

### Task 1: Create directory skeleton

**Files:**
- Create: `docs/scripts/node-maintenance/` (dir)
- Create: `docs/scripts/node-maintenance/ansible/` (dir)
- Create: `docs/scripts/node-maintenance/ansible/group_vars/` (dir)
- Create: `docs/scripts/node-maintenance/ansible/tasks/` (dir)
- Create: `docs/scripts/node-maintenance/systemd/` (dir)
- Create: `docs/scripts/node-maintenance/lib/` (dir)
- Create: `docs/scripts/node-maintenance/secrets/` (dir)

- [ ] **Step 1: Create directory tree**

```bash
mkdir -p docs/scripts/node-maintenance/{ansible/{group_vars,tasks},systemd,lib,secrets}
```

- [ ] **Step 2: Verify structure**

Run: `find docs/scripts/node-maintenance -type d | sort`
Expected:
```
docs/scripts/node-maintenance
docs/scripts/node-maintenance/ansible
docs/scripts/node-maintenance/ansible/group_vars
docs/scripts/node-maintenance/ansible/tasks
docs/scripts/node-maintenance/lib
docs/scripts/node-maintenance/secrets
docs/scripts/node-maintenance/systemd
```

- [ ] **Step 3: Add .gitkeep files (empty dirs don't commit otherwise)**

```bash
touch docs/scripts/node-maintenance/secrets/.gitkeep
```

- [ ] **Step 4: Commit**

```bash
git add docs/scripts/node-maintenance/
git commit -m "Scaffold node-maintenance directory structure"
```

---

### Task 2: Create ansible collection requirements

**Files:**
- Create: `docs/scripts/node-maintenance/ansible/requirements.yml`

- [ ] **Step 1: Write requirements.yml**

Content:
```yaml
---
collections:
  - name: kubernetes.core
    version: ">=3.0.0,<4.0.0"
```

- [ ] **Step 2: Verify YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('docs/scripts/node-maintenance/ansible/requirements.yml'))"`
Expected: no output (valid YAML)

- [ ] **Step 3: Commit**

```bash
git add docs/scripts/node-maintenance/ansible/requirements.yml
git commit -m "Add ansible collection requirements for node-maintenance"
```

---

### Task 3: Create inventory file

**Files:**
- Create: `docs/scripts/node-maintenance/ansible/inventory.yml`

- [ ] **Step 1: Write inventory.yml**

Content:
```yaml
---
all:
  vars:
    ansible_ssh_common_args: '-o UserKnownHostsFile=/etc/node-maintenance/known_hosts -o StrictHostKeyChecking=yes -o ConnectTimeout=10'
    ansible_ssh_private_key_file: /var/lib/node-maintenance/.ssh/id_ed25519
    ansible_user: node-maintenance
    ansible_port: 65300
    ansible_python_interpreter: /usr/bin/python3
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

- [ ] **Step 2: Verify YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('docs/scripts/node-maintenance/ansible/inventory.yml'))"`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add docs/scripts/node-maintenance/ansible/inventory.yml
git commit -m "Add ansible inventory for node-maintenance workers"
```

---

### Task 4: Create group_vars/all.yml

**Files:**
- Create: `docs/scripts/node-maintenance/ansible/group_vars/all.yml`

- [ ] **Step 1: Write group_vars/all.yml**

Content:
```yaml
---
# Paths
state_dir: /var/lib/node-maintenance
flag_file: "{{ state_dir }}/phase2-pending"
log_dir: /var/log/node-maintenance
silence_id_file: "{{ state_dir }}/silence-id"
updated_packages_log: "{{ state_dir }}/updated-packages.log"
metrics_file: /var/lib/node_exporter/textfile/node_maintenance.prom

# Credentials (populated by install.sh)
telegram_token_file: /etc/node-maintenance/telegram-token
telegram_chat_id_file: /etc/node-maintenance/telegram-chat-id

# Kubernetes
kubeconfig_path: /etc/rancher/k3s/k3s.yaml

# Alertmanager
alertmanager_url: "http://alertmanager-operated.monitoring.svc.cluster.local:9093"
silence_duration_seconds: 1800   # 30 minutes
silence_alertnames: "KubeletDown|KubernetesAPIServerDown|DeploymentReplicasMismatch|StatefulSetReplicasMismatch|CloudflareTunnelDown|CloudflareTunnelPodNotRunning|CloudflareTunnelNoConnections|CouchDBDown|CouchDBPodNotRunning|FluxReconciliationFailure|FluxSourceNotReady|KyvernoAdmissionControllerDown|LokiDown|LokiCompactorNotRunning|MySQLDown|MySQLHAProxyNotRunning|MySQLOrchestratorNotRunning|RedisDown|RedisPodNotRunning|AlertmanagerFailedToSendAlerts|AlloyDown|AlloyLogDeliveryFailing|DaemonSetNotScheduled|TraefikDown|RebuilderdWorkerDown|PrometheusTargetDown|KubePodCrashLooping|KubePodNotReady|TargetDown|TooManyPodsPending|JobFailed"

# Preflight thresholds
min_free_root_gb: 5
min_free_var_gb: 3

# Reboot / stabilization
reboot_timeout_sec: 400
post_reboot_delay_sec: 30
node_ready_retries: 40
node_ready_delay_sec: 10
per_node_stabilize_minutes: 3
final_stabilize_minutes: 5

# Flux kustomizations to reconcile
flux_kustomizations:
  - flux-system
  - infrastructure-controllers
  - infrastructure-configs
  - apps
  - monitoring-configs
  - monitoring-controllers

# yay command (used in both phases)
yay_cmd: "sudo -u node-maintenance yay -Syu --noconfirm --answerdiff=None --answerclean=None --removemake"
```

- [ ] **Step 2: Verify YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('docs/scripts/node-maintenance/ansible/group_vars/all.yml'))"`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add docs/scripts/node-maintenance/ansible/group_vars/all.yml
git commit -m "Add node-maintenance ansible group_vars"
```

---

## Phase B — Playbooks

### Task 5: Write shared Telegram task include

**Files:**
- Create: `docs/scripts/node-maintenance/ansible/tasks/telegram.yml`

- [ ] **Step 1: Write tasks/telegram.yml**

Content:
```yaml
---
# Shared include. Callers must set `tg_message` in `vars:`.
- name: Send Telegram notification
  ansible.builtin.uri:
    url: "https://api.telegram.org/bot{{ lookup('file', telegram_token_file) | trim }}/sendMessage"
    method: POST
    body_format: json
    body:
      chat_id: "{{ lookup('file', telegram_chat_id_file) | trim }}"
      text: "{{ tg_message }}"
      parse_mode: Markdown
    status_code: [200]
  no_log: true
  register: telegram_result
  failed_when: false   # never fail the playbook because Telegram API hiccuped
```

- [ ] **Step 2: Verify YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('docs/scripts/node-maintenance/ansible/tasks/telegram.yml'))"`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add docs/scripts/node-maintenance/ansible/tasks/telegram.yml
git commit -m "Add shared Telegram notification ansible task"
```

---

### Task 6: Write phase1.yml (CP self-update playbook)

**Files:**
- Create: `docs/scripts/node-maintenance/ansible/phase1.yml`

- [ ] **Step 1: Write phase1.yml**

Content:
```yaml
---
- name: Node maintenance — Phase 1 (control-plane self-update)
  hosts: localhost
  connection: local
  become: true
  gather_facts: true

  tasks:

    # ── PREFLIGHT ──────────────────────────────────────────────
    - name: Preflight — no active backup/replication job
      ansible.builtin.shell: |
        set -o pipefail
        kubectl --kubeconfig={{ kubeconfig_path }} get jobs -A -o json \
          | jq -r '[.items[] | select(.metadata.name | test("backup|replication")) | select(.status.active == 1)] | length'
      args:
        executable: /bin/bash
      register: active_backups
      changed_when: false
      failed_when: (active_backups.stdout | int) > 0

    - name: Preflight — root free space
      ansible.builtin.assert:
        that:
          - (ansible_mounts | selectattr('mount','equalto','/') | list | first).size_available > (min_free_root_gb * 1073741824)
        fail_msg: "Free space on / below {{ min_free_root_gb }} GB"

    - name: Preflight — /var free space
      ansible.builtin.assert:
        that:
          - (ansible_mounts | selectattr('mount','equalto','/var') | list | first | default({'size_available': 9999999999999})).size_available > (min_free_var_gb * 1073741824)
        fail_msg: "Free space on /var below {{ min_free_var_gb }} GB"

    - name: Preflight — Flux kustomizations all Ready
      ansible.builtin.shell: |
        set -o pipefail
        kubectl --kubeconfig={{ kubeconfig_path }} get kustomization -n flux-system -o json \
          | jq -e '[.items[] | select(.status.conditions[]? | select(.type=="Ready") | .status != "True")] | length == 0'
      args:
        executable: /bin/bash
      changed_when: false

    - name: Preflight — workers reachable
      ansible.builtin.command: >-
        ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=yes
            -o UserKnownHostsFile=/etc/node-maintenance/known_hosts
            -p 65300 -i {{ state_dir }}/.ssh/id_ed25519
            node-maintenance@{{ item }} true
      loop:
        - 192.168.1.129
        - 192.168.1.126
      changed_when: false

    # ── NOTIFY START ──────────────────────────────────────────
    - name: Telegram — run starting
      ansible.builtin.include_tasks: tasks/telegram.yml
      vars:
        tg_message: "🔧 Node maintenance phase 1 starting on {{ ansible_hostname }}. Log: /var/log/node-maintenance/phase1-{{ '%d-%m-%Y' | strftime(ansible_date_time.epoch | int) }}.log"

    # ── SILENCE TRANSIENT ALERTS ──────────────────────────────
    - name: Silence transient alerts for {{ silence_duration_seconds // 60 }} minutes
      ansible.builtin.uri:
        url: "{{ alertmanager_url }}/api/v2/silences"
        method: POST
        body_format: json
        body:
          matchers:
            - { name: "alertname", value: "{{ silence_alertnames }}", isRegex: true }
          startsAt: "{{ '%Y-%m-%dT%H:%M:%SZ' | strftime(ansible_date_time.epoch | int) }}"
          endsAt: "{{ '%Y-%m-%dT%H:%M:%SZ' | strftime((ansible_date_time.epoch | int) + silence_duration_seconds) }}"
          createdBy: "node-maintenance"
          comment: "Auto-silence during scheduled node update run"
        status_code: 200
      register: silence_response

    - name: Persist silence ID
      ansible.builtin.copy:
        dest: "{{ silence_id_file }}"
        content: "{{ silence_response.json.silenceID }}"
        mode: '0600'
        owner: root
        group: root

    # ── UPGRADE ───────────────────────────────────────────────
    - name: Upgrade via yay (pacman + AUR)
      ansible.builtin.shell: "{{ yay_cmd }}"
      register: yay_result
      changed_when: "'there is nothing to do' not in yay_result.stdout"

    - name: Persist package update log
      ansible.builtin.copy:
        dest: "{{ updated_packages_log }}"
        content: "{{ yay_result.stdout }}"
        mode: '0644'
        owner: root
        group: root

    # ── STAGE PHASE 2 ─────────────────────────────────────────
    - name: Create phase2-pending flag
      ansible.builtin.file:
        path: "{{ flag_file }}"
        state: touch
        mode: '0600'
        owner: root
        group: root
```

- [ ] **Step 2: Verify YAML**

Run: `python3 -c "import yaml; list(yaml.safe_load_all(open('docs/scripts/node-maintenance/ansible/phase1.yml')))"`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add docs/scripts/node-maintenance/ansible/phase1.yml
git commit -m "Add phase1.yml: CP preflight + alert silence + yay upgrade + flag"
```

---

### Task 7: Write phase2.yml play 1 — worker loop

**Files:**
- Create: `docs/scripts/node-maintenance/ansible/phase2.yml`

- [ ] **Step 1: Write phase2.yml (plays 1 + 2)**

Content:
```yaml
---
# ──────────────────────────────────────────────────────────────
# PLAY 1: Per-worker rolling update (serial: 1)
# ──────────────────────────────────────────────────────────────
- name: Node maintenance — Phase 2 (worker rolling update)
  hosts: workers
  serial: 1
  gather_facts: false
  become: true

  tasks:
    - name: Verify SSH reachable before start
      ansible.builtin.wait_for_connection:
        timeout: 120

    - name: Stop rebuilderd-worker (boot timer re-enables at +10min)
      ansible.builtin.systemd_service:
        name: rebuilderd-worker@1.service
        state: stopped
      failed_when: false   # tolerate "not running"

    - name: Cordon node
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig_path }}"
        state: patched
        kind: Node
        name: "{{ inventory_hostname }}"
        definition:
          spec:
            unschedulable: true
      delegate_to: localhost
      become: false

    - name: Upgrade via yay (retry once on failure)
      block:
        - name: First attempt
          ansible.builtin.shell: "{{ yay_cmd }}"
          register: yay_result
          changed_when: "'there is nothing to do' not in yay_result.stdout"
      rescue:
        - name: Pause 30s before retry
          ansible.builtin.pause:
            seconds: 30
        - name: Retry attempt
          ansible.builtin.shell: "{{ yay_cmd }}"

    - name: Reboot node (graceful — shutdownGracePeriod 2min handles pods)
      ansible.builtin.reboot:
        reboot_timeout: "{{ reboot_timeout_sec }}"
        post_reboot_delay: "{{ post_reboot_delay_sec }}"
        test_command: "systemctl is-active {{ k3s_service }}"

    - name: Wait for node Ready in k8s API
      kubernetes.core.k8s_info:
        kubeconfig: "{{ kubeconfig_path }}"
        kind: Node
        name: "{{ inventory_hostname }}"
      register: node_info
      until: >
        node_info.resources | length > 0
        and (node_info.resources[0].status.conditions
             | selectattr('type','equalto','Ready')
             | selectattr('status','equalto','True')
             | list | length) > 0
      retries: "{{ node_ready_retries }}"
      delay: "{{ node_ready_delay_sec }}"
      delegate_to: localhost
      become: false

    - name: Uncordon node
      kubernetes.core.k8s:
        kubeconfig: "{{ kubeconfig_path }}"
        state: patched
        kind: Node
        name: "{{ inventory_hostname }}"
        definition:
          spec:
            unschedulable: false
      delegate_to: localhost
      become: false

    - name: Stabilize pause
      ansible.builtin.pause:
        minutes: "{{ per_node_stabilize_minutes }}"

    - name: Observe crashloops (report-only — decision: continue, self-heal)
      ansible.builtin.shell: |
        set -o pipefail
        kubectl --kubeconfig={{ kubeconfig_path }} get pods -A -o json \
          | jq -r '.items[] | select(.status.containerStatuses[]?.state.waiting.reason=="CrashLoopBackOff")
                  | "\(.metadata.namespace)/\(.metadata.name)"'
      args:
        executable: /bin/bash
      register: crashloops
      changed_when: false
      failed_when: false
      delegate_to: localhost
      become: false

# ──────────────────────────────────────────────────────────────
# PLAY 2: Cluster-level post-tasks (cleanup + alerts + notify)
# ──────────────────────────────────────────────────────────────
- name: Node maintenance — Phase 2 (post-tasks)
  hosts: localhost
  connection: local
  become: true
  gather_facts: true

  tasks:
    - name: Final 5-minute stabilize
      ansible.builtin.pause:
        minutes: "{{ final_stabilize_minutes }}"

    - name: Flux reconcile kustomizations
      ansible.builtin.shell: |
        flux reconcile kustomization {{ item }} --timeout=60s || echo "FAILED: {{ item }}"
      loop: "{{ flux_kustomizations }}"
      register: flux_results
      changed_when: false

    - name: Per-node cleanup (pacman cache, orphans, crictl image prune)
      ansible.builtin.shell: |
        ssh -p 65300 -i {{ state_dir }}/.ssh/id_ed25519 \
            -o UserKnownHostsFile=/etc/node-maintenance/known_hosts \
            -o StrictHostKeyChecking=yes \
            node-maintenance@{{ item }} '
          sudo paccache -rk2
          sudo paccache -ruk0
          ORPHANS=$(pacman -Qtdq || true)
          [ -n "$ORPHANS" ] && sudo pacman -Rns --noconfirm $ORPHANS || true
          sudo crictl rmi --prune || true
        '
      loop:
        - 127.0.0.1
        - 192.168.1.129
        - 192.168.1.126
      changed_when: false
      failed_when: false

    - name: Delete Failed/Evicted pods cluster-wide
      ansible.builtin.shell: |
        kubectl --kubeconfig={{ kubeconfig_path }} delete pod -A \
          --field-selector=status.phase=Failed --ignore-not-found
      changed_when: false

    - name: Trigger Flux source GC
      ansible.builtin.command: flux reconcile source git flux-system --timeout=60s
      changed_when: false

    - name: Re-check firing alerts
      ansible.builtin.uri:
        url: "{{ alertmanager_url }}/api/v2/alerts?filter=alertstate%3Dfiring"
        return_content: true
      register: firing_alerts

    - name: Read silence ID
      ansible.builtin.slurp:
        src: "{{ silence_id_file }}"
      register: silence_id_b64

    - name: Delete auto-silence
      ansible.builtin.uri:
        url: "{{ alertmanager_url }}/api/v2/silence/{{ silence_id_b64.content | b64decode | trim }}"
        method: DELETE
        status_code: [200, 404]

    - name: Emit node_exporter textfile metric
      ansible.builtin.copy:
        dest: "{{ metrics_file }}"
        mode: '0644'
        content: |
          # HELP node_maintenance_last_run_unixtime Unix time of last successful run
          # TYPE node_maintenance_last_run_unixtime gauge
          node_maintenance_last_run_unixtime {{ ansible_date_time.epoch }}

    - name: Read updated packages summary
      ansible.builtin.slurp:
        src: "{{ updated_packages_log }}"
      register: pkg_log_b64
      failed_when: false

    - name: Build Telegram summary message
      ansible.builtin.set_fact:
        tg_summary: |
          ✅ *Node maintenance complete*
          Nodes: CP, worker-node, worker-node-2
          Alerts still firing: {{ (firing_alerts.json | default([])) | length }}
          Log: /var/log/node-maintenance/phase2-{{ '%d-%m-%Y' | strftime(ansible_date_time.epoch | int) }}.log

    - name: Telegram — success summary
      ansible.builtin.include_tasks: tasks/telegram.yml
      vars:
        tg_message: "{{ tg_summary }}"

    - name: Remove phase2-pending flag (success)
      ansible.builtin.file:
        path: "{{ flag_file }}"
        state: absent
```

- [ ] **Step 2: Verify YAML**

Run: `python3 -c "import yaml; list(yaml.safe_load_all(open('docs/scripts/node-maintenance/ansible/phase2.yml')))"`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add docs/scripts/node-maintenance/ansible/phase2.yml
git commit -m "Add phase2.yml: worker rolling update + cluster-level cleanup/notify"
```

---

## Phase C — systemd Units

### Task 8: Create node-maintenance.timer

**Files:**
- Create: `docs/scripts/node-maintenance/systemd/node-maintenance.timer`

- [ ] **Step 1: Write node-maintenance.timer**

Content:
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

- [ ] **Step 2: Validate systemd syntax (offline)**

Run: `systemd-analyze verify docs/scripts/node-maintenance/systemd/node-maintenance.timer 2>&1 || true`
Expected: Warnings OK (unit refs unresolvable offline); no syntax errors.

- [ ] **Step 3: Commit**

```bash
git add docs/scripts/node-maintenance/systemd/node-maintenance.timer
git commit -m "Add node-maintenance.timer (Sat 04:30 UTC weekly)"
```

---

### Task 9: Create phase1.service

**Files:**
- Create: `docs/scripts/node-maintenance/systemd/node-maintenance-phase1.service`

- [ ] **Step 1: Write phase1.service**

Content:
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

- [ ] **Step 2: Validate systemd syntax**

Run: `systemd-analyze verify docs/scripts/node-maintenance/systemd/node-maintenance-phase1.service 2>&1 || true`
Expected: Warnings about missing ansible-playbook/sh paths offline OK; no syntax errors.

- [ ] **Step 3: Commit**

```bash
git add docs/scripts/node-maintenance/systemd/node-maintenance-phase1.service
git commit -m "Add phase1.service: runs phase1 playbook + reboots on success"
```

---

### Task 10: Create phase2.service

**Files:**
- Create: `docs/scripts/node-maintenance/systemd/node-maintenance-phase2.service`

- [ ] **Step 1: Write phase2.service**

Content:
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

- [ ] **Step 2: Validate systemd syntax**

Run: `systemd-analyze verify docs/scripts/node-maintenance/systemd/node-maintenance-phase2.service 2>&1 || true`
Expected: offline warnings OK; no syntax errors.

- [ ] **Step 3: Commit**

```bash
git add docs/scripts/node-maintenance/systemd/node-maintenance-phase2.service
git commit -m "Add phase2.service: boot-triggered post-reboot worker loop + cleanup"
```

---

### Task 11: Create rebuilderd-worker override drop-in

**Files:**
- Create: `docs/scripts/node-maintenance/systemd/rebuilderd-worker-override.conf`

- [ ] **Step 1: Write override.conf**

Content:
```ini
# Drop-in: /etc/systemd/system/rebuilderd-worker@.service.d/override.conf
# Caps graceful stop at 60s (upstream default TimeoutStopUSec=2h blocks reboots).
# Deployed by install-worker.sh.
[Service]
TimeoutStopSec=60s
```

- [ ] **Step 2: Commit**

```bash
git add docs/scripts/node-maintenance/systemd/rebuilderd-worker-override.conf
git commit -m "Add rebuilderd-worker override: TimeoutStopSec=60s (fixes reboot hang)"
```

---

## Phase D — Support Scripts

### Task 12: Create telegram-notify.sh helper

**Files:**
- Create: `docs/scripts/node-maintenance/lib/telegram-notify.sh`

- [ ] **Step 1: Write telegram-notify.sh**

Content:
```bash
#!/usr/bin/env bash
# telegram-notify.sh — CLI wrapper used by systemd ExecStopPost on phase failure.
# Reads token + chat-id from /etc/node-maintenance/, POSTs to Telegram Bot API.
# Usage: telegram-notify.sh "message text"
set -euo pipefail

MESSAGE="${1:-}"
[ -n "$MESSAGE" ] || { echo "Usage: $0 <message>" >&2; exit 1; }

TOKEN_FILE="/etc/node-maintenance/telegram-token"
CHAT_FILE="/etc/node-maintenance/telegram-chat-id"
[ -r "$TOKEN_FILE" ] || { echo "Missing $TOKEN_FILE" >&2; exit 1; }
[ -r "$CHAT_FILE" ]  || { echo "Missing $CHAT_FILE"  >&2; exit 1; }

TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
CHAT_ID="$(tr -d '[:space:]' < "$CHAT_FILE")"

curl -fsS --max-time 10 \
  -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg c "$CHAT_ID" --arg t "$MESSAGE" \
            '{chat_id: $c, text: $t, parse_mode: "Markdown"}')" \
  > /dev/null || echo "Telegram notify failed (ignored)" >&2
```

- [ ] **Step 2: Make executable + shellcheck**

Run:
```bash
chmod +x docs/scripts/node-maintenance/lib/telegram-notify.sh
shellcheck docs/scripts/node-maintenance/lib/telegram-notify.sh
```
Expected: no warnings.

- [ ] **Step 3: Commit**

```bash
git add docs/scripts/node-maintenance/lib/telegram-notify.sh
git commit -m "Add telegram-notify.sh helper for systemd ExecStopPost alerts"
```

---

### Task 13: Create install-worker.sh

**Files:**
- Create: `docs/scripts/node-maintenance/install-worker.sh`

- [ ] **Step 1: Write install-worker.sh**

Content:
```bash
#!/usr/bin/env bash
# install-worker.sh — idempotent per-worker bootstrap.
# Run as root on each worker (worker-node, worker-node-2).
# install.sh on CP substitutes PUB_KEY placeholder before scp to worker.
set -euo pipefail

PUB_KEY="__REPLACE_WITH_ACTUAL_PUBKEY__"
[ "$PUB_KEY" = "__REPLACE_WITH_ACTUAL_PUBKEY__" ] && { echo "PUB_KEY not substituted" >&2; exit 1; }
[ "$(id -u)" = "0" ] || { echo "Run as root" >&2; exit 1; }

# ── node-maintenance user ──
id node-maintenance >/dev/null 2>&1 || \
  useradd -r -s /usr/bin/nologin -m -d /var/lib/node-maintenance node-maintenance

install -d -m 0700 -o node-maintenance -g node-maintenance /var/lib/node-maintenance/.ssh

AK=/var/lib/node-maintenance/.ssh/authorized_keys
touch "$AK"
grep -qxF "$PUB_KEY" "$AK" || echo "$PUB_KEY" >> "$AK"
chown node-maintenance:node-maintenance "$AK"
chmod 0600 "$AK"

# ── sudoers ──
cat > /etc/sudoers.d/node-maintenance <<'EOF'
node-maintenance ALL=(root) NOPASSWD: /usr/bin/pacman, /usr/bin/paccache, /usr/bin/systemctl reboot, /usr/bin/systemctl stop rebuilderd-worker@1.service, /usr/bin/crictl
EOF
chmod 0440 /etc/sudoers.d/node-maintenance
visudo -c -f /etc/sudoers.d/node-maintenance

# ── rebuilderd-worker systemd override (60s stop) ──
install -d -m 0755 /etc/systemd/system/rebuilderd-worker@.service.d
cat > /etc/systemd/system/rebuilderd-worker@.service.d/override.conf <<'EOF'
[Service]
TimeoutStopSec=60s
EOF
systemctl daemon-reload

echo "Worker bootstrap complete on $(hostname)."
```

- [ ] **Step 2: Shellcheck + commit**

Run:
```bash
chmod +x docs/scripts/node-maintenance/install-worker.sh
shellcheck docs/scripts/node-maintenance/install-worker.sh
```
Expected: no warnings (one `SC2016` about single quotes in heredoc is acceptable; suppress with `# shellcheck disable=SC2016` if it appears).

- [ ] **Step 3: Commit**

```bash
git add docs/scripts/node-maintenance/install-worker.sh
git commit -m "Add install-worker.sh: idempotent worker-side bootstrap"
```

---

### Task 14: Create install.sh (CP bootstrap)

**Files:**
- Create: `docs/scripts/node-maintenance/install.sh`

- [ ] **Step 1: Write install.sh**

Content:
```bash
#!/usr/bin/env bash
# install.sh — CP-side bootstrap. Idempotent.
# Run as root on gmk-k3s-control-plane.
set -euo pipefail

[ "$(id -u)" = "0" ] || { echo "Run as root" >&2; exit 1; }

REPO_DIR="$(dirname "$(realpath "$0")")"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

# ── Preconditions ──
command -v ansible-playbook >/dev/null 2>&1 || pacman -S --noconfirm ansible
command -v sops >/dev/null 2>&1 || pacman -S --noconfirm sops
command -v kubectl >/dev/null 2>&1 || { echo "kubectl required" >&2; exit 1; }
command -v flux >/dev/null 2>&1 || { echo "flux required" >&2; exit 1; }
[ -r "$KUBECONFIG_PATH" ] || { echo "$KUBECONFIG_PATH not readable" >&2; exit 1; }
[ -n "${SOPS_AGE_KEY_FILE:-}" ] || export SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt
[ -r "$SOPS_AGE_KEY_FILE" ] || { echo "SOPS age key missing: $SOPS_AGE_KEY_FILE" >&2; exit 1; }

# ── user + dirs ──
id node-maintenance >/dev/null 2>&1 || \
  useradd -r -s /usr/bin/nologin -m -d /var/lib/node-maintenance node-maintenance

install -d -m 0750 -o root             -g root            /etc/node-maintenance
install -d -m 0750 -o root             -g adm             /var/log/node-maintenance
install -d -m 0700 -o node-maintenance -g node-maintenance /var/lib/node-maintenance/.ssh

# ── ansible playbooks + collections ──
rsync -a --delete "$REPO_DIR/ansible/" /etc/node-maintenance/ansible/
chmod 0600 /etc/node-maintenance/ansible/inventory.yml
ansible-galaxy collection install -r /etc/node-maintenance/ansible/requirements.yml --force

# ── SSH key (SOPS → disk) ──
sops --decrypt "$REPO_DIR/secrets/id_ed25519.enc" > /var/lib/node-maintenance/.ssh/id_ed25519
chown node-maintenance:node-maintenance /var/lib/node-maintenance/.ssh/id_ed25519
chmod 0600 /var/lib/node-maintenance/.ssh/id_ed25519

# Derive pub key from private (no separate storage)
ssh-keygen -y -f /var/lib/node-maintenance/.ssh/id_ed25519 \
  > /var/lib/node-maintenance/.ssh/id_ed25519.pub
chown node-maintenance:node-maintenance /var/lib/node-maintenance/.ssh/id_ed25519.pub
chmod 0644 /var/lib/node-maintenance/.ssh/id_ed25519.pub

# ── known_hosts ──
install -m 0644 "$REPO_DIR/lib/known_hosts" /etc/node-maintenance/known_hosts

# ── Telegram creds (reuse backup-replication/backup-telegram) ──
kubectl --kubeconfig="$KUBECONFIG_PATH" get secret -n backup-replication backup-telegram \
  -o jsonpath='{.data.bot_token}' | base64 -d > /etc/node-maintenance/telegram-token
chmod 0400 /etc/node-maintenance/telegram-token
kubectl --kubeconfig="$KUBECONFIG_PATH" get secret -n backup-replication backup-telegram \
  -o jsonpath='{.data.chat_id}' | base64 -d > /etc/node-maintenance/telegram-chat-id
chmod 0400 /etc/node-maintenance/telegram-chat-id

# ── notify helper + systemd units ──
install -m 0750 -o root -g root "$REPO_DIR/lib/telegram-notify.sh" /usr/local/sbin/telegram-notify.sh
install -m 0644 "$REPO_DIR/systemd/node-maintenance.timer"          /etc/systemd/system/
install -m 0644 "$REPO_DIR/systemd/node-maintenance-phase1.service" /etc/systemd/system/
install -m 0644 "$REPO_DIR/systemd/node-maintenance-phase2.service" /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now node-maintenance.timer
systemctl enable node-maintenance-phase2.service

# ── generate worker install scripts with pubkey substituted ──
PUB_KEY="$(cat /var/lib/node-maintenance/.ssh/id_ed25519.pub)"
WORKER_SCRIPT_OUT="/tmp/install-worker-ready.sh"
sed "s|__REPLACE_WITH_ACTUAL_PUBKEY__|${PUB_KEY}|" \
  "$REPO_DIR/install-worker.sh" > "$WORKER_SCRIPT_OUT"
chmod +x "$WORKER_SCRIPT_OUT"

cat <<EOF

╔═══════════════════════════════════════════════════════════════════╗
║  CP bootstrap complete.                                           ║
║  Next run: $(systemctl list-timers node-maintenance.timer --no-pager 2>/dev/null | awk 'NR==2{print $1,$2,$3}')
║                                                                   ║
║  Worker bootstrap (run from CP):                                  ║
║    scp -P 65300 $WORKER_SCRIPT_OUT akhozya@worker-node:/tmp/      ║
║    ssh -p 65300 akhozya@worker-node 'sudo bash /tmp/install-worker-ready.sh && rm /tmp/install-worker-ready.sh'
║                                                                   ║
║    scp -P 65300 $WORKER_SCRIPT_OUT z3us@worker-node-2:/tmp/       ║
║    ssh -p 65300 z3us@worker-node-2 'sudo bash /tmp/install-worker-ready.sh && rm /tmp/install-worker-ready.sh'
║                                                                   ║
║  After both workers bootstrapped, verify:                         ║
║    sudo -u node-maintenance ssh -p 65300 -i /var/lib/node-maintenance/.ssh/id_ed25519 -o UserKnownHostsFile=/etc/node-maintenance/known_hosts node-maintenance@192.168.1.129 true
║    sudo -u node-maintenance ssh -p 65300 -i /var/lib/node-maintenance/.ssh/id_ed25519 -o UserKnownHostsFile=/etc/node-maintenance/known_hosts node-maintenance@192.168.1.126 true
╚═══════════════════════════════════════════════════════════════════╝
EOF
```

- [ ] **Step 2: Shellcheck**

Run:
```bash
chmod +x docs/scripts/node-maintenance/install.sh
shellcheck docs/scripts/node-maintenance/install.sh
```
Expected: no errors. Silence any SC2016 / SC2154 that aren't actual issues via inline `# shellcheck disable` if needed.

- [ ] **Step 3: Commit**

```bash
git add docs/scripts/node-maintenance/install.sh
git commit -m "Add install.sh: CP-side bootstrap with SOPS decrypt + systemd enable"
```

---

## Phase E — Secrets

### Task 15: Generate SSH keypair + SOPS encrypt

**Files:**
- Create: `docs/scripts/node-maintenance/secrets/id_ed25519.enc` (SOPS-encrypted)

- [ ] **Step 1: Generate keypair (off-repo)**

```bash
ssh-keygen -t ed25519 -f /tmp/node-maint-key -N "" -C "node-maintenance@gmk-k3s-control-plane"
```
Expected: `/tmp/node-maint-key` (private) + `/tmp/node-maint-key.pub`.

- [ ] **Step 2: Verify `.sops.yaml` exists + has age key**

Run: `cat .sops.yaml | head -20`
Expected: age public key entry. If missing, follow existing repo SOPS pattern (see how other secrets are encrypted, e.g., `infrastructure/configs/staging/backup-replication/ssh-key-secret.yaml`).

- [ ] **Step 3: SOPS encrypt private key**

```bash
sops --encrypt --input-type binary --output-type binary \
  /tmp/node-maint-key \
  > docs/scripts/node-maintenance/secrets/id_ed25519.enc
```

- [ ] **Step 4: Verify decrypt round-trip**

```bash
sops --decrypt docs/scripts/node-maintenance/secrets/id_ed25519.enc \
  | diff - /tmp/node-maint-key
```
Expected: no output (identical).

- [ ] **Step 5: Save pub key to repo (for known_hosts reference — will bake into install-worker.sh via install.sh)**

```bash
# Pub key is derivable from private at runtime (install.sh does this).
# Capture pub for changelog + visibility:
cat /tmp/node-maint-key.pub
# Output example: ssh-ed25519 AAAAC3... node-maintenance@gmk-k3s-control-plane
# Save to a scratch file for Task 16:
cp /tmp/node-maint-key.pub /tmp/node-maint-key.pub.tmp
```

- [ ] **Step 6: Securely delete private from /tmp**

```bash
shred -u /tmp/node-maint-key
```

- [ ] **Step 7: Commit encrypted key**

```bash
git add docs/scripts/node-maintenance/secrets/id_ed25519.enc
git commit -m "Add SOPS-encrypted SSH private key for node-maintenance"
```

---

### Task 16: Bake known_hosts for workers

**Files:**
- Create: `docs/scripts/node-maintenance/lib/known_hosts`

- [ ] **Step 1: Scan worker host keys**

```bash
ssh-keyscan -p 65300 -H 192.168.1.129 192.168.1.126 2>/dev/null \
  > docs/scripts/node-maintenance/lib/known_hosts
```

- [ ] **Step 2: Verify format**

Run: `wc -l docs/scripts/node-maintenance/lib/known_hosts`
Expected: at least 2 lines (one per host + possibly more for ed25519/rsa/ecdsa).

- [ ] **Step 3: Cross-check against actual keys**

```bash
ssh-keygen -F "[192.168.1.129]:65300" -f docs/scripts/node-maintenance/lib/known_hosts
ssh-keygen -F "[192.168.1.126]:65300" -f docs/scripts/node-maintenance/lib/known_hosts
```
Expected: both commands return matching entries.

- [ ] **Step 4: Commit**

```bash
git add docs/scripts/node-maintenance/lib/known_hosts
git commit -m "Bake worker host keys into known_hosts for node-maintenance"
```

---

## Phase F — Lint + Smoke Tests

### Task 17: ansible-lint all playbooks

**Files:**
- Test: `docs/scripts/node-maintenance/ansible/*.yml`

- [ ] **Step 1: Install ansible-lint (one-time)**

```bash
pip3 install --user ansible-lint || brew install ansible-lint
```

- [ ] **Step 2: Run ansible-lint on playbooks**

Run:
```bash
cd docs/scripts/node-maintenance/ansible
ansible-lint phase1.yml phase2.yml
```
Expected: no errors. Warnings about `no-changed-when` OK because we set `changed_when` explicitly; fix any genuine issues.

- [ ] **Step 3: Fix any findings inline, recommit**

If fixes needed:
```bash
git add docs/scripts/node-maintenance/ansible/
git commit -m "Fix ansible-lint findings in phase1/phase2 playbooks"
```

---

### Task 18: Syntax-check playbooks with ansible-playbook --syntax-check

- [ ] **Step 1: Syntax-check phase1**

Run:
```bash
cd docs/scripts/node-maintenance/ansible
ansible-playbook -i inventory.yml phase1.yml --syntax-check
```
Expected: `playbook: phase1.yml` on success.

- [ ] **Step 2: Syntax-check phase2**

Run:
```bash
ansible-playbook -i inventory.yml phase2.yml --syntax-check
```
Expected: `playbook: phase2.yml`.

- [ ] **Step 3: If fixes needed, commit**

```bash
git add docs/scripts/node-maintenance/ansible/
git commit -m "Fix playbook syntax errors"
```

---

## Phase G — Documentation

### Task 19: Write README.md operator runbook

**Files:**
- Create: `docs/scripts/node-maintenance/README.md`

- [ ] **Step 1: Write README.md**

Content:
```markdown
# Node Maintenance

Automated weekly Arch Linux updates across all 3 K3s nodes.

**Schedule:** Saturday 04:30 UTC (via systemd timer on control-plane)
**Flow:** CP phase1 (update + reboot) → CP phase2 on boot (worker rolling update + cleanup)
**Notifications:** Telegram (reuses `backup-replication/backup-telegram` bot)

**Spec:** `docs/superpowers/specs/2026-04-18-node-maintenance-design.md`

---

## Install (one-time)

1. On control-plane:
   ```bash
   sudo bash /path/to/repo/docs/scripts/node-maintenance/install.sh
   ```
2. Follow the printed instructions to scp + run `install-worker-ready.sh` on each worker.
3. Verify:
   ```bash
   sudo -u node-maintenance ssh -p 65300 -i /var/lib/node-maintenance/.ssh/id_ed25519 \
     -o UserKnownHostsFile=/etc/node-maintenance/known_hosts \
     node-maintenance@192.168.1.129 true
   ```

## Day-to-day ops

```bash
# Next scheduled run
systemctl list-timers node-maintenance.timer

# Last run status
journalctl -u node-maintenance-phase1.service -u node-maintenance-phase2.service -n 200

# Manual full run (off-schedule)
sudo systemctl start node-maintenance-phase1.service

# Skip this week's run
sudo systemctl stop node-maintenance.timer      # re-enable later: start

# Dry run — worker-node, no changes
cd /etc/node-maintenance/ansible
sudo ansible-playbook -i inventory.yml phase2.yml --check --diff --limit worker-node

# View log
ls /var/log/node-maintenance/
less /var/log/node-maintenance/phase2-18-04-2026.log
```

## Recovery

### Phase 2 failed, flag retained
```bash
journalctl -u node-maintenance-phase2.service -n 500
# Fix root cause (cordoned node, failed flux kustomization, etc.)
kubectl uncordon <node>
flux reconcile kustomization <name>
# When cluster healthy:
sudo rm /var/lib/node-maintenance/phase2-pending
```

### Node stuck cordoned + unreachable
```bash
# Physical/IPMI console recovery, then:
kubectl uncordon <node>
sudo rm /var/lib/node-maintenance/phase2-pending
```

### Rollback a package
```bash
ssh -p 65300 <worker> 'sudo pacman -U /var/cache/pacman/pkg/<pkg>-<prev-version>.pkg.tar.zst'
```

## SSH key rotation (annual)

Tracked in `docs/SECRETS_ROTATION.md` under `node-maintenance-ssh`.

1. Generate new keypair: `ssh-keygen -t ed25519 -f /tmp/new_key -N ""`
2. SOPS-encrypt: `sops --encrypt --input-type binary --output-type binary /tmp/new_key > docs/scripts/node-maintenance/secrets/id_ed25519.enc`
3. Commit + push.
4. On each worker: append new pub to `/var/lib/node-maintenance/.ssh/authorized_keys`.
5. Run `install.sh` on CP (re-decrypts new key).
6. Verify: `sudo -u node-maintenance ssh ... node-maintenance@<worker> true`.
7. Remove old pub from workers' `authorized_keys`.
8. Update `docs/SECRETS_ROTATION.md` with new rotation date.
9. `shred -u /tmp/new_key /tmp/new_key.pub`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/scripts/node-maintenance/README.md
git commit -m "Add node-maintenance operator runbook"
```

---

### Task 20: Append CHANGELOG entry to HOMELAB_ANALYSIS.md

**Files:**
- Modify: `docs/HOMELAB_ANALYSIS.md`

- [ ] **Step 1: Read current changelog section**

Run: `grep -n '## CHANGELOG' docs/HOMELAB_ANALYSIS.md`
Expected: line number where CHANGELOG starts.

- [ ] **Step 2: Read "Recent highlights" list**

Run: `sed -n '/Recent highlights/,/^---$/p' docs/HOMELAB_ANALYSIS.md | head -15`
Expected: bullet list of recent changes.

- [ ] **Step 3: Prepend new bullet**

Edit `docs/HOMELAB_ANALYSIS.md`: under `**Recent highlights** (2026):`, add as the first bullet:
```
- 2026-04-18: Automated weekly node updates deployed — Sat 04:30 UTC, Ansible-driven, dedicated node-maintenance user, SOPS-encrypted SSH key, Telegram notifications
```

- [ ] **Step 4: Commit**

```bash
git add docs/HOMELAB_ANALYSIS.md
git commit -m "Log node-maintenance rollout in HOMELAB_ANALYSIS changelog"
```

---

## Phase H — Staged Rollout

### Task 21: Create PR for review

- [ ] **Step 1: Push branch**

If working on branch (not main):
```bash
git push -u origin <branch-name>
```
If working on main, skip to PR step.

- [ ] **Step 2: Open PR**

```bash
gh pr create \
  --title "Add node-maintenance: automated weekly Arch updates" \
  --body "Implements $(ls docs/superpowers/specs/ | grep node-maintenance). Weekly Sat 04:30 UTC. Full spec in commit. Test plan: manual stages 0-5 per spec §14."
```

- [ ] **Step 3: Self-review PR**

Run: `gh pr view --web`
Review: all files changed, diffs clean, no accidental includes.

- [ ] **Step 4: Merge (or wait for review)**

```bash
gh pr merge --squash --delete-branch
```

---

### Task 22: Stage 0 — Pre-deploy bootstrap verification

**Files:** (no changes — verification only)

- [ ] **Step 1: SSH to CP, pull latest main**

```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane "cd ~/source-code/homelab && git pull"
```

- [ ] **Step 2: Run install.sh on CP**

```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane "cd ~/source-code/homelab && sudo bash docs/scripts/node-maintenance/install.sh"
```
Expected: "CP bootstrap complete" + printed scp commands.

- [ ] **Step 3: Copy + run install-worker-ready.sh on worker-node**

```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane "sudo scp -P 65300 /tmp/install-worker-ready.sh akhozya@worker-node:/tmp/"
ssh -p 65300 akhozya@worker-node "sudo bash /tmp/install-worker-ready.sh && rm /tmp/install-worker-ready.sh"
```
Expected: "Worker bootstrap complete on worker-node".

- [ ] **Step 4: Copy + run on worker-node-2**

```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane "sudo scp -P 65300 /tmp/install-worker-ready.sh z3us@worker-node-2:/tmp/"
ssh -p 65300 z3us@worker-node-2 "sudo bash /tmp/install-worker-ready.sh && rm /tmp/install-worker-ready.sh"
```
Expected: "Worker bootstrap complete on worker-node-2".

- [ ] **Step 5: Verify SSH from CP → workers as node-maintenance**

```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane "sudo -u node-maintenance ssh -p 65300 -i /var/lib/node-maintenance/.ssh/id_ed25519 -o UserKnownHostsFile=/etc/node-maintenance/known_hosts node-maintenance@192.168.1.129 true"
ssh -p 65300 akhozya@gmk-k3s-control-plane "sudo -u node-maintenance ssh -p 65300 -i /var/lib/node-maintenance/.ssh/id_ed25519 -o UserKnownHostsFile=/etc/node-maintenance/known_hosts node-maintenance@192.168.1.126 true"
```
Expected: silent success (exit 0 on both).

- [ ] **Step 6: Verify systemd timer enabled**

```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane "systemctl status node-maintenance.timer --no-pager"
```
Expected: `Active: active (waiting)`, next trigger Saturday 04:30 UTC.

- [ ] **Step 7: If any step failed, diagnose + re-run install.sh (idempotent)**

---

### Task 23: Stage 1 — Dry-run phase2 on worker-node (no changes)

- [ ] **Step 1: Stop timer to prevent automatic run during testing**

```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane "sudo systemctl stop node-maintenance.timer"
```

- [ ] **Step 2: Run phase2 in --check mode against worker-node only**

```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane "cd /etc/node-maintenance/ansible && sudo ansible-playbook -i inventory.yml phase2.yml --check --diff --limit worker-node"
```
Expected: all tasks `ok` or `changed` (in check mode, no actual changes). No errors.

- [ ] **Step 3: Review output**

Look for: failed tasks (red), unresolved vars (`undefined`), missing collections. If issues, fix in repo + re-run.

---

### Task 24: Stage 2 — Manual single-node reboot on worker-node

- [ ] **Step 1: Verify cluster healthy before start**

```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane "kubectl get nodes; flux get kustomizations -A | head -10; kubectl get pods -A | grep -v Running | head -10"
```
Expected: all nodes Ready, all Flux kustomizations Ready, no non-Running pods (Completed OK).

- [ ] **Step 2: Run phase2 against worker-node only**

```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane "cd /etc/node-maintenance/ansible && sudo ansible-playbook -i inventory.yml phase2.yml --limit worker-node"
```
Watch: cordon → yay → reboot (~3min) → node Ready → uncordon → 3min stabilize → post-tasks (flux reconcile + cleanup + Telegram).
Expected: full play completes, exit 0, Telegram "complete" message received.

- [ ] **Step 3: Verify post-state**

```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane "kubectl get nodes; kubectl get pods -A --field-selector=status.phase=Failed; flux get kustomizations -A"
```
Expected: all nodes Ready + schedulable (no `SchedulingDisabled`), no Failed pods, all Flux Ready.

- [ ] **Step 4: Verify phase2-pending flag removed**

```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane "ls /var/lib/node-maintenance/phase2-pending 2>&1"
```
Expected: `No such file or directory`.

---

### Task 25: Stage 2b — Repeat on worker-node-2

- [ ] **Step 1: Run phase2 against worker-node-2 only**

```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane "cd /etc/node-maintenance/ansible && sudo ansible-playbook -i inventory.yml phase2.yml --limit worker-node-2"
```
Expected: same successful pattern as Task 24.

- [ ] **Step 2: Verify cluster healthy**

Same verification as Task 24 Step 3.

---

### Task 26: Stage 3 — Manual full run (phase1 + phase2)

- [ ] **Step 1: Schedule window (not Saturday 04:30 — manual control)**

Pick a quiet window where you can watch logs for ~90min. Do NOT run during active work hours on the cluster.

- [ ] **Step 2: Trigger phase1 manually**

```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane "sudo systemctl start node-maintenance-phase1.service"
```
(This blocks — systemd runs phase1 + reboots CP. SSH session may drop when reboot happens.)

- [ ] **Step 3: From Mac, watch Telegram for notifications**

Expected sequence:
1. "🔧 Node maintenance phase 1 starting on gmk-k3s-control-plane..."
2. (CP reboots — ~3min)
3. Phase 2 auto-fires on CP boot.
4. Per-worker activity in kubectl/journal — no Telegram message per worker.
5. "✅ Node maintenance complete" — summary with alerts/log path.

- [ ] **Step 4: Post-run verification**

```bash
# Reconnect to CP after reboot:
ssh -p 65300 akhozya@gmk-k3s-control-plane "kubectl get nodes; flux get kustomizations -A; kubectl get pods -A | grep -v Running"
ssh -p 65300 akhozya@gmk-k3s-control-plane "ls /var/log/node-maintenance/; cat /var/log/node-maintenance/phase2-$(date -u +%d-%m-%Y).log | tail -50"
```
Expected: all nodes Ready, all Flux Ready, no non-Running pods. Phase2 log ends clean.

- [ ] **Step 5: Verify metric**

```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane "cat /var/lib/node_exporter/textfile/node_maintenance.prom"
```
Expected: `node_maintenance_last_run_unixtime <recent timestamp>`.

---

### Task 27: Stage 4 — Re-enable timer for scheduled runs

- [ ] **Step 1: Re-enable timer**

```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane "sudo systemctl start node-maintenance.timer"
```

- [ ] **Step 2: Verify next scheduled run**

```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane "systemctl list-timers node-maintenance.timer --no-pager"
```
Expected: next Saturday 04:30 UTC.

- [ ] **Step 3: Add monthly-review checklist items to HOMELAB_ANALYSIS.md**

Already captured in spec §15. No code change needed unless user wants an explicit checklist — see Task 28 follow-up.

---

### Task 28: Stage 5 — Monitor first scheduled run

- [ ] **Step 1: Watch Telegram Saturday 04:30 UTC**

Expected sequence same as Task 26 Step 3.

- [ ] **Step 2: Post-run Monday morning: spot-check**

```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane "systemctl status node-maintenance.timer node-maintenance-phase2.service --no-pager"
```
Expected: timer next-run = following Saturday; phase2.service `inactive (dead)` with last exit `success`.

- [ ] **Step 3: Review log for any warnings**

```bash
ssh -p 65300 akhozya@gmk-k3s-control-plane "grep -iE 'warning|failed|error' /var/log/node-maintenance/phase2-*.log | head -30"
```
Expected: no critical findings (some "FAILED: <kustomization>" lines OK if transient Flux reconcile error).

---

## Self-Review (after plan written)

### Spec coverage

| Spec section | Task(s) |
|--------------|---------|
| §2 Decisions (all 17) | Distributed across file contents (Tasks 3-14) |
| §3 Architecture | Tasks 6, 7 (playbooks) + 9, 10 (systemd) |
| §4 File layout | Task 1 (dirs) + all file-creation tasks |
| §5 User + permissions | Task 13 (install-worker.sh), Task 14 (install.sh) |
| §6 Inventory | Task 3 |
| §7 phase1.yml | Task 6 |
| §8 phase2.yml | Task 7 |
| §9 Shared telegram | Task 5 |
| §10 systemd units | Tasks 8-11 |
| §11 install scripts | Tasks 13, 14 |
| §12 Observability | Task 7 (metrics emission), Task 19 (README runbook). F2/F3/F4 deferred. |
| §13 Risk register | Mitigations embedded in playbook retries (Task 7) + override (Task 11) |
| §14 Rollout | Tasks 22-28 |
| §15 Runbook | Task 19 |
| §16 Open items | F1-F6 tracked in HOMELAB_ANALYSIS.md (pre-existing + Task 20) |
| §17 Limitations | Covered implicitly; no code requirement |

All spec sections mapped. ✓

### Placeholder scan

- `__REPLACE_WITH_ACTUAL_PUBKEY__` in install-worker.sh — **intentional**, replaced by install.sh sed at Task 14 runtime.
- No `TBD`, `TODO`, `implement later`, `similar to Task N`, or abstract "add error handling" steps.

### Type consistency

- `yay_cmd` defined once in group_vars (Task 4), referenced in phase1 (Task 6) and phase2 (Task 7) — same string.
- `flag_file` defined once in group_vars, referenced consistently as `/var/lib/node-maintenance/phase2-pending` in systemd units (Tasks 9, 10) and playbooks.
- `silence_id_file` consistent across phase1 write + phase2 read.
- systemd log path expansion uses `%%d-%%m-%%Y` consistently in both phase1 + phase2 service units.
- `k3s_service` per-host var (inventory Task 3) matches usage in phase2 reboot test_command (Task 7).

No inconsistencies. ✓

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-18-node-maintenance.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Best for the 16 file-creation + lint tasks (Phase A-F).

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints. Useful if you want me to pause between phases for review.

**Rollout tasks (22-28) must run against live cluster** — recommend doing those interactively with you rather than unattended.

**Which approach?**
