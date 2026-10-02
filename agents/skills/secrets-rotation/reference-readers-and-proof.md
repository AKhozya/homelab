# Before and after a rotation: readers and proof

## Readers: search by value, not by name

A table of "which file holds it" goes stale. Before rotating, list every SOPS copy of the current
value (`rotate-pg-roles.sh --list` does this for CNPG). Then list the workloads that mount each app
Secret, Jobs and CronJobs included — a Job that reads the secret fails silently on its next run:

```bash
~/.agents/skills/_shared/secret-readers.sh <ns> <secret-name>
```

Use the script: an inline `kubectl get … | jq` that mentions `secretKeyRef` is refused by the
deny list.

Jobs that already ran need nothing: Flux reruns a Job only when its spec changes.

## Proof the app logged in

`kubectl get secret` is on the deny list, so the live Secret value cannot be compared. Prove it
from the database side instead, after the pod cycle:

| Engine | Proof |
|---|---|
| MySQL | `mysql-exec.sh mysql "SELECT user, COUNT(*) FROM information_schema.processlist WHERE user IN (…) GROUP BY user"` — the old pods are gone, so every session is a new login |
| PostgreSQL direct | `pg-primary.sh exec postgres -c "SELECT usename, client_addr, backend_start FROM pg_stat_activity WHERE usename IN (…)"` — need a `backend_start` after the pod cycle from the new pod's IP |
| PostgreSQL via PgBouncer | `pg_stat_activity` shows the pooler pods' IPs, and those server connections can predate the rotation, so it proves nothing. Run `pooler-login-proof.sh <fr time, RFC3339> <user>...`: need logins from the NEW pod's IP and no auth failure from it. Failures from the old pod's IP between `fr` and its cycle are expected |

If you read pooler logs by hand, these constraints apply; the script handles each:

| Constraint | Effect if ignored |
|---|---|
| `kubectl logs -l` returns the last 10 lines per pod unless `--tail=-1` is given | a check reports "0 auth failures" over lines it never read (happened 2026-10-02) |
| user names can hold digits | a `[a-z_-]` pattern misses `n8n` |
| PgBouncer logs `login attempt` before authentication | an attempt count includes logins that then failed |

Plus: only Watchdog firing (`_shared/check-alerts.sh`). A secret diff is ciphertext, so a
reviewer cannot check it; `sops-changed-keys.sh` is the check that replaces review.

