# Backup Strategy

This page is the backup policy: what is backed up, when, for how long, and how fast it comes back.
Every restore procedure is in the [DR runbook](disaster-recovery/README.md).

## Approach

Every database is backed up as a plain export (`pg_dump` for Postgres, the equivalent for each
other engine), not with point-in-time recovery. The databases are a few GB and change by megabytes
a day, so one export a night is enough. An export is easy to inspect and restores into any
compatible engine version, with no write-log replay.

There is deliberately **no** WAL archiving, barman or continuous Postgres backup. CloudNativePG's
streaming replica keeps Postgres available if one instance fails; it is not a backup, because it
copies a mistake as fast as it copies good data.

## Recovery targets

| Target | Value | Basis |
|---|---|---|
| RPO (most data you can lose) | up to 24 hours for the databases and app volumes; up to 7 days for the Immich library; everything since the last run of the secret backup script for the secrets | the daily backups run once a night, the Immich backup once a week, the secret backup by hand |
| RTO (time to restore) | about 30 minutes for a full rebuild, mostly the copy from the NAS and the per-engine restores | an estimate; no full rebuild has been timed. The CouchDB restore was drilled end to end on 2026-07-24. |

## Schedule

All times are UTC. Every backup job runs on `worker-node` and writes under
`/mnt/k8s-storage/backups/`, except the Immich library backup, which runs on `worker-node-2`.

| Backup | CronJob (namespace) | When | Output | Kept |
|---|---|---|---|---|
| PostgreSQL | `postgres-backup` (`databases`) | daily 03:00 | `pg_dump -F c` of each database, tarred and gzipped, with a SHA-256 file | 30 days |
| CouchDB | `couchdb-backup` (`databases`) | daily 03:05 | `@cloudant/couchbackup` export of each database, tarred and gzipped, with a SHA-256 file | 30 days |
| App volumes | `pvc-backup` (`kube-system`) | daily 03:10 | one tar per PVC, with a SHA-256 file | 30 days |
| MySQL | `mysql-backup` (`databases`) | daily 03:15 | `mysqldump` of each database, with a SHA-256 file | 30 days |
| Copy to the NAS | `backup-replication` (`backup-replication`) | daily 03:30 | the four backups above, copied to the NAS | 30 days on the NAS |
| Immich library | `immich-backup` (`backup-replication`) | Sunday 03:00 | an uncompressed tar of the library and a SHA-256 file, on worker-node-2 and on the NAS | the newest 2 of each |
| Secrets | `.backup/secrets-backup.sh`, by hand | monthly, and before a large change | a GPG-encrypted archive | as long as you keep it; store the passphrase in 1Password |

## What is backed up

| Data | Backed up |
|---|---|
| PostgreSQL | every app database: authentik, blocky, immich, linkwarden, mealie, n8n, paperless |
| MySQL | homeassistant, uptimekuma, pricebuddy |
| CouchDB | obsidian-personal |
| App volumes | the 14 PVCs in `CRITICAL_PVCS` (`infrastructure/configs/backup/pvc-backup-cronjob.yaml`): `audiobookshelf/audiobookshelf-{audiobooks,podcasts,config,metadata}`, `home-assistant/home-assistant-data-pvc`, `homehub/homehub-data-pvc`, `linkwarden/linkwarden-data`, `linkwarden/meilisearch-data`, `mealie/mealie-data-pvc`, `n8n/n8n-data-pvc`, `paperless-ngx/paperless-data-pvc`, `pricebuddy/pricebuddy-storage`, `rustdesk/rustdesk-data`, `stirling-pdf/stirling-pdf-configs-pvc` |
| Immich library | the whole library, about 61 GB, weekly. The library lives on the NAS, not in a PVC. |
| Secrets | the SOPS age key, the Cloudflare tokens, every database credential, every app secret, the OIDC secrets, the NAS and Telegram credentials |
| Everything else | Git: every manifest, ConfigMap, NetworkPolicy and RBAC rule, and the SOPS-encrypted secrets |

Kept elsewhere, not in the secret backup: the SSH keys and a local copy of the SOPS age key, both in
1Password.

### What is not backed up, on purpose

From the 2026-05-22 audit:

| Resource | Why |
|---|---|
| `redis-replication` PVCs (DB0 and DB1) | Cache and job queues only, with no lasting user data. DB0 holds BullMQ and Celery queues and Django sessions, which the apps recover from on restart; DB1 is cache with a timeout on every key. Redis keeps RDB snapshots and an AOF log, and runs two replicas and three Sentinels, which cover the loss of one pod. |
| `immich/immich-machine-learning` | A model cache that downloads again |
| `claude-telegram/claude-telegram-home-pvc` | Session state only; the bot rebuilds it on restart, and its secrets are in SOPS |
| `loki/storage-loki-0`, `monitoring/vmsingle-vmsingle` | Log and metric buffers |
| `stirling-pdf/stirling-pdf-pipeline-pvc`, `stirling-pdf-tessdata-pvc` | Runtime files and model data that download again |

## What matters most

| Tier | Data | Why |
|---|---|---|
| Critical | the SOPS age key | it decrypts every other secret |
| Critical | the Authentik database | every OIDC setup and every user |
| High | the app databases (Immich, Paperless and the rest) and user files (documents, configs) | the data people use |
| Medium | app state (Home Assistant, CouchDB) | rebuildable, but slow to rebuild |

## The copy to the NAS

`backup-replication` (`infrastructure/configs/backup-replication/cronjob.yaml`) runs these steps:

| Step | Does |
|---|---|
| 1 | Checks each type's newest backup: age, tar listing, a minimum size per engine, and the SHA-256 if a `.sha256` file exists. For PVCs it checks every archive, requires each one's `.sha256`, and requires 14 archives. If a type fails, the copy leaves it out and its source stays. If every type fails, the run stops before any copy. |
| 2 | Copies to the NAS with rsync, without `--delete`, so the NAS keeps history |
| 3 | Checks that each backup arrived on the NAS |
| 4 | Deletes the source copies on worker-node for the types that passed step 1 and that step 3 confirmed |
| 4b | Prunes the NAS: 30 days for the daily backups, the newest 2 for Immich. If the NAS refuses a delete, the other prunes still run. The copy to the NAS still counts. If any prune is refused, the run fails, and the report counts the refused prunes. The Job log names them; delete those by hand in the NAS web UI. |
| 5 | Reports NAS use against the 500 GB limit: a warning at 400 GB, critical at 450 GB |
| 6 | Sends a Telegram message, only on failure |

| NAS | Value |
|---|---|
| Address | 192.168.1.136, rsync daemon on port 50555 |
| Module and path | `akhozya-pool1`, `backups/homelab/` |
| Credentials | the SOPS Secret `nas-rsync-credentials` |
| Space | a 500 GB self-imposed limit for these backups; the pool size is in [HOMELAB_ANALYSIS.md](HOMELAB_ANALYSIS.md#storage) |
| Admin access | SSH on port 56634, key-based |

The NAS is off the node, but not off the site: worker-node, worker-node-2 and the NAS share one
building, power supply and LAN. There is no cloud copy; [ARCHITECTURE.md](ARCHITECTURE.md#deliberate-simplifications)
records that as an accepted risk.

## Watching the backups

| Alert | Fires when |
|---|---|
| `BackupJobFailed` | a backup Job fails |
| `BackupCronJobMissedSchedule` | a daily backup CronJob misses its scheduled run |
| `BackupJobRunningTooLong` | a backup Job runs too long |
| `NoRecentBackups` | a daily backup CronJob has had no success for too long |
| `NoRecentImmichBackup` | the weekly Immich backup has had no success for 9 days |

The rules are in `monitoring/configs/victoria-metrics/vmrules.yaml`. The
[`backup-nightly-verify`](../agents/skills/backup-nightly-verify/SKILL.md) skill checks a night's run
by hand, including the two silent failure modes the alerts cannot see.

To run one of the four daily backups by hand, for a test:

```bash
kubectl create job --from=cronjob/postgres-backup postgres-backup-manual-$(date +%s) -n databases
kubectl create job --from=cronjob/couchdb-backup couchdb-backup-manual-$(date +%s) -n databases
kubectl create job --from=cronjob/pvc-backup pvc-backup-manual-$(date +%s) -n kube-system
kubectl create job --from=cronjob/mysql-backup mysql-backup-manual-$(date +%s) -n databases
```

Do not start `backup-replication` or `immich-backup` by hand: the repo's Claude Code settings deny
it, because re-running either one is destructive.

## Checks

| How often | Check |
|---|---|
| Daily, automatic | each backup Job and the copy to the NAS succeed (the alerts above) |
| Monthly, by hand | run the secret backup script and store the archive safely; restore one database into a scratch namespace ([`backup-restore-drill`](../agents/skills/backup-restore-drill/SKILL.md)); read the backup logs; check NAS use |
| Quarterly | a full DR drill on spare hardware; there is no staging cluster, so never on the live one |
