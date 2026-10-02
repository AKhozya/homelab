# Node Maintenance

This folder keeps the four K3s nodes configured and updated. Ansible does the work. Timers on the
control plane (CP) drive the update, the drift-heal and the sync; each node runs its own security
scan timer:

| Job | When (UTC) | What it does |
|---|---|---|
| Weekly update | Saturday 04:30 (`node-maintenance.timer`) | Phase 1 updates and reboots the CP. On boot, phase 2 updates the two physical workers one at a time, then `immich-vm` without an in-guest reboot, then cleans up. |
| Drift-heal | daily 03:00 and 15:00 (`node-maintenance-config.timer`), and after every sync that pulls a new `main` | Puts each node back to the state `ansible/node-config.yml` declares |
| Sync | every 10 minutes (`node-maintenance-sync.timer`) | Pulls `main` onto the CP and installs changed playbooks and units |
| Security scan | the 1st of each month, 04:00 plus up to an hour's random delay | lynis and rkhunter on each node |

Telegram messages reuse the `backup-replication/backup-telegram` bot.

## Drift-heal (Ansible)

`ansible/node-config.yml` declares each node's configuration. It runs from the CP against all four
nodes and applies these 14 roles in order:

| Role | Nodes | What it manages |
|---|---|---|
| `packages` | all | pacman base packages, per-host CPU microcode, per-host GPU stack |
| `base_config` | all | logrotate, journald limits, sudoers, the `node-maintenance` user, fstrim and paccache timers, and the shared shell library (below) |
| `k3s_config` | all | `/etc/rancher/k3s/config.yaml`, templated per group and host. It only alerts on drift; it never restarts K3s. |
| `k3s_image_gc` | all | a weekly `crictl rmi --prune` |
| `firewall_preflight` | all | settles the packet filter and runs sanity checks before any firewall change; it runs again before the workers-only roles |
| `firewall` | all | UFW policies, base, group and host rules, and route rules. It only adds rules and never resets; see [SECURITY.md](../docs/SECURITY.md#node-firewall) |
| `hardening` | all | the sshd drop-in, sysctls, `kubelet.yaml`, the systemd watchdog and timeouts, K3s service drop-ins, resolved (LLMNR off), NVMe and SATA udev and modprobe rules, CPU and NVMe tmpfiles |
| `nic_tuning` | the three physical nodes (each host's `nic_tuning_iface`; `immich-vm` has none) | turns EEE (Energy-Efficient Ethernet) off through `nic-tune@.service`, and on the CP also forces the Intel I226-V NIC to 1 Gbps; it removes the old `igc-tune@` unit |
| `security_scan` | all | the monthly scan timer and script |
| `ad_hoc` | on demand | tasks run only by tag, such as firmware (see below) |
| `clusterip_heal` | workers | a watchdog: if a probe through a ClusterIP fails (a stuck DNAT rule after a reboot), it restarts `k3s-agent`. Journal tag `clusterip-heal`. |
| `clusterip_heal_cp` | CP | a watchdog that probes CoreDNS from inside a pod's network namespace; if the probe fails, it restarts K3s with `timeout 120`. Journal tag `clusterip-heal-cp`. |
| `node_isolation_heal` | the two physical workers | if a worker loses the CP, it first restarts `k3s-agent`, then reboots itself on a staggered timer. Active since 2026-07-23. |
| `immich_gpu_node` | `immich-vm` | the GPU node's heal script, watchdog units, sysctl and kernel-command-line guards, and the local-path bind mount |

| Setting | Value |
|---|---|
| Log | `/var/log/node-maintenance/config-latest.log`. The unit rewrites it each run; its `ExecStopPost` copies each run to `config-archive/` and keeps the 50 newest. |
| Telegram | a message if the run changed anything or failed; silent when nothing changed |

Run it by hand:

```bash
sudo systemctl start node-maintenance-config.service
# Check last run
journalctl -u node-maintenance-config.service -n 80 --no-pager
# Dry-run (no changes):
sudo ansible-playbook --check -D -i /etc/node-maintenance/ansible/inventory.yml \
  /etc/node-maintenance/ansible/node-config.yml
```

Run only some tags, for debugging:

```bash
sudo ansible-playbook --tags logrotate -D \
  -i /etc/node-maintenance/ansible/inventory.yml \
  /etc/node-maintenance/ansible/node-config.yml
```

**To change a node:** edit the role's file or template under `ansible/roles/<role>/`, then push. The
CP's sync timer pulls the change, runs `install.sh --sync-only`, then runs
`node-maintenance-config.service`, which applies it. Telegram reports what changed.

### Shared shell library

`base_config` installs `roles/base_config/files/node-script-lib.sh` as
`/usr/local/lib/node-maintenance/node-script-lib.sh`. It runs before every role that installs a
script that sources it.

| Function | Used by | What it does |
|---|---|---|
| `textfile_write PATH` | the 4 heal watchdogs, `firewall-preflight.sh` | writes a node-exporter metric atomically, mode 0644; returns 1 on failure, and the callers ignore that |
| `state_write PATH FIELD...` | the 4 heal watchdogs | writes a one-line state file atomically, mode 0600; always returns 0 |
| `ufw_chains_hash` | `firewall-preflight.sh`, `k3s-wait-ready.sh`, `ufw-heal-post-k3s.sh` | hashes the ufw chains only, the settle signal |

If the library is missing or lacks a function a script needs, that script logs `cannot load …`
and exits 1. Where that shows:

| Script | What reports it |
|---|---|
| the 4 heal watchdogs | the failed unit (`NodeSystemdUnitFailed`) and the stale metric file (`NodeHealWatchdogStale`) |
| `k3s-wait-ready.sh` | the failed unit; `ufw-heal-post-k3s.service` then skips at boot, as `/run/k3s-ready` is missing |
| `ufw-heal-post-k3s.sh` | the failed unit, at boot or from `ufw-heal-watchdog.timer` |
| `firewall-preflight.sh` | the Ansible task fails the host, so the run's failure notice fires and the host skips its later plays |

| Test | Runs where | Command |
|---|---|---|
| library unit tests | CI (`node-script-tests`) and the workstation | `bash node-maintenance/lib/tests/test-node-script-lib.sh` |
| whole-script harness: every changed script in stubbed scenarios, compared byte for byte with fixtures recorded from the pre-library scripts | the workstation (Docker, privileged) | `node-maintenance/lib/tests/heal-harness/run-all.sh check` |

### Rolling restart of K3s

Drift-heal does not restart K3s to apply a change to `config.yaml` or `kubelet.yaml`, so such a
change waits until you apply it. This unit restarts K3s on all four nodes, one at a time, and checks each node is Ready and
reports the expected config:

```bash
sudo systemctl start node-maintenance-rolling-restart.service
journalctl -u node-maintenance-rolling-restart.service -n 80 --no-pager
```

The CP goes first, then each worker. `serial: 1` means at most one node is down at a time. Before it
moves to the next node, the run checks through `configz` that the node reports the expected
`nodeLeaseDurationSeconds` and `nodeStatusReportFrequency`, and stops if it does not; this guards
against K3s bugs that dropped those fields in the past. Telegram reports a failure. It takes about
5 to 7 minutes.

### On-demand tasks

Every `ad_hoc` task carries the `never` tag, so the scheduled runs skip it. Run one with `-t <tag>`:

```bash
# List pending firmware updates (metadata refresh + get-updates, no apply)
sudo ansible-playbook -t firmware -i /etc/node-maintenance/ansible/inventory.yml \
  /etc/node-maintenance/ansible/node-config.yml --limit worker-node

# Apply firmware updates on a specific host (may reboot — run during maintenance window)
sudo ansible-playbook -t firmware -e ad_hoc_firmware_apply=true \
  -i /etc/node-maintenance/ansible/inventory.yml \
  /etc/node-maintenance/ansible/node-config.yml --limit worker-node
```

### One-off scripts outside Ansible

| Script | Use |
|---|---|
| `scripts/update-firmware.sh` | The `firmware` tag above replaces it. It stays as an interactive fallback when no Mac is available. |

---

## Monthly security scan

Each node runs the scan on its own; nothing coordinates them.

| Item | Value |
|---|---|
| Schedule | the 1st of each month, 04:00 UTC, plus up to an hour's random delay (`RandomizedDelaySec=3600`) |
| Units | `node-maintenance-security-scan.timer` starts `node-maintenance-security-scan.service` |
| Script | `/usr/local/sbin/node-maintenance-security-scan.sh`; its source is `ansible/roles/security_scan/files/security-scan.sh` |
| Tools | `lynis audit system --quick`, `rkhunter --check --sk --rwo --nocolors` |
| Summary log | `/var/log/node-maintenance/security-scan-YYYY-MM.log`, kept 12 months, `root:adm` 0640 |
| Full logs | `/var/log/lynis.log`, `/var/log/lynis-report.dat`, `/var/log/rkhunter.log`, kept 6 months |
| Alerts | Telegram if the scan fails to run (the unit's `ExecStopPost`). The monthly review reads the findings. |

The timer keeps `Persistent=false`: if a node is down at the scheduled time, it skips that month's
scan. The comment in the timer file says why: the stamp files still date from July 2026, so
`Persistent=true` would start a catch-up scan on the next restart of the timer.

Run it by hand:

```bash
sudo systemctl start node-maintenance-security-scan.service
# Watch progress
journalctl -fu node-maintenance-security-scan.service
# Read latest summary
sudo cat /var/log/node-maintenance/security-scan-$(date -u +%Y-%m).log
```

If you change `security-scan.sh`, the CP syncs it, and the `security_scan` role deploys it to all
four nodes on the next drift-heal run.

---

## Install (once)

1. On the CP:
   ```bash
   sudo bash /path/to/repo/node-maintenance/install.sh
   ```
2. `install.sh` writes `/tmp/install-worker-ready.sh` (`install-worker.sh` with the CP's public key
   filled in) and prints the commands that copy and run it on worker-node and worker-node-2. Run
   the same on `immich-vm`: the inventory reaches it as the `node-maintenance` user too, and the
   printed commands predate it.
3. Check:
   ```bash
   sudo -u node-maintenance ssh -p 65300 -i /var/lib/node-maintenance/.ssh/id_ed25519 \
     -o UserKnownHostsFile=/etc/node-maintenance/known_hosts \
     node-maintenance@192.168.1.129 true
   ```

## Syncing changes

### Automatic, every 10 minutes

`node-maintenance-sync.timer` on the CP runs every 10 minutes:

| Step | Action |
|---|---|
| 1 | `git fetch` and `reset --hard origin/main` in `/var/lib/node-maintenance/homelab` |
| 2 | If HEAD changed, `install.sh --sync-only` (systemd daemon-reload and file permissions), then drift-heal |
| 3 | Telegram on failure (`ExecStopPost`) |

Check it with `systemctl list-timers node-maintenance-sync.timer` and
`journalctl -u node-maintenance-sync.service`.

### By hand, if it is urgent

```bash
bash node-maintenance/sync-node-maintenance.sh   # triggers same unit now
```

Override the target with `NODE_MAINT_CP_HOST`, `NODE_MAINT_CP_USER` and `NODE_MAINT_CP_PORT`.

### Deploy key (once; enables the automatic sync)

The sync uses its own read-only GitHub deploy key at `/root/.ssh/homelab-deploy`:

```bash
# 1. Generate key on CP
ssh -p 65300 -t akhozya@gmk-k3s-control-plane \
  "sudo ssh-keygen -t ed25519 -f /root/.ssh/homelab-deploy -N '' -C 'homelab-deploy@gmk-k3s-control-plane' \
   && sudo cat /root/.ssh/homelab-deploy.pub"

# 2. GitHub repo Settings → Deploy keys → Add deploy key
#    - Title: "gmk-k3s-control-plane sync"
#    - Paste pubkey
#    - Leave "Allow write access" UNCHECKED (read-only)

# 3. Enable timer
ssh -p 65300 -t akhozya@gmk-k3s-control-plane \
  "sudo systemctl enable --now node-maintenance-sync.timer && sudo systemctl start node-maintenance-sync.service"
```

`docs/SECRETS_ROTATION.md` tracks its rotation as `homelab-deploy`.

## Day to day

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

## Retries

Tasks that can fail for a moment on an outside service carry `until`, `retries` and `delay`, so a
brief failure does not need a manual re-run. Examples: pacman mirrors, LVFS firmware metadata, or
`ip6tables` races with kube-router or fail2ban, where `ufw status verbose` returns "ERROR: problem
running ip6tables".

| Task | Retries | Delay | Why |
|------------|---------|-------|-----|
| `ansible.builtin.package` (pacman) | 3 | 30s | mirror 5xx or DNS errors, `/var/lib/pacman/db.lck`, GPG timeout |
| `community.general.ufw` | 5 | 10s | brief `ip6tables` races with kube-router and fail2ban |
| `fwupdmgr update` (firmware apply) | 3 | 20s | LVFS server 5xx during fetch or verify |
| `systemd-resolved` restart handler | 2 | 5s | DNS churn during CP reboots |

These are **not** retried, so they fail at once:

| Task | Why |
|---|---|
| `sshd -t` config check | it must catch real config errors |
| Preflight checks (`/readyz`, Flux Kustomization Ready, backup active) | a failure means stop |
| Local `copy`, `file` and `lineinfile` | the writes are atomic, so a failure is a real bug |

### Time limits (systemd `TimeoutStartSec`)

| Unit | Limit | Why |
|------|-------|-----------|
| `node-maintenance-sync.service` | 20min | wraps the config playbook (at most 15 min), the git sync and `install.sh` |
| `node-maintenance-config.service` | 15min | the playbook's time limit, with worst-case retries across all roles |
| `node-maintenance-phase1.service` | 30min | the CP's update and reboot |
| `node-maintenance-phase2.service` | 90min | the two physical workers, one at a time, each updated and rebooted with pauses to settle, then `immich-vm` |

### UFW repair at boot (`ufw-heal-post-k3s.service`)

On every boot, `/usr/local/sbin/ufw-heal-post-k3s.sh` runs once:

| Phase | Action |
|---|---|
| A | Wait until kube-router stops changing the rules: the `KUBE-ROUTER-INPUT` chain exists and the `ip6tables-save` line count is the same in two samples 5 s apart. Give up waiting after 120 s and go on. |
| B | `ufw reload` three times, 10 s apart |
| C | Repair each chain: read the `:<chain>` lines from the UFW rules files and `ip6tables -N` any that are missing |
| D | Check that `ufw-logging-deny`, `ufw6-logging-deny`, `ufw-user-input` and `ufw6-user-input` exist |
| E | One final `ufw reload` |
| F | Check that `ufw status verbose` says `Status: active` (or inactive if `ENABLED=no`); exit non-zero only on a real failure |

Logs: `journalctl -t ufw-heal`, with a marker per phase. It replaced `ufw-reload-after-k3s.service`,
which only slept 15 s and reloaded, and so often ran before kube-router had finished.

### UFW health metrics (`ufw-state-metric.timer`)

Every 60 s it writes three gauges for the node-exporter textfile collector
(`/var/lib/node_exporter/textfile/ufw_state.prom`):

| Gauge | Meaning |
|---|---|
| `ufw_enabled{node}` | the config says `ENABLED=yes` (1) or `no` (0) |
| `ufw_service_active{node}` | `systemctl is-active ufw.service` |
| `ufw_chains_healthy{node}` | the probe chains exist in the kernel |

Alerts, in the `firewall-alerts` group of the `homelab-alerts` VMRule:

| Alert | Fires when |
|---|---|
| `UfwDisabled` (critical, 5m) | the config is switched off |
| `UfwServiceInactive` (critical, 5m) | the systemd unit has stopped |
| `UfwChainsUnhealthy` (critical, 5m) | the `ip6tables` rules loaded only in part. `ufw-heal-watchdog.timer` runs the repair script every 5 minutes, so it clears within about 10 minutes; drift-heal also repairs it before its firewall step. |

## Recovery

### Phase 2 failed and left its flag

```bash
journalctl -u node-maintenance-phase2.service -n 500
# Fix root cause (cordoned node, failed flux kustomization, etc.)
kubectl uncordon <node>
flux reconcile kustomization <name>
# When cluster healthy:
sudo rm /var/lib/node-maintenance/phase2-pending
```

### A node stuck cordoned and unreachable

```bash
# Physical/IPMI console recovery, then:
kubectl uncordon <node>
sudo rm /var/lib/node-maintenance/phase2-pending
```

### Roll back a package

```bash
ssh -p 65300 <worker> 'sudo pacman -U /var/cache/pacman/pkg/<pkg>-<prev-version>.pkg.tar.zst'
```

## Install and SSH key rotation (from the Mac; the CP has no age key)

SOPS decrypts only on the Mac. The plain key reaches the CP through an SSH pipe and stays in
`/tmp` only until `install.sh` copies and shreds it. `docs/SECRETS_ROTATION.md` tracks it as
`node-maintenance-ssh`.

### First install

```bash
# On Mac: decrypt SSH key → stream to CP
sops --decrypt --extract '["stringData"]["ssh-private-key"]' \
  node-maintenance/secrets/ssh-key.sops.yaml \
  | ssh -p 65300 akhozya@gmk-k3s-control-plane \
      'cat > /tmp/node-maintenance-ssh-key && chmod 600 /tmp/node-maintenance-ssh-key'

# Copy install folder to CP (if not already)
scp -P 65300 -r node-maintenance akhozya@gmk-k3s-control-plane:

# On CP: run install
ssh -p 65300 akhozya@gmk-k3s-control-plane
sudo bash ~/node-maintenance/install.sh
# Follow printed instructions to scp + run install-worker.sh on both workers
```

`install.sh` shreds `/tmp/node-maintenance-ssh-key` after it copies it to
`/var/lib/node-maintenance/.ssh/id_ed25519`.

### Rotation (yearly)

```bash
# 1. On Mac: generate fresh keypair
ssh-keygen -t ed25519 -f /tmp/new_key -N "" -C "node-maintenance@gmk-k3s-control-plane"

# 2. Wrap as SOPS Secret YAML (same as spec §15):
cat > /tmp/new-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
    name: node-maintenance-ssh
    namespace: node-maintenance-not-deployed
type: Opaque
stringData:
    ssh-private-key: |
$(sed 's/^/        /' /tmp/new_key)
EOF

# 3. Encrypt + commit new key version
sops --encrypt /tmp/new-secret.yaml > node-maintenance/secrets/ssh-key.sops.yaml
git add node-maintenance/secrets/ssh-key.sops.yaml
git commit -m "Rotate node-maintenance-ssh (YYYY-MM-DD)"
git push

# 4. Add the new pub key next to the old one on all three workers
cat /tmp/new_key.pub
ssh -p 65300 akhozya@worker-node "echo '<PASTE_PUB_KEY>' | sudo tee -a /var/lib/node-maintenance/.ssh/authorized_keys"
ssh -p 65300 z3us@worker-node-2 "echo '<PASTE_PUB_KEY>' | sudo tee -a /var/lib/node-maintenance/.ssh/authorized_keys"
ssh -p 65300 akhozya@immich-vm "echo '<PASTE_PUB_KEY>' | sudo tee -a /var/lib/node-maintenance/.ssh/authorized_keys"

# 5. Stream new private to CP + re-run install.sh
# The staged key must replace the installed key before step 6 can test it.
cat /tmp/new_key | ssh -p 65300 akhozya@gmk-k3s-control-plane \
  'cat > /tmp/node-maintenance-ssh-key && chmod 600 /tmp/node-maintenance-ssh-key'
ssh -p 65300 akhozya@gmk-k3s-control-plane "sudo bash ~/node-maintenance/install.sh"

# 6. Verify CP → every worker with the NEW key.
#    If any line fails, stop and leave the old pub key in place. The CP now holds only the
#    new private key, so fix that worker's authorized_keys over your own SSH account
#    (as in step 4), then re-run this step.
for ip in 192.168.1.129 192.168.1.126 192.168.1.231; do
  ssh -p 65300 akhozya@gmk-k3s-control-plane "sudo -u node-maintenance ssh -p 65300 -i /var/lib/node-maintenance/.ssh/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=/etc/node-maintenance/known_hosts node-maintenance@$ip true" && echo "$ip ok"
done

# 7. If all three print ok, remove the OLD pub key from each worker's
#    /var/lib/node-maintenance/.ssh/authorized_keys (manual edit)

# 8. Shred temp files on Mac
gshred -u /tmp/new_key /tmp/new_key.pub /tmp/new-secret.yaml

# 9. Update docs/SECRETS_ROTATION.md with new rotation date
```

