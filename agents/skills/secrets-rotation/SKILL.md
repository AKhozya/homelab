---
name: secrets-rotation
description: >-
  Use to rotate homelab database passwords (MySQL/Percona, PostgreSQL/CNPG, Redis ACL users, CouchDB admin), the Authentik secret key and OIDC client secrets — after a leak/compromise, on the SECRETS_ROTATION.md schedule (the 180-day batch), or when the user says "rotate the <app> db password". Covers SOPS + live change + GitOps deploy + pod cycle + proof the app logged in. Cycle app pods with `_shared/restart-workload.sh`, NEVER `kubectl rollout restart` (Flux reverts the restartedAt annotation to the old secret).
---

# Secrets Rotation (DB users)

Rotate DB user passwords end to end. This file holds the order of steps and the known failure
modes; the helpers in `~/.agents/skills/_shared/` do the work:

| Helper | Does |
|---|---|
| `rotate-db-user.sh` | MySQL: writes one SOPS key and/or runs the live `ALTER USER` |
| `rotate-pg-roles.sh` | CNPG: finds every SOPS copy of a role's password by value, replaces them all |
| `sops-changed-keys.sh` | names the stringData keys a change touched; stands in for review of ciphertext |
| `secret-readers.sh` | lists the workloads that mount a Secret |
| `pooler-login-proof.sh` | per user, the IPs that logged in or failed through PgBouncer since a time |
| `rotate-redis-users.sh` | Redis ACL users: the SOPS side of the three overlap passes, plus `status` |
| `redis-restart.sh` | Redis replica→master or the 3 sentinels, one at a time, only once Flux applied a given SHA |
| `redis-acl-drop-old.sh` | Redis pass 3 at runtime: removes old password hashes from the running pods |

## When

- **Compromise / leak** — a plaintext password reached Git (even if since redacted, it's live in history → rotate, don't just scrub). See `pii-scrub`.
- **Scheduled** — per `docs/SECRETS_ROTATION.md`. DB user = app name.

## Authority (operator, 2026-10-02)

For a scheduled or requested rotation, the agent runs the whole loop itself, merge included:
worktree → SOPS edit → commit → `_shared/merge-worktree.sh` → `fr`
→ live step → pod cycle → proof. Do not stop to hand the merge to the operator. Stop and ask only
if an app fails to log in after its pod cycle, or a step below fails.

Work one engine per merge (MySQL, then PostgreSQL, then the rest), so one failure has one cause.
Finish an engine before the Saturday 04:30 UTC upgrade+reboot window: a pod restarted between the
deploy and the live change logs in with the wrong password.

## Cycling app pods (read first)

After the new password is deployed, land it on the running app by **deleting** its
pods one at a time, not restarting them:

```bash
~/.agents/skills/_shared/restart-workload.sh <ns> <app-selector>   # ✅ Flux-safe; one pod at a time
# kubectl delete pod -n <ns> -l <app-selector>   # ❌ deletes every replica at once
# kubectl rollout restart deploy/<app>           # ❌ writes restartedAt (not in Git);
                                                 #    Flux prunes it, reverts to OLD secret
```

2026-06-12: a rollout-restart left uptime-kuma 4h on a dead password.

`restart-workload.sh` gives up after 90s; linkwarden and paperless-ngx can take 2-5 min. A 90s
FAILED there is not an auth failure: run `kubectl wait pod -n <ns> -l <sel>
--for=condition=Ready --timeout=300s`, then read the logs.

## MySQL (Percona): deploy first, ALTER second

Deploy the new Secret before the `ALTER`, so each app keeps working on the old password until its own pod cycle. Commands, and Home Assistant (password only inside a DSN, twice): `reference-mysql.md`.

## PostgreSQL (CNPG): every copy at once

Each password lives in the role's CNPG `passwordSecret` file and in one or more app files, as a
bare key or inside a DSN (linkwarden `DATABASE_URL`, blocky `config.yml`). CNPG sets the role
password when Flux syncs its file — there is no `ALTER`, and the app fails auth from that sync
until its pods are cycled. So cycle immediately after `fr`.

```bash
R=~/.agents/skills/_shared/rotate-pg-roles.sh
"$R" --list mealie linkwarden paperless immich n8n   # copies found by VALUE; expect >= 2 each
"$R" mealie linkwarden paperless immich n8n          # one new password per role, every copy
~/.agents/skills/_shared/sops-changed-keys.sh        # only the password keys changed, rest identical
"$R" --list mealie linkwarden paperless immich n8n   # same copies again = they all agree
# commit, merge-worktree.sh, fr: source, infrastructure-configs, apps
# then cycle every app at once (parallel restart-workload.sh, one per app)
~/.agents/skills/_shared/pooler-login-proof.sh <fr time, RFC3339> mealie linkwarden paperless immich n8n
```

Authentik is a CNPG role too: rotate it with its Django key as one step, before the OIDC batch
(the key ends every Authentik session). OIDC client secrets: `reference-oidc.md`.

## Readers and proof

Before rotating, list every copy by value and every workload that reads each Secret. After the pod cycle, prove each app logged in from the database side: `kubectl get secret` is denied. Commands and the per-engine proof table: `reference-readers-and-proof.md`.

## Gotchas

- **Hex passwords** (`openssl rand -hex 32`) — no quoting hazards in SQL literals or
  DSNs. The scripts use this; keep it.
- **Never put a password on a command line or in output.** Values go in on stdin; checks compare
  hashes or counts.
- **A heredoc that contains `kubectl get secret` is refused** by the safety hook even as text.
  Write such notes with the Write/Edit tool.
- **Redis and CouchDB**: three-pass overlap for Redis (`rotate-redis-users.sh`,
  `redis-restart.sh`, `redis-acl-drop-old.sh`); CouchDB admin = three copies + one pod delete at a
  time. Procedure and what the 2026-10-02 run showed (both Redis pods master for ~50s after a
  restart, sentinels stuck on a dead IP): `reference-redis-couchdb.md`.
- **Never** force-delete or `kubectl edit` DB pods. Redis and CouchDB pods are deleted normally,
  one at a time, as above; MySQL and PostgreSQL pods are never touched — only their *app* pods
  cycle. A DB user change is an `ALTER` or a CNPG sync, never a drop/recreate.
- After the batch, update the rows in `docs/SECRETS_ROTATION.md` (last rotated, next = +180 days).

## See also

- `db-operations` skill — `mysql-exec.sh` / `pg-primary.sh`.
- `pii-scrub` — find the leak that triggered the rotation.
- `gitops-workflow` — the worktree -> merge -> push -> reconcile loop.
