# Node Maintenance

Automated weekly Arch Linux updates across all 3 K3s nodes.

**Schedule:** Saturday 04:30 UTC (via systemd timer on control-plane)
**Flow:** CP phase1 (update + reboot) → CP phase2 on boot (worker rolling update + cleanup)
**Notifications:** Telegram (reuses `backup-replication/backup-telegram` bot)

## Monthly Security Scan

Parallel pipeline, runs on **each node locally** (no orchestration).

**Schedule:** 1st of month 04:00 UTC, ±1h jitter (RandomizedDelaySec=3600)
**Unit:** `node-maintenance-security-scan.timer` → `node-maintenance-security-scan.service`
**Script:** `/usr/local/sbin/node-maintenance-security-scan.sh` (canonical: `bin/security-scan.sh`)
**Tools:** `lynis audit system --quick` + `rkhunter --check --sk --rwo --nocolors`
**Summary log:** `/var/log/node-maintenance/security-scan-YYYY-MM.log` (12mo retention, root:adm 0640)
**Full logs:** `/var/log/lynis.log` + `/var/log/lynis-report.dat` + `/var/log/rkhunter.log` (6mo retention)
**No Telegram alerts** — reviewed during monthly HOMELAB_ANALYSIS.md cadence.

Manual trigger (off-schedule):
```bash
sudo systemctl start node-maintenance-security-scan.service
# Watch progress
journalctl -fu node-maintenance-security-scan.service
# Read latest summary
sudo cat /var/log/node-maintenance/security-scan-$(date -u +%Y-%m).log
```

When `security-scan.sh` changes: CP auto-syncs (sync timer). **Workers require manual re-run of `install-worker.sh`** (script body inlined to avoid worker→git dependency).

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

## Sync changes (after editing playbooks / systemd units)

### Automatic (every 10 min)

`node-maintenance-sync.timer` on CP runs every 10 min:
- `git fetch` + `reset --hard origin/main` in `/var/lib/node-maintenance/homelab`
- If HEAD changed → `install.sh --sync-only` (systemd daemon-reload + file perms)
- Telegram on failure (`ExecStopPost`)

Check: `systemctl list-timers node-maintenance-sync.timer` · `journalctl -u node-maintenance-sync.service`

### Manual (urgent)

```bash
bash docs/scripts/node-maintenance/sync-node-maintenance.sh   # triggers same unit now
```

Overrides via env: `NODE_MAINT_CP_HOST`, `NODE_MAINT_CP_USER`, `NODE_MAINT_CP_PORT`.

### Deploy key (one-time setup — enables auto-sync)

Auto-sync uses a dedicated read-only GitHub deploy key at `/root/.ssh/homelab-deploy`. Setup:

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

All SOPS decryption happens on Mac. Plain key transits to CP via SSH pipe, lives in `/tmp` only long enough for `install.sh` to copy+shred.

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

`install.sh` shreds `/tmp/node-maintenance-ssh-key` after copying it into `/var/lib/node-maintenance/.ssh/id_ed25519`.

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
