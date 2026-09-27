---
name: secrets-rotation
description: >-
  Use to rotate a database user's password (MySQL/Percona, PostgreSQL/CNPG) in the homelab — after a leak/compromise, on the SECRETS_ROTATION.md schedule, or when the user says "rotate the <app> db password". Covers SOPS secret + live ALTER + GitOps deploy + pod cycle — cycle app pods with `kubectl delete pod`, NEVER `kubectl rollout restart` (Flux reverts the restartedAt annotation to the old secret).
---

# Secrets Rotation (DB users)

Rotate a DB user's password end to end. The mechanical mutations are in
`~/.agents/skills/_shared/rotate-db-user.sh`; this skill is the ordering + the traps.

## When

- **Compromise / leak** — a plaintext password reached Git (even if since redacted, it's live in history → rotate, don't just scrub). See `pii-scrub`.
- **Scheduled** — per `docs/SECRETS_ROTATION.md`.
- DB user = app name by convention.

## The footgun (read first)

After the new password is deployed, land it on the running app by **deleting** its
pods, not restarting them:

```bash
kubectl delete pod -n <ns> -l <app-selector>      # ✅ Flux-safe; new pod mounts new secret
# kubectl rollout restart deploy/<app>            # ❌ writes restartedAt (not in Git);
                                                  #    Flux prunes it, reverts to OLD secret
```

2026-06-12: a rollout-restart left uptime-kuma 4h on a dead password, firing
`MySQLHighAbortedConnections`. `kubectl delete pod` fixed it in seconds.

## Flow

```bash
S=~/.agents/skills/_shared/rotate-db-user.sh

# 0. preview — mutates nothing
"$S" mysql apps/uptime-kuma/mysql-credentials.yaml password uptimekuma --dry-run --pod-selector app=uptime-kuma

# 1. rotate: writes SOPS secret + ALTERs the live DB
"$S" mysql apps/uptime-kuma/mysql-credentials.yaml password uptimekuma --pod-selector app=uptime-kuma
#   postgres: "$S" postgres apps/<app>/postgres-credentials.yaml password <app>

# 2. GitOps deploy (do it in a worktree per CLAUDE.md):
#    commit the SOPS change -> merge to main -> push
flux reconcile source git flux-system && flux reconcile kustomization apps

# 3. cycle pods (DELETE — see footgun)
kubectl delete pod -n uptime-kuma -l app=uptime-kuma

# 4. verify
kubectl get pods -n uptime-kuma            # new pod 1/1 Running
# DB-auth quiet, no MySQLHighAbortedConnections
```

## Ordering / downtime

The script writes the secret (undeployed in Git) AND ALTERs the live DB together,
so running pods (old pw) fail auth until step 2+3. Brief blip — acceptable for the
single-env homelab ("Simple mode"). For **zero-downtime**: run with `--no-alter`,
deploy the secret (steps 2), confirm new pods are up, then re-run with
`--alter-only` and immediately cycle pods.

## Gotchas

- **DSN-stored creds.** Some secrets hold a full DSN, not a bare password — e.g.
  home-assistant's `db_url: mysql://homeassistant:PW@…`. The script rotates a bare
  `stringData[<key>]`; for a DSN, edit the password substring inside the URL with
  `sops <file>` (manual) and run the matching `ALTER USER` yourself, or split the
  DSN into discrete user/password keys first.
- **Hex passwords** (`openssl rand -hex 32`) — no quoting hazards in SQL literals or
  DSNs. The script uses this; keep it.
- **Redis / CouchDB** are out of script scope — Redis ACLs are operator-managed
  (`redis-acl-secret`), CouchDB via the `couchdb-couchdb` secret. Rotate by hand.
- **Never** force-delete or `kubectl edit` the DB pods themselves — only the *app*
  pods get cycled. The DB user change is an `ALTER`, never a drop/recreate.

## See also

- `_shared/rotate-db-user.sh` — the engine.
- `db-operations` skill — `mysql-exec.sh` / `pg-primary.sh` (the helpers the script calls).
- `pii-scrub` — find the leak that triggered the rotation.
- `gitops-workflow` — the worktree -> merge -> push -> reconcile loop for step 2.
