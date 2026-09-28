---
name: secrets-rotation
description: >-
  Use to rotate a database user's password (MySQL/Percona, PostgreSQL/CNPG) in the homelab — after a leak/compromise, on the SECRETS_ROTATION.md schedule, or when the user says "rotate the <app> db password". Covers SOPS secret + live ALTER + GitOps deploy + pod cycle — cycle app pods one at a time with `_shared/restart-workload.sh`, NEVER `kubectl rollout restart` (Flux reverts the restartedAt annotation to the old secret).
---

# Secrets Rotation (DB users)

Rotate a DB user's password end to end. The mechanical mutations are in
`~/.agents/skills/_shared/rotate-db-user.sh`; this skill is the ordering + the traps.

## When

- **Compromise / leak** — a plaintext password reached Git (even if since redacted, it's live in history → rotate, don't just scrub). See `pii-scrub`.
- **Scheduled** — per `docs/SECRETS_ROTATION.md`.
- DB user = app name by convention.

## Cycling app pods (read first)

After the new password is deployed, land it on the running app by **deleting** its
pods one at a time, not restarting them:

```bash
~/.agents/skills/_shared/restart-workload.sh <ns> <app-selector>   # ✅ Flux-safe; one pod at a time
# kubectl delete pod -n <ns> -l <app-selector>   # ❌ deletes every replica at once
# kubectl rollout restart deploy/<app>           # ❌ writes restartedAt (not in Git);
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
#   postgres: NOT this script — see "PostgreSQL (CNPG): two files" below

# 2. GitOps deploy (do it in a worktree per CLAUDE.md):
#    commit the SOPS change -> merge to main -> push
flux reconcile source git flux-system && flux reconcile kustomization apps

# 3. cycle pods (DELETE one at a time — see Cycling app pods)
~/.agents/skills/_shared/restart-workload.sh uptime-kuma app=uptime-kuma

# 4. verify
kubectl get pods -n uptime-kuma            # new pod 1/1 Running
# DB-auth quiet, no MySQLHighAbortedConnections
```

## PostgreSQL (CNPG): two files

Every CNPG user is in `managed.roles` of `infrastructure/configs/databases/postgres/cluster.yaml`,
so each password lives in two SOPS files that must carry the same value:

| File | Read by |
|---|---|
| the role's `passwordSecret` in `infrastructure/configs/databases/postgres/` — usually `<app>-db-user.yaml`; linkwarden uses `linkwarden-app-user-secret.yaml` (`password`) | CNPG, which sets the role's password from it — no live `ALTER` |
| the app's own secret under `apps/<app>/` (key name varies) | the app |

`rotate-db-user.sh` writes one file and runs an `ALTER`, so it does not fit this case. Follow
`docs/SECRETS_ROTATION.md` § 1. PostgreSQL Password (CNPG): set one new password in both files,
commit them together, then cycle the app pods as in step 3.

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
