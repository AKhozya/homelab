# MySQL (Percona) rotation

Each app holds its own copy; there is no operator-side copy. Deploy the secret before changing the
user, so the app keeps working on the old password until its own pod cycle:

```bash
S=~/.agents/skills/_shared/rotate-db-user.sh
# 1. write SOPS only, for each app (no live change)
"$S" mysql apps/uptime-kuma/mysql-credentials.yaml password uptimekuma --no-alter --pod-selector app=uptime-kuma
# 2. commit, merge-worktree.sh, fr (apps)
# 3. per app, one at a time: ALTER from the deployed value, then cycle
"$S" mysql apps/uptime-kuma/mysql-credentials.yaml password uptimekuma --alter-only
~/.agents/skills/_shared/restart-workload.sh uptime-kuma app=uptime-kuma
```

## Home Assistant: password only inside a DSN

`apps/home-assistant/secrets.yaml` holds the password only inside a DSN, twice:

| Key | Where the password sits |
|---|---|
| `secrets.yaml` | the `db_url: mysql://homeassistant:PW@…` line; HA mounts this key as `/config/secrets.yaml` |
| `db_url` | the whole DSN; nothing reads it, but keep it equal |

The same file also holds `oidc_client_secret`, which the OIDC rotation changes.

`rotate-db-user.sh` handles bare keys only, so rotate HA manually (done this way 2026-10-02):

1. Generate one password with `openssl rand -hex 32`.
2. For each key: `sops -d --extract` it to a file. Replace the DSN password with awk, reading the
   new value from the environment (`ENVIRON["NP"]`), not from its arguments. If the original
   value has no final newline, strip the one awk appends, so the bytes match.
   Then run `jq -Rs . < file | sops set --value-stdin <file> '["stringData"]["<key>"]'`.
3. Check: both keys carry the same password (compare hashes), and `secrets.yaml` is byte-identical
   to HEAD once the password is masked.
4. After the deploy: decrypt key `db_url`, cut the password out of it, require 64 hex, then pipe
   `ALTER USER 'homeassistant'@'%' IDENTIFIED BY '<pw>';` into
   `~/.agents/skills/db-operations/scripts/mysql-exec.sh homeassistant -`.
5. Cycle with `restart-workload.sh home-assistant app=home-assistant`. HA logs only warnings, so
   prove the login with the processlist query in `reference-readers-and-proof.md`.
