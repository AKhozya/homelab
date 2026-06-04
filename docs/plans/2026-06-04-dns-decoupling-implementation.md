# Node DNS Decoupling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make all 3 nodes resolve external DNS via public resolvers (1.1.1.1 / 9.9.9.9) instead of blocky's worker-IP servicelb endpoints, breaking the node→blocky→kube-proxy circular dependency so a cluster networking blip can no longer take out node + CoreDNS upstream DNS.

**Architecture:** Node-side change via the ansible `hardening` role (no GitOps/Flux). Two drop-ins per node: (1) a systemd-networkd drop-in on the primary NIC's `.network` setting `UseDNS=no` (DHCPv4 + IPv6AcceptRA) so the router-supplied blocky DNS is dropped from the link; (2) a systemd-resolved global drop-in `DNS=1.1.1.1 9.9.9.9` + `Domains=~.` so resolved forwards everything to public DNS. Applied via `networkctl reload` + `systemctl restart systemd-resolved` — neither flaps the link (no SSH lockout). resolved stays in **uplink mode** (real IPs in `/etc/resolv.conf`, never the 127.0.0.53 stub, or k3s would generate its own resolv.conf). CoreDNS (`dnsPolicy: Default`, `forward . /etc/resolv.conf`) is restarted afterward to re-read the node resolv.conf. Router DHCP DNS option is untouched → LAN client blocky adblock preserved.

**Tech Stack:** Arch Linux, systemd-networkd, systemd-resolved, ansible (node-maintenance roles), K3s, kubectl.

**Design doc:** `docs/plans/2026-06-04-dns-decoupling-design.md` (approved Option A).

**Rollout order:** W2 → W1 → CP (coredns-ha placement: W1×1, CP×2, W2×0 → W2 lowest blast radius; CP last). Per-node, manual, timers masked to prevent the 10-min auto-heal racing the staged apply.

**Apply constraint:** Claude has no sudo. Claude does: edits, local validation (yamllint/ansible-lint/syntax-check), commit, merge, push, and read-only SSH verification. The **user** runs every `sudo` step (masking timers, the staged `ansible-playbook`, `kubectl rollout restart`, unmasking).

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `docs/scripts/node-maintenance/ansible/roles/hardening/files/resolved-upstream-dns.conf` | resolved global upstream = public DNS | Create |
| `docs/scripts/node-maintenance/ansible/roles/hardening/files/networkd-no-dhcp-dns.conf` | drop link DHCP/RA-supplied DNS | Create |
| `docs/scripts/node-maintenance/ansible/roles/hardening/tasks/main.yml` | deploy both drop-ins, tagged `networkd-dns` | Modify |
| `docs/scripts/node-maintenance/ansible/roles/hardening/handlers/main.yml` | add `Reload networkd` handler | Modify |
| `docs/scripts/node-maintenance/ansible/host_vars/worker-node.yml` | `primary_network_file: 20-ethernet.network` | Modify |
| `docs/scripts/node-maintenance/ansible/host_vars/worker-node-2.yml` | `primary_network_file: 20-wired-static.network` | Modify |
| `docs/scripts/node-maintenance/ansible/group_vars/control_plane.yml` | `primary_network_file: 10-enp3s0.network` | Modify |
| `docs/HOMELAB_ANALYSIS.md`, `docs/HOMELAB_HISTORY.md` | record change | Modify (Task 12) |

---

## Task 1: Per-host primary-NIC variable

**Files:**
- Modify: `docs/scripts/node-maintenance/ansible/host_vars/worker-node.yml`
- Modify: `docs/scripts/node-maintenance/ansible/host_vars/worker-node-2.yml`
- Modify: `docs/scripts/node-maintenance/ansible/group_vars/control_plane.yml`

- [ ] **Step 1: Add var to worker-node host_vars**

Append to `host_vars/worker-node.yml`:

```yaml

# Primary NIC .network filename — target for the DNS-decoupling drop-in
# (docs/plans/2026-06-04-dns-decoupling-implementation.md). DHCP link → blocky
# DNS dropped via UseDNS=no; resolved global drop-in supplies public DNS.
primary_network_file: 20-ethernet.network
```

- [ ] **Step 2: Add var to worker-node-2 host_vars**

Append to `host_vars/worker-node-2.yml`:

```yaml

# Primary NIC .network filename — target for the DNS-decoupling drop-in.
# Static link; its existing `DNS=192.168.1.129` is reset to public DNS via
# the resolved global drop-in + networkd UseDNS reset.
primary_network_file: 20-wired-static.network
```

- [ ] **Step 3: Add var to control_plane group_vars**

Append to `group_vars/control_plane.yml`:

```yaml

# Primary NIC .network filename — target for the DNS-decoupling drop-in
# (CP is a single-host group). DHCP link.
primary_network_file: 10-enp3s0.network
```

- [ ] **Step 4: yamllint the three files**

Run: `yamllint docs/scripts/node-maintenance/ansible/host_vars/worker-node.yml docs/scripts/node-maintenance/ansible/host_vars/worker-node-2.yml docs/scripts/node-maintenance/ansible/group_vars/control_plane.yml`
Expected: no errors (exit 0).

- [ ] **Step 5: Commit**

```bash
git add docs/scripts/node-maintenance/ansible/host_vars/worker-node.yml docs/scripts/node-maintenance/ansible/host_vars/worker-node-2.yml docs/scripts/node-maintenance/ansible/group_vars/control_plane.yml
git commit -m "node-maintenance: add primary_network_file var for DNS-decoupling drop-in"
```

---

## Task 2: resolved global upstream drop-in + task

**Files:**
- Create: `docs/scripts/node-maintenance/ansible/roles/hardening/files/resolved-upstream-dns.conf`
- Modify: `docs/scripts/node-maintenance/ansible/roles/hardening/tasks/main.yml` (after the existing `Deploy resolved LLMNR disable drop-in` task, ~line 137)

- [ ] **Step 1: Create the resolved drop-in file**

`roles/hardening/files/resolved-upstream-dns.conf`:

```ini
# Managed by ansible (hardening role) — DNS decoupling, 2026-06-04.
# Cluster-INDEPENDENT upstream: nodes + CoreDNS must NOT depend on blocky
# (cluster pods on the worker IPs) for external DNS. Breaks the node→blocky→
# kube-proxy circular dependency. LAN clients keep blocky via router DHCP.
# Domains=~. routes ALL lookups to these servers (used because the link has
# no DNS after UseDNS=no). Plain 53 (DoT optional, omitted for node simplicity).
[Resolve]
DNS=1.1.1.1 9.9.9.9
Domains=~.
```

- [ ] **Step 2: Add the deploy task**

In `roles/hardening/tasks/main.yml`, immediately after the `Deploy resolved LLMNR disable drop-in` task, insert:

```yaml
- name: Deploy resolved upstream-DNS drop-in (cluster-independent public DNS)
  ansible.builtin.copy:
    src: resolved-upstream-dns.conf
    dest: /etc/systemd/resolved.conf.d/upstream-dns.conf
    owner: root
    group: root
    mode: "0644"
  notify: Restart systemd-resolved
  tags: [hardening, resolved, networkd-dns]
```

- [ ] **Step 3: yamllint the task file**

Run: `yamllint docs/scripts/node-maintenance/ansible/roles/hardening/tasks/main.yml`
Expected: no errors (exit 0).

- [ ] **Step 4: Commit**

```bash
git add docs/scripts/node-maintenance/ansible/roles/hardening/files/resolved-upstream-dns.conf docs/scripts/node-maintenance/ansible/roles/hardening/tasks/main.yml
git commit -m "hardening: resolved global upstream-DNS drop-in (public resolvers)"
```

---

## Task 3: networkd no-DHCP-DNS drop-in + tasks + handler

**Files:**
- Create: `docs/scripts/node-maintenance/ansible/roles/hardening/files/networkd-no-dhcp-dns.conf`
- Modify: `docs/scripts/node-maintenance/ansible/roles/hardening/tasks/main.yml` (after Task 2's task)
- Modify: `docs/scripts/node-maintenance/ansible/roles/hardening/handlers/main.yml`

- [ ] **Step 1: Create the networkd drop-in file**

`roles/hardening/files/networkd-no-dhcp-dns.conf`:

```ini
# Managed by ansible (hardening role) — DNS decoupling, 2026-06-04.
# Drops the router-supplied DNS (DHCPv4 + IPv6 RA = blocky worker IPs + fe80::1)
# from this link so resolved falls through to the global DNS drop-in
# (resolved-upstream-dns.conf = 1.1.1.1 / 9.9.9.9). `DNS=` (empty) resets any
# static DNS in the main .network (W2's 20-wired-static.network has DNS=.129).
[Network]
DNS=

[DHCPv4]
UseDNS=no

[IPv6AcceptRA]
UseDNS=no
```

- [ ] **Step 2: Add the dir + copy tasks**

In `roles/hardening/tasks/main.yml`, immediately after the Task-2 deploy task, insert:

```yaml
- name: Ensure primary-NIC networkd drop-in dir exists
  ansible.builtin.file:
    path: "/etc/systemd/network/{{ primary_network_file }}.d"
    state: directory
    owner: root
    group: root
    mode: "0755"
  tags: [hardening, networkd-dns]

- name: Deploy networkd no-DHCP-DNS drop-in (drop blocky DNS from link)
  ansible.builtin.copy:
    src: networkd-no-dhcp-dns.conf
    dest: "/etc/systemd/network/{{ primary_network_file }}.d/10-no-dhcp-dns.conf"
    owner: root
    group: root
    mode: "0644"
  notify: Reload networkd
  tags: [hardening, networkd-dns]
```

- [ ] **Step 3: Add the handler**

In `roles/hardening/handlers/main.yml`, add **above** the `Restart systemd-resolved` handler (so networkd drops link DNS before resolved re-reads):

```yaml
- name: Reload networkd
  ansible.builtin.shell: |
    networkctl reload
    resolvectl flush-caches
  changed_when: false
```

- [ ] **Step 4: yamllint task + handler files**

Run: `yamllint docs/scripts/node-maintenance/ansible/roles/hardening/tasks/main.yml docs/scripts/node-maintenance/ansible/roles/hardening/handlers/main.yml`
Expected: no errors (exit 0).

- [ ] **Step 5: Commit**

```bash
git add docs/scripts/node-maintenance/ansible/roles/hardening/files/networkd-no-dhcp-dns.conf docs/scripts/node-maintenance/ansible/roles/hardening/tasks/main.yml docs/scripts/node-maintenance/ansible/roles/hardening/handlers/main.yml
git commit -m "hardening: networkd UseDNS=no drop-in + Reload networkd handler"
```

---

## Task 4: Local validation (offline)

**Files:** none (validation only).

- [ ] **Step 1: ansible-lint the role**

Run: `cd docs/scripts/node-maintenance/ansible && ansible-lint roles/hardening node-config.yml ; cd -`
Expected: no errors. (Pre-existing warnings unrelated to the new tasks are acceptable — confirm no new `fqcn`/`syntax`/`var-naming` errors on the added lines.)

- [ ] **Step 2: Playbook syntax check**

Run: `cd docs/scripts/node-maintenance/ansible && ansible-playbook --syntax-check -i inventory.yml node-config.yml ; cd -`
Expected: `playbook: node-config.yml` printed, exit 0 (offline — does not connect).

- [ ] **Step 3: Confirm the rendered drop-in dest paths per host (sanity)**

Run: `rg -n 'primary_network_file' docs/scripts/node-maintenance/ansible/host_vars/ docs/scripts/node-maintenance/ansible/group_vars/control_plane.yml`
Expected: `20-ethernet.network` (worker-node), `20-wired-static.network` (worker-node-2), `10-enp3s0.network` (control_plane). These must match the live `.network` filenames captured 2026-06-04.

---

## Task 5: Merge to main + push (drift-heal pulls from origin/main)

**Files:** none (git).

- [ ] **Step 1: Merge worktree branch to main**

```bash
cd /Users/akhozya/source-code/homelab
git checkout main && git pull --ff-only
git merge --no-ff wt-dns-decouple -m "Break node->blocky circular DNS dependency: nodes->public DNS via ansible hardening role"
```

- [ ] **Step 2: Push**

```bash
git push origin main
```
Expected: push succeeds; CI `.github/workflows/validate.yaml` runs (yamllint/shellcheck/sops-check — ansible files are linted by yamllint). Do NOT proceed to apply until CI is green.

---

## Task 6: Staged-apply prep — mask timers, sync CP checkout (USER sudo on CP)

**Files:** none (node ops). All commands run by the **user** on the control plane (`ssh_master_node`).

- [ ] **Step 1: Mask the auto-heal timers (prevents all-host race)**

```bash
sudo systemctl stop node-maintenance.timer node-maintenance-sync.timer node-maintenance-config.timer
sudo systemctl mask node-maintenance-sync.service node-maintenance-config.service
```
Expected: timers stopped; services masked. (Masking the services blocks any in-flight timer trigger too.)

- [ ] **Step 2: Update the CP git checkout + installed copy WITHOUT auto-heal**

```bash
sudo git -C /var/lib/node-maintenance/homelab fetch --depth=50 origin main
sudo git -C /var/lib/node-maintenance/homelab reset --hard origin/main
sudo bash /var/lib/node-maintenance/homelab/docs/scripts/node-maintenance/install.sh --sync-only
```
Expected: HEAD at the merge commit; `install.sh --sync-only` copies the updated ansible tree to `/etc/node-maintenance/ansible/` (file copy only — does NOT run the playbook).

- [ ] **Step 3: Verify the new files landed in the installed copy**

```bash
ls -l /etc/node-maintenance/ansible/roles/hardening/files/resolved-upstream-dns.conf /etc/node-maintenance/ansible/roles/hardening/files/networkd-no-dhcp-dns.conf
grep primary_network_file /etc/node-maintenance/ansible/host_vars/*.yml /etc/node-maintenance/ansible/group_vars/control_plane.yml
```
Expected: both files present; three `primary_network_file` lines.

---

## Task 7: Apply on worker-node-2 (W2 first — 0 coredns replicas) (USER sudo on CP)

**Files:** none.

- [ ] **Step 1: Dry-run (check + diff) limited to W2, DNS tag only**

```bash
cd /etc/node-maintenance/ansible
sudo ansible-playbook -D --check -i inventory.yml node-config.yml --limit worker-node-2 --tags networkd-dns
```
Expected: diff shows the two drop-ins to be created on W2; no errors.

- [ ] **Step 2: Apply for real on W2**

```bash
sudo ansible-playbook -D -i inventory.yml node-config.yml --limit worker-node-2 --tags networkd-dns
```
Expected: `changed` for the two copy tasks + handlers (`Reload networkd`, `Restart systemd-resolved`) fire; play recap `failed=0`.

- [ ] **Step 3: Verify W2 resolves via public DNS, SSH alive (Claude read-only)**

```bash
ssh_worker_node2 'echo "--- resolv.conf ---"; cat /etc/resolv.conf | grep -E "^nameserver"; echo "--- resolvectl global ---"; resolvectl status | sed -n "1,8p"; echo "--- dig ---"; dig +short github.com @1.1.1.1 >/dev/null && getent hosts github.com'
```
Expected: `nameserver 1.1.1.1` + `nameserver 9.9.9.9` ONLY (no `192.168.1.129`/`.126`); `getent hosts github.com` returns an IP. SSH responded ⇒ no lockout.

- [ ] **Step 4: Verify cluster still healthy after W2 (Claude, local kubectl)**

```bash
kubectl get nodes -o wide --no-headers | awk '{print $1,$2}'
kubectl get pods -A --field-selector status.phase!=Running,status.phase!=Succeeded --no-headers | head
```
Expected: all nodes `Ready`; no new non-Running pods attributable to DNS. STOP and rollback (Task 11 inverse) if W2 lost resolution or pods on W2 fail DNS.

---

## Task 8: Apply on worker-node (W1 — 1 coredns replica) (USER sudo on CP)

**Files:** none.

- [ ] **Step 1: Apply on W1**

```bash
cd /etc/node-maintenance/ansible
sudo ansible-playbook -D -i inventory.yml node-config.yml --limit worker-node --tags networkd-dns
```
Expected: `changed`; `failed=0`.

- [ ] **Step 2: Verify W1 (Claude read-only)**

```bash
ssh_worker_node 'cat /etc/resolv.conf | grep -E "^nameserver"; getent hosts github.com'
```
Expected: `nameserver 1.1.1.1` + `9.9.9.9` only; `github.com` resolves.

- [ ] **Step 3: Cluster health re-check (Claude)**

```bash
kubectl get nodes --no-headers | awk '{print $1,$2}'
kubectl -n kube-system get pods -l app=coredns-ha -o wide --no-headers | awk '{print $1,$3,$7}'
```
Expected: nodes `Ready`; coredns-ha pods `Running` (the W1 replica still serving — it forwards to old upstream until Task 10 restart, which is fine since blocky is still up).

---

## Task 9: Apply on control plane (CP last — 2 coredns replicas) (USER sudo on CP)

**Files:** none.

- [ ] **Step 1: Apply on CP**

```bash
cd /etc/node-maintenance/ansible
sudo ansible-playbook -D -i inventory.yml node-config.yml --limit gmk-k3s-control-plane --tags networkd-dns
```
Expected: `changed`; `failed=0`. Handler restarts systemd-resolved on the CP — SSH (port 65300, IP-based) is unaffected by a resolver restart.

- [ ] **Step 2: Verify CP (Claude read-only)**

```bash
ssh_master_node 'cat /etc/resolv.conf | grep -E "^nameserver"; getent hosts github.com'
```
Expected: `nameserver 1.1.1.1` + `9.9.9.9` only; `github.com` resolves.

---

## Task 10: Restart CoreDNS + cluster verification (USER sudo for rollout) 

**Files:** none. CoreDNS pods cached the OLD node resolv.conf at creation — must restart to forward to public DNS.

- [ ] **Step 1: Rollout restart coredns-ha (ordered, single deploy)**

```bash
kubectl -n kube-system rollout restart deploy/coredns-ha
kubectl -n kube-system rollout status deploy/coredns-ha --timeout=120s
```
Expected: 3/3 new pods `Running`. (Acceptable to run via the `cluster-roll` skill instead for full ordered safety; a single-deploy restart is low-risk here.)

- [ ] **Step 2: Verify CoreDNS resolves internal + external (Claude)**

```bash
kubectl run dns-test --rm -it --restart=Never --image=ghcr.io/akhozya/... 2>/dev/null || true
# Preferred non-pod check: confirm via an existing pod with shell, or check flux:
kubectl -n flux-system get gitrepository -o wide
flux get sources git -A 2>/dev/null || kubectl -n flux-system get kustomizations --no-headers | head
```
Expected: flux GitRepository `Ready=True` with a recent fetch (external github.com resolved through CoreDNS→public DNS). Internal: any running pod resolving `*.svc.cluster.local` still works (NodeHosts + kubernetes plugin unaffected).

- [ ] **Step 3: Force a flux reconcile + confirm green (Claude)**

```bash
flux reconcile source git flux-system -n flux-system 2>/dev/null; flux get kustomizations -A --status-selector ready=false
```
Expected: no `ready=false` kustomizations (empty output) ⇒ external DNS path healthy end-to-end.

- [ ] **Step 4: Confirm no node lists a worker IP as nameserver (Claude)**

```bash
for n in ssh_master_node ssh_worker_node ssh_worker_node2; do $n 'hostname; grep -E "^nameserver" /etc/resolv.conf'; done
```
Expected: every node shows only `1.1.1.1` + `9.9.9.9`. Zero `192.168.1.129`/`.126`. **Circular dependency broken.**

---

## Task 11: Unmask timers (restore auto-heal) (USER sudo on CP)

**Files:** none.

- [ ] **Step 1: Unmask + restart timers**

```bash
sudo systemctl unmask node-maintenance-sync.service node-maintenance-config.service
sudo systemctl start node-maintenance.timer node-maintenance-sync.timer node-maintenance-config.timer
```
Expected: timers active. Next auto-heal is idempotent (`changed=0` — drop-ins already in place).

- [ ] **Step 2: Confirm one clean idempotent heal (optional, Claude read-only after next cycle)**

```bash
ssh_master_node 'tail -30 /var/log/node-maintenance/config-latest.log | grep -E "changed=|failed=|networkd|resolved"'
```
Expected: recap `changed=0 failed=0` for the DNS tasks ⇒ converged, no drift.

**Rollback (if any node breaks):** delete `/etc/systemd/resolved.conf.d/upstream-dns.conf` and `/etc/systemd/network/<file>.d/10-no-dhcp-dns.conf` on the node, then `sudo networkctl reload && sudo systemctl restart systemd-resolved` → DHCP DNS (blocky) returns. Revert the commits on main so drift-heal doesn't re-apply. `kubectl rollout restart deploy/coredns-ha` to restore pods.

---

## Task 12: Documentation + memory

**Files:**
- Modify: `docs/HOMELAB_ANALYSIS.md`
- Modify: `docs/HOMELAB_HISTORY.md`
- Memory: `~/.claude/projects/-Users-akhozya-source-code-homelab/memory/gotcha_k3s_reboot_ordering.md`

- [ ] **Step 1: HOMELAB_HISTORY.md — append changelog entry**

Append under the current date:

```markdown
## 2026-06-04 — Node DNS decoupled from blocky (circular-dep fix)
Nodes' upstream DNS moved from blocky worker IPs (.129/.126, DHCP-supplied) to
public resolvers (1.1.1.1/9.9.9.9) via ansible hardening role (networkd UseDNS=no
drop-in + resolved global DNS drop-in). CoreDNS (`forward . /etc/resolv.conf`,
`dnsPolicy: Default`) restarted to pick up the change. Breaks node→blocky→
kube-proxy circular dependency (2026-06-04 incident delta #3). LAN-client blocky
adblock unchanged (router DHCP DNS option untouched). Rollout W2→W1→CP.
See docs/plans/2026-06-04-dns-decoupling-{design,implementation}.md.
```

- [ ] **Step 2: HOMELAB_ANALYSIS.md — update the DNS/networking note**

Find the blocky/CoreDNS description and add: nodes now resolve external DNS via public resolvers (cluster-independent); blocky serves LAN clients only via router DHCP. Keep the why (circular-dep break).

- [ ] **Step 3: Update the memory gotcha**

In `gotcha_k3s_reboot_ordering.md`, under the "2026-06-04 incident" section delta #3, mark the circular dependency RESOLVED with the fix summary + commit SHA(s) + a pointer to the design/impl plans. Note resolved-stub-mode-vs-k3s gotcha (don't point resolv.conf at 127.0.0.53).

- [ ] **Step 4: Commit docs (in worktree or main per workflow)**

```bash
git add docs/HOMELAB_ANALYSIS.md docs/HOMELAB_HISTORY.md
git commit -m "docs: record node DNS decoupling from blocky (circular-dep fix)"
```

---

## Self-Review

**Spec coverage** (design doc → tasks):
- Change 1 (networkd drop-in) → Task 3 ✅ (refined: `UseDNS=no` + global resolved DNS instead of per-link static `DNS=`, for flap-free apply — same outcome).
- Change 2 (CoreDNS restart) → Task 10 ✅.
- Rollout W2→W1→CP → Tasks 7/8/9 ✅.
- Uplink-mode / no-127.0.0.53 → Architecture + Task 12 gotcha ✅.
- UFW outgoing=allow (no new rule) → relied on, documented in design ✅.
- Rollback → Task 11 ✅.
- Residual LAN SPOF / security note → carried in design doc (out of scope) ✅.

**Placeholder scan:** Task 10 Step 2 leaves the `kubectl run ... --image=ghcr.io/akhozya/...` line as a non-preferred fallback — the **preferred** check (flux GitRepository Ready) is concrete; delete the `kubectl run` line if no suitable image is handy. No other placeholders.

**Type/name consistency:** var `primary_network_file` used identically in Task 1 (definition) and Task 3 (consumption). Drop-in dest filenames (`upstream-dns.conf`, `10-no-dhcp-dns.conf`) consistent across create/verify/rollback. Handler name `Reload networkd` matches the `notify:` in Task 3. Tag `networkd-dns` consistent across all tasks and the apply commands.
