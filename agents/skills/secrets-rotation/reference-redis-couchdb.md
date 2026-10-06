# Redis and CouchDB rotation (run 2026-10-02)

## Redis (opstree redis-ha): three passes, old and new overlap

Redis accepts several passwords per ACL user, so every user (immich, paperless, blocky, admin)
holds OLD and NEW until every reader has NEW. `rotate-redis-users.sh` edits the SOPS files;
`status` after each pass shows token counts and whether every copy is accepted.

| Pass | `rotate-redis-users.sh` | Then | Done 2026-10-02 |
|---|---|---|---|
| 1 | ACL `>OLD >NEW` for 4 users; app keys + consumers → NEW | commit, merge, fr; `redis-restart.sh replication <sha>`; cycle paperless, immich, blocky (least critical first: blocky is DNS) | yes |
| 2 | `admin-password` → NEW (2nd ACL token; rerun is a no-op) | commit, merge, fr; `redis-restart.sh sentinel <sha>` | yes |
| 3 | ACL keeps only NEW | commit, merge, fr; `redis-acl-drop-old.sh` (no restart) | yes |

What the run showed:

| Observation | Consequence |
|---|---|
| The ACL Secret is mounted with `subPath` | a running pod never sees the new file, so `ACL LOAD` re-reads the old one; only a restart or a runtime `ACL SETUSER` changes the live ACL |
| A replication restart can leave both pods `role:master` until the operator re-attaches the replica (~50s on 2026-10-02) | the label-based `redis-replication-master` Service has no stable target meanwhile; `redis-restart.sh` waits until one master has one replica with the link up |
| A replication restart gives both pods new IPs; the sentinels keep monitoring the dead master IP (`s_down,o_down`, failover stuck) | no automatic failover until the sentinels restart. After a sentinel restart the operator needs ~10s to set the master (`NOQUORUM` until then); `redis-restart.sh sentinel` waits until all three name the current master and quorum is OK |
| `ACL SETUSER <user> !<hash>` removes OLD from a running pod | pass 3 needs no restart. ACL changes do not replicate, so `redis-acl-drop-old.sh` runs on every pod and exits 1 unless every user holds only NEW |
| blocky sets redis `required: true` | a blocky pod that cannot log in does not start; cycle blocky last, and only after Redis accepts NEW |
| Not tried yet: `ACL SETUSER <user> #<sha256(NEW)>` (pass 1) and `SENTINEL SET myMaster auth-pass` (pass 2) at runtime | could make the whole rotation restart-free; test on a scratch Redis before using it live |

Proof per consumer: `redis-cli CLIENT LIST` on the master, connections with `user=<app>` from the
new pod's IP (the default user has no password, so `redis-cli` in the pod needs no auth).
`db-operations/scripts/redis-master.sh exec` is broken for this: it sends AUTH to the default user
and passes the command as one quoted argument.

The ACL's `user default on nopass ~* &* +@all` line means any client that reaches Redis has full
rights without a password; the per-app passwords limit nothing until that line changes. Open
finding, 2026-10-02.

## CouchDB admin

Three SOPS copies (see `docs/SECRETS_ROTATION.md` Standard section). Rotate them by value (one new
password into every copy that holds the old one). Then, per pod: delete it, wait for the new pod
to be Ready, and require the login and membership proof below before deleting the other pod.

Why a pod restart applies it: the image entrypoint writes `[admins] <user> = <COUCHDB_PASSWORD>`
into `/opt/couchdb/etc/local.d/docker.ini` if no admin of that name is defined, and `local.d` is not
mounted, so every new container starts without one and takes the env value. The data PVC holds no
admin. While one pod has restarted and the other has not, the two nodes disagree for a minute or
two.

Obsidian LiveSync on the operator's devices logs in as this admin user, not as the sync user
(operator, 2026-10-06). The plugin's database-configuration fixes change CouchDB server settings.
The sync user is admin of `obsidian-personal` only. After the 2026-10-02 rotation, CouchDB logged
401 for the devices' sync requests, through Cloudflare and from the LAN.

Proof per pod: `curl -u "$COUCHDB_USER:$COUCHDB_PASSWORD" http://127.0.0.1:5984/_session` inside
the pod (its env holds the new Secret value) returns 200, and `_membership` lists both nodes in `all_nodes` and `cluster_nodes`.

If both pods pass, stop and tell the operator to put the new password into LiveSync on every
device. 1Password holds no copy. The operator reads it with
`sops -d --extract '["stringData"]["adminPassword"]' infrastructure/configs/databases/couchdb/admin-secret.yaml`.

The next morning's `backup-nightly-verify` confirms the backup CronJob.
