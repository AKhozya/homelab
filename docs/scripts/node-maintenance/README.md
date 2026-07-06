# Node Maintenance

Weekly Arch Linux updates across 3 K3s nodes.

**Schedule**: Saturday 04:30 UTC (systemd timer on CP)
**Flow**: CP phase1 (update + reboot) → CP phase2 on boot (worker rolling update + cleanup)
**Notifications**: Telegram (reuses `backup-replication/backup-telegram` bot)

## Node Config Drift-Heal (ansible)

Declarative config via `ansible/node-config.yml`. Roles (apply order, 13): `packages` (pacman-native base + per-host ucode + per-host GPU stack + worker-only `rebuilderd`/`archlinux-repro`), `base_config` (logrotate, journald caps, sudoers, node-maintenance user, rebuilderd-worker override, fstrim/paccache timers), `k3s_config` (`/etc/rancher/k3s/config.yaml` templated per group/host; drift-alert only, no auto-restart), `k3s_image_gc` (weekly `crictl rmi --prune`), `firewall_preflight` (settle barrier + sanity checks before firewall changes; runs again before the workers-only tail), `firewall` (UFW rules: policies + base/group/host rules + route rules; idempotent-additive, never resets), `hardening` (sshd drop-in incl. `PermitEmptyPasswords no`, sysctls, kubelet.yaml, systemd watchdog + timeouts, k3s service.d drop-ins, resolved LLMNR, NVMe/SATA udev+modprobe, CPU/NVMe tmpfiles), `nic_tuning` (igc NIC forced 1Gbps + EEE off via `igc-tune@.service` — CP I225-V link-drop fix), `security_scan` (monthly lynis+rkhunter timer + script), `ad_hoc` (on-demand tag-gated: firmware), `clusterip_heal` (workers: ClusterIP-DNAT wedge watchdog — probe fails ⇒ restart `k3s-agent`; journal tag `clusterip-heal`), `rebuilderd` (workers: resources.conf drop-in, metrics + watchdog + boot-timer + repro-cleanup units/scripts), `clusterip_heal_cp` (CP: nsenter-into-pod-netns CoreDNS probe — pod-netns wedge ⇒ `timeout 120` k3s restart; journal tag `clusterip-heal-cp`). Runs from CP, targets 3 nodes (rebuilderd + clusterip_heal workers-only; clusterip_heal_cp CP-only).

**Schedule**: daily 03:00 UTC (`node-maintenance-config.timer`)
**Also runs**: after `node-maintenance-sync.service` pulls new `main` HEAD (post-pull drift apply)
**Log**: `/var/log/node-maintenance/config-latest.log` (truncated each run; archived via logrotate)
**Telegram**: fires if `changed>0` or run fails (alert includes counts; silent when idempotent)

Manual trigger:
```bash
sudo systemctl start node-maintenance-config.service
# Check last run
journalctl -u node-maintenance-config.service -n 80 --no-pager
# Dry-run (no changes):
sudo ansible-playbook --check -D -i /etc/node-maintenance/ansible/inventory.yml \
  /etc/node-maintenance/ansible/node-config.yml
```

Tag-scoped run (debug):
```bash
sudo ansible-playbook --tags logrotate -D \
  -i /etc/node-maintenance/ansible/inventory.yml \
  /etc/node-maintenance/ansible/node-config.yml
```

**Edit workflow**: modify file in `ansible/roles/<role>/files/` or template → `git push` → CP sync timer pulls → `install.sh --sync-only` runs → `node-maintenance-config.service` re-applies → Telegram alert on `changed>0`.

### Rolling restart of k3s (apply config.yaml / kubelet.yaml drift)

`config.yaml` and `kubelet.yaml` are drift-alert-only (no auto-restart). To apply pending kubelet/CM config changes across all 3 nodes serially, with per-node Ready + configz verification:

```bash
sudo systemctl start node-maintenance-rolling-restart.service
journalctl -u node-maintenance-rolling-restart.service -n 80 --no-pager
```

Order: CP first (CM grace-period applies), then workers serially. `serial: 1` = max 1 node disrupted at a time. Aborts before next node if `configz` doesn't reflect expected `nodeLeaseDurationSeconds` + `nodeStatusReportFrequency` (defends against historical k3s field-stripping bugs). Telegram alert on failure.

ETA ≈ 5-7 min total (3 × restart + Ready + verify + 30s pauses).

### Tag catalog (ad-hoc / on-demand)

All `ad_hoc` tasks tagged `never` — daily timer skips. Invoke with `-t <tag>`:

```bash
# List pending firmware updates (metadata refresh + get-updates, no apply)
sudo ansible-playbook -t firmware -i /etc/node-maintenance/ansible/inventory.yml \
  /etc/node-maintenance/ansible/node-config.yml --limit worker-node

# Apply firmware updates on a specific host (may reboot — run during maintenance window)
sudo ansible-playbook -t firmware -e ad_hoc_firmware_apply=true \
  -i /etc/node-maintenance/ansible/inventory.yml \
  /etc/node-maintenance/ansible/node-config.yml --limit worker-node
```

### Out-of-scope one-shots (not ansible)

- **`docs/scripts/setup-claude-telegram.sh`** — Mac-side bootstrap for Claude Telegram bot on worker-node. Installs chezmoi/Node/Claude CLI as user `akhozya`, interactive GH token read. Run once per deploy; not drift-heal.
- **`docs/scripts/update-firmware.sh`** — superseded by ad_hoc `firmware` tag. Kept for interactive Mac-less fallback.

---

## Monthly Security Scan

Parallel pipeline, runs **each node locally** (no orchestration).

**Schedule**: 1st of month 04:00 UTC, ±1h jitter (RandomizedDelaySec=3600)
**Unit**: `node-maintenance-security-scan.timer` → `node-maintenance-security-scan.service`
**Script**: `/usr/local/sbin/node-maintenance-security-scan.sh` (canonical: `ansible/roles/security_scan/files/security-scan.sh`)
**Tools**: `lynis audit system --quick` + `rkhunter --check --sk --rwo --nocolors`
**Summary log**: `/var/log/node-maintenance/security-scan-YYYY-MM.log` (12mo retention, root:adm 0640)
**Full logs**: `/var/log/lynis.log` + `/var/log/lynis-report.dat` + `/var/log/rkhunter.log` (6mo retention)
**No Telegram alerts** — reviewed during monthly HOMELAB_ANALYSIS.md cadence.

Manual trigger (off-schedule):
```bash
sudo systemctl start node-maintenance-security-scan.service
# Watch progress
journalctl -fu node-maintenance-security-scan.service
# Read latest summary
sudo cat /var/log/node-maintenance/security-scan-$(date -u +%Y-%m).log
```

When `security-scan.sh` changes: CP auto-syncs (sync timer), ansible `security_scan` role deploys to 3 nodes on next `node-maintenance-config.service` run (daily, or `sudo systemctl start node-maintenance-config.service`).

---

## Install (one-time)

1. On CP:
   ```bash
   sudo bash /path/to/repo/docs/scripts/node-maintenance/install.sh
   ```
2. Follow printed instructions — scp + run `install-worker-ready.sh` on each worker.
3. Verify:
   ```bash
   sudo -u node-maintenance ssh -p 65300 -i /var/lib/node-maintenance/.ssh/id_ed25519 \
     -o UserKnownHostsFile=/etc/node-maintenance/known_hosts \
     node-maintenance@192.168.1.129 true
   ```

## Sync changes (after editing playbooks / systemd units)

### Automatic (every 10 min)

`node-maintenance-sync.timer` on CP runs every 10 min:
- `git fetch` + `reset --hard origin/main` in `/var/lib/node-maintenance/homelab`
- HEAD changed → `install.sh --sync-only` (systemd daemon-reload + file perms)
- Telegram on failure (`ExecStopPost`)

Check: `systemctl list-timers node-maintenance-sync.timer` · `journalctl -u node-maintenance-sync.service`

### Manual (urgent)

```bash
bash docs/scripts/node-maintenance/sync-node-maintenance.sh   # triggers same unit now
```

Overrides via env: `NODE_MAINT_CP_HOST`, `NODE_MAINT_CP_USER`, `NODE_MAINT_CP_PORT`.

### Deploy key (one-time setup — enables auto-sync)

Auto-sync uses dedicated read-only GitHub deploy key at `/root/.ssh/homelab-deploy`. Setup:

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

Rotation tracked in `docs/SECRETS_ROTATION.md` as `homelab-deploy`.

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

## Resilience — retry policy

Tasks sensitive to transient external failures (pacman mirrors, LVFS firmware metadata, ip6tables kernel races with kube-router/fail2ban, UFW `ufw status verbose` returning "ERROR: problem running ip6tables") carry `until/retries/delay` so drift-heal survives flakes without manual re-runs.

| Task class | Retries | Delay | Why |
|------------|---------|-------|-----|
| `ansible.builtin.package` (pacman) | 3 | 30s | Mirror 5xx/DNS, `/var/lib/pacman/db.lck`, GPG timeout |
| `community.general.ufw` | 5 | 10s | Transient ip6tables races with kube-router + fail2ban |
| `fwupdmgr update` (firmware apply) | 3 | 20s | LVFS server 5xx during fetch/verify |
| `systemd-resolved` restart handler | 2 | 5s | DNS churn during CP reboots |

**Not retried** (fail-loud):
- `sshd -t` config validate — must catch real config errors.
- Preflight checks (`/readyz`, Flux kustomization Ready, backup active).
- Local `copy`/`file`/`lineinfile` — atomic writes, failure = real bug.

### Drift-heal timeouts (systemd `TimeoutStartSec`)

| Unit | Limit | Rationale |
|------|-------|-----------|
| `node-maintenance-sync.service` | 20min | Wraps config playbook (max 15min) + git sync + install.sh |
| `node-maintenance-config.service` | 15min | Playbook ceiling incl. worst-case retries across all roles |
| `node-maintenance-phase1.service` | 30min | CP yay+reboot staging |
| `node-maintenance-phase2.service` | 90min | 3 workers serial yay+reboot + stabilize pauses |

### UFW boot-time healer (`ufw-heal-post-k3s.service`)

Every boot, `/usr/local/sbin/ufw-heal-post-k3s.sh` runs once:

1. **Phase A** — poll for kube-router quiescence (`KUBE-ROUTER-INPUT` chain exists + ip6tables-save line count stable across 2 samples 5s apart), 120s cap, continue on timeout.
2. **Phase B** — `ufw reload` ×3 with 10s gap.
3. **Phase C** — per-chain repair: parse `:<chain>` declarations from UFW rules files, `ip6tables -N` any missing (race-free, atomic per syscall).
4. **Phase D** — verify probe set: `ufw-logging-deny`, `ufw6-logging-deny`, `ufw-user-input`, `ufw6-user-input` all exist.
5. **Phase E** — final `ufw reload` once.
6. **Phase F** — `ufw status verbose` returns `Status: active` (or inactive if `ENABLED=no`, also accepted). Exits non-zero only on real failure.

Logs: `journalctl -t ufw-heal` (per-phase markers).

Replaces prior `ufw-reload-after-k3s.service` (bare `sleep 15 + ufw reload`, too fragile — ran before kube-router done mutating kernel state).

### UFW health metrics (`ufw-state-metric.service.timer`)

Emits 3 gauges every 60s via node-exporter textfile collector (`/var/lib/node_exporter/textfile/ufw_state.prom`):

- `ufw_enabled{node}` — config `ENABLED=yes` (1) or `no` (0)
- `ufw_service_active{node}` — `systemctl is-active ufw.service`
- `ufw_chains_healthy{node}` — canary probe set present in kernel

Alerts (`firewall-alerts` group, VMRule `homelab-alerts`):

- `UfwDisabled` (critical, 5m) — config flipped off
- `UfwServiceInactive` (critical, 5m) — systemd unit stopped
- `UfwChainsUnhealthy` (critical, 5m) — partial ip6tables load; heal catch within 10min via drift-heal pre-heal

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

## Install / SSH key rotation (Mac-driven — no age key on CP)

All SOPS decryption on Mac. Plain key transits to CP via SSH pipe, lives in `/tmp` only long enough for `install.sh` to copy+shred.

Tracked in `docs/SECRETS_ROTATION.md` under `node-maintenance-ssh`.

### Initial install

```bash
# On Mac: decrypt SSH key → stream to CP
sops --decrypt --extract '["stringData"]["ssh-private-key"]' \
  docs/scripts/node-maintenance/secrets/ssh-key.sops.yaml \
  | ssh -p 65300 akhozya@gmk-k3s-control-plane \
      'cat > /tmp/node-maintenance-ssh-key && chmod 600 /tmp/node-maintenance-ssh-key'

# Copy install folder to CP (if not already)
scp -P 65300 -r docs/scripts/node-maintenance akhozya@gmk-k3s-control-plane:

# On CP: run install
ssh -p 65300 akhozya@gmk-k3s-control-plane
sudo bash ~/node-maintenance/install.sh
# Follow printed instructions to scp + run install-worker.sh on both workers
```

`install.sh` shreds `/tmp/node-maintenance-ssh-key` after copying to `/var/lib/node-maintenance/.ssh/id_ed25519`.

### Rotation (annual)

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
sops --encrypt /tmp/new-secret.yaml > docs/scripts/node-maintenance/secrets/ssh-key.sops.yaml
git add docs/scripts/node-maintenance/secrets/ssh-key.sops.yaml
git commit -m "Rotate node-maintenance-ssh (YYYY-MM-DD)"
git push

# 4. Capture pub key for worker-side
cat /tmp/new_key.pub
# Copy to each worker's authorized_keys (as node-maintenance user or root):
ssh -p 65300 akhozya@worker-node "echo '<PASTE_PUB_KEY>' | sudo tee -a /var/lib/node-maintenance/.ssh/authorized_keys"
ssh -p 65300 z3us@worker-node-2 "echo '<PASTE_PUB_KEY>' | sudo tee -a /var/lib/node-maintenance/.ssh/authorized_keys"

# 5. Stream new private to CP + re-run install.sh
cat /tmp/new_key | ssh -p 65300 akhozya@gmk-k3s-control-plane \
  'cat > /tmp/node-maintenance-ssh-key && chmod 600 /tmp/node-maintenance-ssh-key'
ssh -p 65300 akhozya@gmk-k3s-control-plane "sudo bash ~/node-maintenance/install.sh"

# 6. Verify CP → workers as node-maintenance
ssh -p 65300 akhozya@gmk-k3s-control-plane "sudo -u node-maintenance ssh -p 65300 -i /var/lib/node-maintenance/.ssh/id_ed25519 -o UserKnownHostsFile=/etc/node-maintenance/known_hosts node-maintenance@192.168.1.129 true"

# 7. Remove OLD pub from workers' authorized_keys (manual edit)

# 8. Shred temp files on Mac
gshred -u /tmp/new_key /tmp/new_key.pub /tmp/new-secret.yaml

# 9. Update docs/SECRETS_ROTATION.md with new rotation date
```