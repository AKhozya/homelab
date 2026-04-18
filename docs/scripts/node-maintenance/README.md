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
2. Wrap in k8s Secret YAML (see spec §15 for exact template), then:
   `sops --encrypt /tmp/new_secret.yaml > docs/scripts/node-maintenance/secrets/ssh-key.sops.yaml`
3. Commit + push.
4. On each worker: append new pub to `/var/lib/node-maintenance/.ssh/authorized_keys`.
5. Run `install.sh` on CP (re-decrypts new key).
6. Verify: `sudo -u node-maintenance ssh ... node-maintenance@<worker> true`.
7. Remove old pub from workers' `authorized_keys`.
8. Update `docs/SECRETS_ROTATION.md` with new rotation date.
9. `shred -u /tmp/new_key /tmp/new_key.pub`.
