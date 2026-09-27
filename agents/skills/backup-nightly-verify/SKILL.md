---
name: backup-nightly-verify
description: Use the morning after a backup change, or when asked to "check last night's backups", "did the backups run", "verify the backup cycle". Confirms all five nightly CronJobs succeeded and that the two with SILENT failure modes (CouchDB partial dump, replication uploading a path it then deletes) produced the right log evidence. Read-only — never triggers a job.
user-invocable: true
---

# Nightly backup verification

```bash
~/.agents/skills/backup-nightly-verify/scripts/verify-nightly.sh            # last night (UTC)
~/.agents/skills/backup-nightly-verify/scripts/verify-nightly.sh 2026-07-28 # a specific date
```

Exit `0` pass · `1` a check failed · `2` a check could not run. **Treat 2 as failure** — an
inconclusive backup check is what hid two nights of broken CouchDB dumps.

The date argument selects Jobs *dated that day*. Backup Jobs carry a 24h TTL, so anything older
than yesterday legitimately reports "no Job dated …" — that is the reaper, not a missed run. The
argument is for re-checking this morning after the fact, not for auditing history.

## Never trigger a job to investigate

`backup-replication` posts to Telegram from inside the run, and its Step 4 deletes the source
on success. Re-running it to "see what happens" destroys the evidence and the source. Capture
logs and report instead. A manual `couchdb-backup` is safe.

## What it checks

| # | Check | Why it is not obvious |
|---|---|---|
| 1 | Firing alerts | Uses `_shared/check-alerts.sh` (VMAlert + Alertmanager), **not** a vmsingle `ALERTS{}` query — that metric lags ~5min behind rule state |
| 2 | Five jobs succeeded, dated today | `pvc-backup` lives in **kube-system**, the other three DB jobs in `databases`, replication in `backup-replication` |
| 3 | `immich-backup` did *not* run | Weekly (Sun 03:00). A run on a weekday is as wrong as a missing daily one |
| 4 | CouchDB completions == databases discovered | The job exits 0 on a partial dump. Counting against the `Found databases:` line is what catches db2 dying after db1 succeeded — matching one completion line does not |
| 5 | Transfer under 1000MB, no `immich/` pruned | See below |
| 6 | `all 4 validated artifact(s)` + `Source cleaned` | The 4 are postgres/couchdb/mysql/pvc — immich was never among them |

Schedules (UTC): postgres 03:00 · couchdb 03:05 · pvc 03:10 · mysql 03:15 · replication 03:30.

## Traps this encodes

**Pick the run by `.status.startTime`, never by sorting job NAMES.** The suffix is minutes
since epoch, so a lexical `sort | tail -1` picks the wrong run once digit count matters — and
yesterday's jobs linger in `kubectl get jobs` until their TTL expires, so "the last one listed"
is routinely the wrong one.

**The expected job set is hardcoded on purpose.** Listing what exists and checking those can
never notice a CronJob that silently vanished or got suspended.

**A size floor fails when the data legitimately shrinks.** Step 1 aborts the whole replication
before the rsync if any one artifact is under its minimum, so a shrunk source blocks the other
three as well. On 2026-08-08 a client-side Obsidian LiveSync rebuild recreated `obsidian-personal`;
the dump went 15.8M → 88K, under the then-100KB CouchDB floor, and nothing reached the NAS.
Check #6 catches it (no `all 4 validated artifact(s)` line), but the Telegram report names it
"Backup Validation FAILED", which reads like corruption. Read the per-artifact table: `SHA256 OK,
tar OK, too small` is a size verdict, not a broken dump. Confirm against the `couchdb-backup` job's
own `Found databases:` / per-database completion lines before touching the floor — those are what
prove content, and the floor is only there to catch a truncated file.

**A >5GB transfer means replication is carrying a path another job owns.** `immich-backup`
publishes to the NAS itself; `--exclude='/immich/'` on the Step 2 rsync is what keeps
replication out of it. Without it, replication re-uploads stale immich generations that its own
Step 4b keep-2 deletes minutes later — 129G a night, both directions (`5f76db93`, 2026-07-27).
The exclude's **leading slash anchors it to the transfer root**; unanchored `immich/` would also
match a future `pvc/<ts>/immich/`. If the size check trips, look there before touching rsync
flags: `speedup is 1.00` on a repeat run means the files really were absent at the destination,
which is a circular pipeline, not a tuning problem.

## Cross-refs

- `backup-restore-drill` — proving backups RESTORE (monthly/quarterly); this skill only proves they RAN
- `monitoring-check` — when the alert step itself looks wrong
- `docs/CODEMAPS/backup-restore.md` — topology, retention, and the exclude
