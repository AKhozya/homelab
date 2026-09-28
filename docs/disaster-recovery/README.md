# Disaster Recovery Runbook

This runbook rebuilds the cluster from nothing. The order is: build the nodes, restore the
secrets, start Flux, then restore the databases and volumes from the backups. The same encryption
and ordering rules apply whether you restore one database or everything.

| Page | Covers |
|---|---|
| This page | The rebuild, every restore procedure, and configuration rollback |
| [BACKUP_STRATEGY.md](../BACKUP_STRATEGY.md) | What is backed up, when, for how long, and the recovery targets |
| [setup/K3S_SETUP.md](../setup/K3S_SETUP.md) | Installing K3s on each node |

Start every command block on this page from the root of a checkout of this repo, unless a step says
to run it on a node. The secret-backup blocks change into `.backup/` themselves.

## Secret backups

The cluster's secrets are backed up by hand, separately from the data. The scripts live in
`.backup/`, and every archive is encrypted.

| Rule | Detail |
|---|---|
| Encrypted | Each archive is encrypted with GPG (AES256) |
| No plain copy left | The script deletes the unencrypted secrets directory after encrypting it |
| Not in Git | `.gitignore` excludes the archives and the `.backup/secrets/` output; the scripts are tracked |
| No default passphrase | You must choose one |
| Passphrase | Keep it in 1Password; without it the archive cannot be decrypted |

### 1. Create an encrypted backup (monthly)

```bash
cd .backup
chmod +x secrets-backup.sh
./secrets-backup.sh

# Script prompts for passphrase interactively
# Or set env var to skip prompt:
# export GPG_PASSPHRASE='your-very-secure-passphrase'

# WARNING: Store passphrase in 1Password — need to decrypt!
```

**Output:** `secrets-backup-YYYYMMDD_HHMMSS.tar.gz.gpg`, an encrypted archive.

### 2. Decrypt a backup (optional)

`secrets-restore.sh` decrypts the archive itself, so you rarely need this. To inspect one by hand,
run this inside `.backup/`, next to the archive:

```bash
# Interactive (prompts for passphrase)
gpg --decrypt secrets-backup-20251030_120000.tar.gz.gpg | tar -xzf - -C .

# Non-interactive (env var)
export GPG_PASSPHRASE='your-passphrase'
gpg --decrypt --batch --passphrase-file <(echo "$GPG_PASSPHRASE") \
  secrets-backup-20251030_120000.tar.gz.gpg | tar -xzf - -C .
```

The archive unpacks to `secrets/`, one JSON file per secret. It holds every secret a full rebuild
needs:

| Group | Secrets |
|---|---|
| Critical infrastructure | the SOPS age key, which decrypts everything else; the Cloudflare API token (cert-manager DNS-01); the Cloudflare tunnel credentials and config |
| Monitoring | Grafana admin credentials; the Alertmanager Telegram bot token |
| Databases | Redis passwords; the PostgreSQL admin and every app database user; the MySQL cluster secrets and app credentials (Uptime Kuma, PriceBuddy) |
| Apps | Authentik, Immich, Home Assistant, n8n, Linkwarden, Mealie, Paperless-NGX, Audiobookshelf, Uptime Kuma, Stirling-PDF, HomeHub, PriceBuddy, CouchDB (Obsidian sync) |
| Backup replication | the NAS rsync credentials; the Telegram bot token for backup failure alerts |

The files land in `.backup/secrets/`, which Git ignores.

## Automated data backups

CronJobs run the data backups on the schedules below, without any manual step. [BACKUP_STRATEGY.md](../BACKUP_STRATEGY.md)
has the full policy.

| Backup | When (UTC) | Where | Kept |
|---|---|---|---|
| PostgreSQL | daily 03:00 | `/mnt/k8s-storage/backups/postgres/` on worker-node | 30 days |
| CouchDB | daily 03:05 | `/mnt/k8s-storage/backups/couchdb/` | 30 days |
| App volumes (14 PVCs) | daily 03:10 | `/mnt/k8s-storage/backups/pvc/` | 30 days |
| MySQL | daily 03:15 | `/mnt/k8s-storage/backups/mysql/` | 30 days |
| Immich library | Sunday 03:00 | `immich-backup` on worker-node-2 pulls the library from the NAS, writes a tar and checksum to `/mnt/extra-storage/immich-backup/` and a copy to the NAS `akhozya-pool1` pool | 2 of each (about 61 GB uncompressed) |
| Copy to the NAS | daily 03:30 | NAS (`backup-replication` Step 4b prunes it) | 30 days; Immich keeps 2 |

## Full recovery

### Step 1: Build the nodes

Follow [setup/K3S_SETUP.md](../setup/K3S_SETUP.md) for each node: control plane first, then
worker-node and worker-node-2, then `immich-vm`. It covers the bootstrap script, the Ansible
config, the pinned K3s install, the join token and the kubeconfig. Read its control-plane section
first: the first-start order there is not drilled and has a known gap.

### Step 2: Firewall

The Ansible `firewall` role already applied the rules in step 1 (`node-maintenance-config.service`).
Do not run `ufw` by hand; the role owns the rules, only adds them, and never resets them.

### Step 3: Install the Flux CLI

```bash
brew install fluxcd/tap/flux  # macOS
```

### Step 4: Restore all secrets

**Run this BEFORE you bootstrap Flux.**

```bash
cd .backup
chmod +x secrets-restore.sh
./secrets-restore.sh

# Script will:
# 1. Auto-find latest encrypted backup
# 2. Prompt for passphrase to decrypt
# 3. Restore all secrets to respective namespaces
#
# Set GPG_PASSPHRASE env var to skip prompt
```

The script decrypts the archive and restores every secret the cluster needs.

### Step 5: Bootstrap Flux

Start CoreDNS first. The control plane's K3s config turns off the bundled CoreDNS, and Flux is the
only source of the cluster's DNS (`infrastructure/coredns/`). Flux's own controllers need that DNS
to reach GitHub, so without this apply the bootstrap cannot fetch the repo. This apply from a
checkout is a second exception to the GitOps-only rule; Flux adopts the objects on its first
reconcile of the `coredns` Kustomization.

```bash
# From a checkout of this repo
kubectl apply -k infrastructure/coredns/
kubectl -n kube-system rollout status daemonset/coredns-ha --timeout=5m
```

```bash
flux bootstrap github \
  --owner=AKhozya \
  --repository=homelab \
  --path=clusters \
  --personal
```

### Step 6: Wait for reconciliation

```bash
# Watch deploy
watch kubectl get pods -A

# Flux status
flux get kustomizations -A
kubectl get helmrelease -A
```

**On a bare cluster, `apps` fails here. That does not mean the restore is broken.**
`require-networkpolicy` is a Deny policy that counts the NetworkPolicies that exist in the target
namespace right now. Flux's kustomize-controller dry-runs its whole set of changes on the server
before it writes any of them. A workload and the NetworkPolicy that would allow it arrive in the
same set, so the dry run rejects the workload while its policy is still unwritten:

```
admission webhook denied the request: Namespace must declare at least one NetworkPolicy
```

This is the two-commit new-namespace problem (`.claude/review-invariants.md`) hitting every
namespace at once, and the repo has no fix for it yet. To unblock it, apply the namespaces and
NetworkPolicies on their own; the workloads wait on nothing else. Then let Flux reconcile the rest.

Run this **after** `flux bootstrap`, not before: it repairs a reconcile that has already failed,
and it is not part of the secret restore. Once the policies exist, Flux converges on its next
run.

```bash
# Run from a checkout of this repo, not from the cluster.
# Namespaces AND policies together: trivy-scan and popeye each ship their own
# namespace, so a policies-only pass would have nowhere to put them.
# The `echo ---` is load-bearing: kustomize build emits no trailing separator,
# so without it the last document of one root merges into the first of the next
# and you get a Namespace carrying someone else's roleRef.
extract() {
  for d in apps/*/ monitoring/configs/*/ monitoring/controllers/*/ infrastructure/configs/*/; do
    kustomize build "$d" 2>/dev/null
    echo "---"
  done | yq 'select(.kind == "Namespace" or .kind == "NetworkPolicy")'
}

extract | kubectl apply --dry-run=server -f -    # expect 23 namespaces + 58 policies (2026-08-06)
extract | kubectl apply -f -
```

Then run `flux reconcile kustomization apps --with-source` and watch `flux get kustomizations -A`
turn Ready. If a later change adds a layer that applies the NetworkPolicies before the policy
check, this step is no longer needed; check the Kustomization graph before you assume it still is.

### Step 7: Restore the data

The backups exist in two places. Use them in this order:

| Source | Notes |
|---|---|
| NAS (192.168.1.136), rsync daemon on port 50555 | full history |
| worker-node (192.168.1.129) | the replication job cleans it daily, so it may be empty |

**Copy the backups from the NAS to worker-node.** Either run rsync on worker-node (you need a shell
there and the password in your environment):

```bash
# Get NAS creds from restored secrets or 1Password
export RSYNC_PASSWORD='<nas-rsync-password>'
rsync -avz --port=50555 \
  rsync://akhozya@192.168.1.136/akhozya-pool1/backups/homelab/ \
  /mnt/k8s-storage/backups/
```

…or run it as a Job. The Job needs neither node SSH nor the password in your shell: it reads the
existing `nas-rsync-credentials` Secret and uses the namespace's NAS egress policy. Prefer it if
the SSH key is locked in 1Password during the incident. Set `SUBDIR` to the backup type you need
(`couchdb`, `postgres`, `mysql` or `pvc`); the Job fetches the newest archive and its `.sha256`
file. Last run 2026-07-24.

```bash
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: nas-fetch
  namespace: backup-replication
  labels:
    app: backup-replication
spec:
  ttlSecondsAfterFinished: 3600
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: backup-replication
    spec:
      restartPolicy: Never
      serviceAccountName: backup-replication
      nodeSelector:
        kubernetes.io/hostname: worker-node
      securityContext:
        runAsUser: 0
        runAsGroup: 0
        seccompProfile:
          type: RuntimeDefault
      volumes:
        - name: source-backups
          hostPath:
            path: /mnt/k8s-storage/backups
            type: Directory
      containers:
        - name: nas-fetch
          image: alpine:3.24.1
          volumeMounts:
            - name: source-backups
              mountPath: /source-backups
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            capabilities:
              drop: ["ALL"]
              add: ["DAC_OVERRIDE", "CHOWN", "FOWNER"]
          env:
            - name: SUBDIR
              value: "couchdb"
            - name: NAS_RSYNC_USER
              valueFrom:
                secretKeyRef:
                  name: nas-rsync-credentials
                  key: rsync-user
            - name: NAS_RSYNC_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: nas-rsync-credentials
                  key: rsync-password
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              apk add --no-cache rsync >/dev/null
              mkdir -p "/source-backups/$SUBDIR"
              NEWEST=$(RSYNC_PASSWORD="$NAS_RSYNC_PASSWORD" rsync --port=50555 -r --list-only \
                "rsync://${NAS_RSYNC_USER}@192.168.1.136/akhozya-pool1/backups/homelab/${SUBDIR}/" \
                | awk '$NF ~ /\.tar\.gz$/ {print $NF}' | sort | tail -1)
              [ -n "$NEWEST" ] || { echo "no .tar.gz on NAS under $SUBDIR"; exit 1; }
              echo "=== fetching $NEWEST (+ .sha256) ==="
              RSYNC_PASSWORD="$NAS_RSYNC_PASSWORD" rsync --port=50555 -av \
                --include="$NEWEST" --include="$NEWEST.sha256" --exclude='*' \
                "rsync://${NAS_RSYNC_USER}@192.168.1.136/akhozya-pool1/backups/homelab/${SUBDIR}/" \
                "/source-backups/${SUBDIR}/"
              ls -l "/source-backups/${SUBDIR}/"
EOF

# Keep the Job on failure: a bare `wait; logs; delete` sequence would exit 0 even when the
# wait failed, and would delete the evidence.
if kubectl wait --for=condition=complete job/nas-fetch -n backup-replication --timeout=30m; then
  kubectl logs -n backup-replication job/nas-fetch --tail=20
  kubectl delete job nas-fetch -n backup-replication
else
  echo "NAS FETCH FAILED — Job kept for diagnosis."
  kubectl logs -n backup-replication job/nas-fetch --tail=50
  false
fi
```

The PostgreSQL and MySQL restores each take two hosts. The archives sit on worker-node, where only
root can read them and `kubectl` is not configured. The restore runs from the workstation, which
has `kubectl`. So verify and extract on the node, copy the extracted directory over, then restore.

#### PostgreSQL

```bash
# --- on worker-node, as root (sudo -i): verify and extract ---
set -euo pipefail
# The .sha256 file names the archive without a directory, so check it from inside this one.
cd /mnt/k8s-storage/backups/postgres
LATEST=$(ls -t postgres_*.tar.gz | head -1)
sha256sum -c "$LATEST.sha256"
tar -xzf "$LATEST" -C /tmp
# The archive holds one directory named after its timestamp (YYYYMMDD_HHMMSS).
TS=$(basename "$LATEST" .tar.gz | sed 's/^postgres_//')
chown -R akhozya: "/tmp/$TS"
echo "TS=$TS"
```

```bash
# --- workstation: copy the dumps over, then restore ---
TS=20260928_020000   # <-- the value the node printed
FAILED=""
if scp -P 65300 -r "akhozya@worker-node:/tmp/${TS:?}" /tmp/ &&
   PRIMARY=$(kubectl get pod -n databases -l cnpg.io/cluster=main-postgres,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}'); then
  # Iterate the actual dumps (custom format, pg_dump -F c), so every backed-up database is
  # covered and none is invented. One failed database does not stop the others.
  for DUMP in "/tmp/$TS"/*.dump; do
    DB=$(basename "$DUMP" .dump)
    echo "Restoring $DB -> $PRIMARY..."
    kubectl exec -i -n databases "$PRIMARY" -- \
      pg_restore -U postgres -d "$DB" -c --if-exists < "$DUMP" || FAILED="$FAILED $DB"
  done
else
  FAILED=" (copy or primary lookup)"
fi
if [ -n "$FAILED" ]; then echo "RESTORE FAILED:$FAILED — fix these before you start the apps"; false; fi
```

#### MySQL

On a rebuilt cluster the MySQL databases and users do not exist yet. Create them first with
[`mysql-create-dbs.sql`](mysql-create-dbs.sql) in this folder; replace each `<value>` with the
password from the restored secrets. Then restore the dumps:

```bash
# --- on worker-node, as root (sudo -i): verify and extract ---
set -euo pipefail
# The .sha256 file names the archive without a directory, so check it from inside this one.
cd /mnt/k8s-storage/backups/mysql
LATEST=$(ls -t mysql_*.tar.gz | head -1)
sha256sum -c "$LATEST.sha256"
tar -xzf "$LATEST" -C /tmp
# The archive holds one directory named after its timestamp (YYYYMMDD_HHMMSS).
TS=$(basename "$LATEST" .tar.gz | sed 's/^mysql_//')
chown -R akhozya: "/tmp/$TS"
echo "TS=$TS"
```

```bash
# --- workstation: copy the dumps over, then restore ---
TS=20260928_020000   # <-- the value the node printed
FAILED=""
if scp -P 65300 -r "akhozya@worker-node:/tmp/${TS:?}" /tmp/ &&
   MYSQL_ROOT_PWD=$(kubectl get secret -n databases mysql-cluster-secrets -o jsonpath='{.data.root}' | base64 -d) &&
   [ -n "$MYSQL_ROOT_PWD" ]; then
  for SQL in "/tmp/$TS"/*.sql; do
    DB=$(basename "$SQL" .sql)
    echo "Restoring $DB..."
    # -h haproxy routes the write to the primary
    kubectl exec -i -n databases main-mysql-mysql-0 -c mysql -- \
      mysql -h main-mysql-haproxy.databases.svc.cluster.local -uroot -p"${MYSQL_ROOT_PWD}" "$DB" < "$SQL" \
      || FAILED="$FAILED $DB"
  done
else
  FAILED=" (copy or root password lookup)"
fi
if [ -n "$FAILED" ]; then echo "RESTORE FAILED:$FAILED — fix these before you start the apps"; false; fi
```

#### CouchDB

> The restore Jobs on this page are applied straight to the cluster, not committed to Git. That
> is the one exception to the GitOps-only rule in AGENTS.md, which notes it too. Committing them
> would make Flux re-run a destructive restore on every reconcile. They run once and are deleted
> when complete.

The CouchDB image does not contain `couchrestore`; it ships with `@cloudant/couchbackup` (npm), the
same tool the backup CronJob uses. So the restore runs as a Job that reads the archive straight off
the backup `hostPath`, the way the backup CronJob reaches it. The admin credentials come from the
`couchdb-couchdb` Secret, so they never appear in shell history or in the Job spec. They do reach the
`couchrestore` command line inside the pod, because `--url` is its only way to take credentials, so
anything that can read that pod's process list can see them.

**Drilled end to end on 2026-07-24.** A full restore of the live Obsidian database into a scratch
target completed: 1505 document revisions, 1479 documents against 1494 live (the difference is
edits made after the 03:05 backup), and the deleted-document counts matched exactly at 21.

Four things make a plain `kubectl run` fail here. Each was found by running it:

| # | Problem | Fix in the Job below |
|---|---|---|
| 1 | **Kyverno denies it.** All 12 policies deny. The `app` label (require-labels), requests and limits (require-resource-limits), runAsNonRoot (require-non-root), seccompProfile (require-seccomp-runtimedefault), drop ALL (require-drop-all-capabilities), `allowPrivilegeEscalation: false` (disallow-privilege-escalation), readOnlyRootFilesystem (require-readonly-rootfs) and a non-default serviceAccountName (require-non-default-serviceaccount, so `couchdb-jobs`) are each required by one of them. The webhook names only the first failing policy, so a missing field gives one misleading error, not a list. | every field is set |
| 2 | **The ResourceQuota denies it too.** `namespace-quota` on `databases` leaves only about 800m CPU free on a running cluster, so a 1-CPU limit is rejected even after Kyverno passes. Check first: `kubectl get resourcequota namespace-quota -n databases`. In a real full restore the namespace is mostly empty, so there is room. | a 500m limit |
| 3 | **`readOnlyRootFilesystem` breaks npm.** Its default `~/.npm` is not writable, so `npm install` fails and `couchrestore` is simply missing. | `HOME` and `npm_config_cache` point into the `/tmp` emptyDir |
| 4 | **The default `--parallelism 5` breaks authentication part-way.** It shows up only after several batches succeed, so it looks like a partial success. The comment on the `couchrestore` call explains it. | `--parallelism 1` |

Also: `couchrestore` does not create the target database, and this image's busybox `wget` has no
`--method` flag (only `--post-data` and `--post-file`). So the Job creates the database with Node's
built-in `fetch` and an Authorization header. HTTP 412 means it already exists, which is fine.

The Job picks the archive and checks its checksum itself, so it needs no node SSH. That matters
because the SSH key lives in 1Password and may be unavailable during an incident.

```bash
# ARCHIVE: leave EMPTY to use the newest archive; set a filename to pin a specific one.
ARCHIVE=""
# DRILL_SUFFIX is the safety catch: "-drill" restores into <db>-drill and proves the whole
# path WITHOUT touching live data. Set it to "" for a real disaster recovery.
# A real restore never DELETES anything — the drop below is drill-only, and couchrestore
# refuses a non-empty target. So a real restore needs the target absent or empty (true when
# rebuilding a cluster): restoring over a populated database FAILS rather than overwriting
# it, and you must drop that database yourself first.
DRILL_SUFFIX="-drill"     # <-- "" for a real restore

kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: couchrestore
  namespace: databases
  labels:
    app: couchrestore
spec:
  ttlSecondsAfterFinished: 3600
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: couchrestore
    spec:
      restartPolicy: Never
      serviceAccountName: couchdb-jobs
      # hostPath is node-local — the archives exist only on worker-node.
      nodeSelector:
        kubernetes.io/hostname: worker-node
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      volumes:
        - name: backup-storage
          hostPath:
            path: /mnt/k8s-storage/backups/couchdb
            type: Directory
        - name: tmp
          emptyDir: {}
      containers:
        - name: couchrestore
          image: node:24.18.0-alpine
          volumeMounts:
            - name: backup-storage
              mountPath: /backup
              readOnly: true
            - name: tmp
              mountPath: /tmp
          resources:
            requests:
              cpu: "100m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "1Gi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          env:
            - name: HOME
              value: /tmp
            - name: npm_config_cache
              value: /tmp/.npm
            - name: ARCHIVE
              value: "${ARCHIVE}"
            - name: DRILL_SUFFIX
              value: "${DRILL_SUFFIX}"
            # No backticks anywhere in this heredoc: it is UNQUOTED, so backticks
            # would be command substitution on the operator's own machine.
            # Must match clusterSize in the couchdb HelmRelease values. CouchDB
            # defaults new databases to n=3; on this 2-node cluster that logs
            # "Request to create N=3 DB but only 2 node(s)" and creates it wrong.
            - name: CLUSTER_N
              value: "2"
            - name: COUCHDB_ENDPOINT
              value: http://couchdb-couchdb.databases.svc.cluster.local:5984
            - name: U
              valueFrom:
                secretKeyRef:
                  name: couchdb-couchdb
                  key: adminUsername
            - name: P
              valueFrom:
                secretKeyRef:
                  name: couchdb-couchdb
                  key: adminPassword
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              npm install --prefix /tmp @cloudant/couchbackup@2.11.18 >/dev/null
              if [ -n "\$ARCHIVE" ]; then
                SRC="/backup/\$ARCHIVE"
              else
                SRC=\$(ls -t /backup/couchdb_*.tar.gz | head -1)
              fi
              [ -f "\$SRC" ] || { echo "archive not found: \$SRC"; exit 1; }
              echo "=== archive: \$SRC ==="
              # Verify the checksum HERE rather than over SSH — the sidecar sits next to it.
              if [ -f "\$SRC.sha256" ]; then
                ( cd /backup && sha256sum -c "\$(basename "\$SRC").sha256" ) || {
                  echo "CHECKSUM MISMATCH — refusing to restore"; exit 1; }
              else
                echo "no .sha256 sidecar — refusing to restore an unverified archive"; exit 1
              fi
              mkdir -p /tmp/restore
              tar -xzf "\$SRC" -C /tmp/restore
              FIRST=\$(find /tmp/restore -name '*.couchbackup' | head -1)
              # Test FIRST, not dirname's output: dirname "" returns ".", which passes a
              # -d check and then iterates the literal unmatched glob.
              [ -n "\$FIRST" ] || { echo "no .couchbackup files inside \$SRC"; exit 1; }
              DIR=\$(dirname "\$FIRST")
              RC=0
              for BK in "\$DIR"/*.couchbackup; do
                DB="\$(basename "\$BK" .couchbackup)\$DRILL_SUFFIX"
                echo "=== restoring \$DB ==="
                # Pre-create the database; couchrestore will not do it. couchrestore also
                # REFUSES a non-empty target, so in drill mode (and ONLY in drill mode)
                # the scratch database is dropped first to make re-runs idempotent.
                if ! DB="\$DB" node -e 'const a="Basic "+Buffer.from(process.env.U+":"+process.env.P).toString("base64");const u=process.env.COUCHDB_ENDPOINT+"/"+process.env.DB;const cu=u+"?n="+(process.env.CLUSTER_N||"2");const h={Authorization:a};(async()=>{try{if(process.env.DRILL_SUFFIX){const d=await fetch(u,{method:"DELETE",headers:h});console.log("drill: dropped scratch db ("+d.status+")")}const r=await fetch(cu,{method:"PUT",headers:h});if([201,202,412].indexOf(r.status)<0){console.error("create failed: "+r.status);process.exit(1)}console.log("db ready ("+r.status+")")}catch(e){console.error(e.message);process.exit(1)}})()'
                then
                  # A negated test is true when the command FAILED, so the failure
                  # handling belongs here. Guarded because under set -e an unguarded
                  # failure would abort the whole restore instead of moving to the next
                  # database. (No backticks in this heredoc — it is unquoted.)
                  echo "FAILED \$DB (database pre-create)"
                  RC=1
                  continue
                fi
                # --parallelism 1 is REQUIRED, not a tuning choice. At the default 5, some
                # concurrent requests reach CouchDB with no credentials at all (its log shows
                # the user as "undefined" and returns 401 on _bulk_docs) and the restore dies
                # part-way with "Access is denied due to invalid credentials" — after having
                # already written several batches. couchrestore has no username/password
                # flags, only --url, so serialising is the fix.
                if /tmp/node_modules/.bin/couchrestore --url "http://\$U:\$P@couchdb-couchdb.databases.svc.cluster.local:5984" --parallelism 1 --db "\$DB" < "\$BK"; then
                  echo "OK \$DB"
                else
                  echo "FAILED \$DB"
                  RC=1
                fi
              done
              exit \$RC
EOF

# Do NOT run these as three independent commands: if `wait` fails, a following successful
# `logs` and `delete` leaves the block at exit status 0 and destroys the failure evidence.
if kubectl wait --for=condition=complete job/couchrestore -n databases --timeout=30m; then
  kubectl logs -n databases job/couchrestore --tail=50
  kubectl delete job couchrestore -n databases
else
  echo "RESTORE FAILED — Job kept for diagnosis; delete it yourself once done."
  kubectl logs -n databases job/couchrestore --tail=100
  false
fi
```

After a drill, drop the scratch databases (named `<db>-drill`):

```bash
kubectl exec -n databases couchdb-couchdb-0 -c couchdb -- \
  curl -sS -X DELETE -u "$ADMIN_USER:$ADMIN_PASS" "http://127.0.0.1:5984/<db>-drill"
```

#### App volumes (PVCs)

The `pvc-backup` CronJob covers **14** PVCs across 10 namespaces. Nothing needs a lookup table:
local-path names each volume directory `<pv-uuid>_<namespace>_<pvc-name>`, and the owning workload
can be read from the PVC, so the restore finds both itself. A hardcoded name becomes wrong as soon
as a PVC is recreated.

Archives sit at `/mnt/k8s-storage/backups/pvc/<timestamp>/<namespace>/<pvc-name>.tar[.gz]`, each
with a `.sha256` file. `audiobookshelf-audiobooks` and `audiobookshelf-podcasts` are stored
**uncompressed** (`.tar`), because they hold audio that is already compressed; every other archive
is `.tar.gz`.

The restore takes three steps on two hosts. Every volume this job backs up lives on `worker-node`.
Run each block whole: each one sets `set -e`, so a failed step stops before the next one, not
after it has extracted into a running app or restarted on top of a half-done extract.

```bash
# --- STEP 1 (workstation): stop the workload ---
set -euo pipefail
NS=home-assistant
PVC=home-assistant-data-pvc

# Find the workload that mounts this PVC — never guess the name.
WORKLOAD=$(kubectl get deploy,statefulset -n "$NS" -o json \
  | jq -r --arg p "$PVC" '.items[]
      | select([.spec.template.spec.volumes[]?.persistentVolumeClaim.claimName] | index($p))
      | "\(.kind|ascii_downcase)/\(.metadata.name)"')
[ -n "$WORKLOAD" ] || { echo "no workload mounts $NS/$PVC"; exit 1; }
echo "workload: $WORKLOAD"

# Derive the selector — do NOT assume `app=<namespace>`. linkwarden's meilisearch
# StatefulSet selects `app=meilisearch`, so a guessed label waits on the wrong pods
# and the extract would start while the app is still writing.
SEL=$(kubectl get "$WORKLOAD" -n "$NS" -o jsonpath='{.spec.selector.matchLabels}' \
  | jq -r 'to_entries|map("\(.key)=\(.value)")|join(",")')

# Suspend Flux first. Every one of these workloads sets `replicas: 1` in git, and the `apps`
# Kustomization would scale it back up within a minute, in the middle of STEP 2.
flux suspend kustomization apps
kubectl scale "$WORKLOAD" -n "$NS" --replicas=0
kubectl wait --for=delete pod -l "$SEL" -n "$NS" --timeout=5m
echo "stopped; Flux 'apps' is SUSPENDED until STEP 3 — now run STEP 2 on worker-node"
```

```bash
# --- STEP 2 (on worker-node, as root: sudo -i): verify, set aside, extract. DESTRUCTIVE ---
set -euo pipefail
NS=home-assistant
PVC=home-assistant-data-pvc

# Resolve the PV directory HERE, on the node. kubectl is not configured on agent nodes,
# and a PV_PATH computed in the workstation shell does not exist in this one. local-path
# encodes both names in the directory, so the same glob the backup CronJob uses works.
# Require EXACTLY one match — `| head -1` would silently pick one of several and extract
# over the wrong volume. A stale directory from a recreated PVC is the realistic way two
# appear, and that is precisely when guessing is worst.
MATCHES=$(find /mnt/k8s-storage -maxdepth 1 -type d -name "*_${NS}_${PVC}")
COUNT=$(printf '%s\n' "$MATCHES" | grep -c . || true)
[ "$COUNT" = "1" ] || { echo "expected 1 PV directory for ${NS}/${PVC}, found ${COUNT}:"; printf '%s\n' "$MATCHES"; exit 1; }
PV_PATH="$MATCHES"

# Pin ONE backup generation. For a multi-PVC app, `ls -td | head -1` re-evaluated per PVC
# would silently mix generations if the 03:10 backup lands mid-restore. Run this block for
# the first PVC, then `export BACKUP_DIR=<printed value>` before the remaining ones.
BACKUP_DIR="${BACKUP_DIR:-$(ls -td /mnt/k8s-storage/backups/pvc/*/ | head -1)}"
echo "using backup generation: $BACKUP_DIR"

# .tar for the two audiobookshelf audio PVCs, .tar.gz for the rest; tar -xf detects either.
ARCHIVE="$BACKUP_DIR/$NS/$PVC.tar.gz"
[ -f "$ARCHIVE" ] || ARCHIVE="$BACKUP_DIR/$NS/$PVC.tar"
[ -f "$ARCHIVE" ] || { echo "no archive for ${NS}/${PVC} in $BACKUP_DIR"; exit 1; }

# Verify BEFORE touching anything — a bad archive must not cost both the app and the data.
( cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$ARCHIVE").sha256" )
tar -tf "$ARCHIVE" >/dev/null

# Set the old directory aside instead of extracting over it. tar does not delete files
# missing from the archive, so an overlay leaves stale data behind — for anything with a
# WAL or index that is a corrupt hybrid, not a restore. This also keeps a rollback.
STAMP=$(date +%Y%m%d-%H%M%S)
mv "$PV_PATH" "${PV_PATH}.pre-restore-${STAMP}"
mkdir -p "$PV_PATH"
chown --reference="${PV_PATH}.pre-restore-${STAMP}" "$PV_PATH"
chmod --reference="${PV_PATH}.pre-restore-${STAMP}" "$PV_PATH"

# Created with `tar -C <pv-dir> .`, so it extracts at the PV root.
tar -xf "$ARCHIVE" -C "$PV_PATH"
echo "extracted — old data kept at ${PV_PATH}.pre-restore-${STAMP}"
```

```bash
# --- STEP 3 (workstation): start it back up ---
# Rediscovers its own inputs. Inheriting $WORKLOAD/$NS from STEP 1 means that in any other
# shell `set -u` aborts here and the app stays scaled to zero — a failure that reads as
# "the restore is still running" while the outage continues.
set -euo pipefail
NS=home-assistant
PVC=home-assistant-data-pvc

WORKLOAD=$(kubectl get deploy,statefulset -n "$NS" -o json \
  | jq -r --arg p "$PVC" '.items[]
      | select([.spec.template.spec.volumes[]?.persistentVolumeClaim.claimName] | index($p))
      | "\(.kind|ascii_downcase)/\(.metadata.name)"')
[ -n "$WORKLOAD" ] || { echo "no workload mounts $NS/$PVC"; exit 1; }

kubectl scale "$WORKLOAD" -n "$NS" --replicas=1
flux resume kustomization apps
kubectl rollout status "$WORKLOAD" -n "$NS" --timeout=5m
```

Flux stays suspended from STEP 1 until STEP 3 resumes it, and applies no change to any app in
between. If you stop before STEP 3, resume Flux only once the volume holds complete data: STEP 2
finished, or the rollback below restored the original. If you resume earlier, Flux starts the app
on a half-extracted volume.

**If STEP 2 fails part-way**, the original data is untouched under `.pre-restore-*`. Leave the
workload stopped and roll back on the node before you restart anything. Then run STEP 3, which
resumes Flux:

```bash
# --- ROLLBACK (on worker-node, as root: sudo -i) ---
# Rediscovers both directories rather than reusing STEP 2's $PV_PATH/$STAMP — those are
# gone if that shell exited, which is exactly the situation a rollback follows.
# `-name` matches the whole basename, so the live directory and the `.pre-restore-*`
# copy never match each other's pattern.
set -euo pipefail
NS=home-assistant
PVC=home-assistant-data-pvc

SAVED=$(find /mnt/k8s-storage -maxdepth 1 -type d -name "*_${NS}_${PVC}.pre-restore-*")
# Everything keys off SAVED. If STEP 2's `mv` never ran there is no .pre-restore-* copy,
# the original was never touched, and this exits BEFORE any rm — nothing to roll back.
# Zero or several matches both stop here: deleting the live directory on a guess is the
# one mistake a rollback must never make.
[ "$(printf '%s\n' "$SAVED" | grep -c . || true)" = "1" ] || {
  echo "expected exactly 1 .pre-restore-* directory for ${NS}/${PVC}, found:"
  printf '%s\n' "$SAVED"
  echo "STOP — do not delete anything by hand until you know which is the original."
  exit 1; }

# Derive the live path from SAVED rather than globbing for it: if mkdir failed, the live
# directory does not exist and a second find would return empty, turning the rm below
# into `rm -rf ""`.
TARGET="${SAVED%.pre-restore-*}"
if [ -d "$TARGET" ]; then rm -rf "$TARGET"; fi
mv "$SAVED" "$TARGET"
echo "rolled back to $TARGET"
```

Delete the `.pre-restore-*` directory only after the app is healthy; it is the rollback.
`audiobookshelf` has 4 backed-up PVCs and one Deployment for all of them: run STEP 1 once, STEP 2
once per PVC with `BACKUP_DIR` pinned, then STEP 3 once. `stirling-pdf` mounts 3 PVCs, but only
`stirling-pdf-configs-pvc` is backed up, so it takes one STEP 2.

> **Not drilled.** The discovery block and the PVC → volume → path → workload mapping were checked
> against the live cluster on 2026-07-25 for all 14 PVCs. The extract itself has **not** been
> rehearsed end to end, unlike the CouchDB restore. Run the checksum and `tar -tf` steps first;
> they are the cheap way to find a bad archive before the app is already down.

#### Immich library

The PVC backup leaves out the Immich photos; the weekly `immich-backup` CronJob covers them. The
library lives on the NAS, mounted into `immich-vm` over virtiofs as a `hostPath` (the container
sees it at `/data`). There is no library PVC, so a restore writes onto the NAS.

```bash
# 0) Pick a source tar + verify. The NAS pool is reachable from your workstation over
#    the rsync daemon; the W2 copy (/mnt/extra-storage/immich-backup/<ts>/) is identical
#    if you prefer restoring from the node instead.
NAS=192.168.1.136
RU=$(kubectl get secret -n backup-replication nas-rsync-credentials -o jsonpath='{.data.rsync-user}' | base64 -d)
RP=$(kubectl get secret -n backup-replication nas-rsync-credentials -o jsonpath='{.data.rsync-password}' | base64 -d)
# list available backups (newest last), then pick one:
RSYNC_PASSWORD="$RP" rsync --port=50555 --list-only "rsync://${RU}@${NAS}/akhozya-pool1/backups/homelab/immich/"
TS=20260714_100910   # <-- the dir you picked

# 1) Fence writes, then WAIT for the server pod to actually terminate — `scale` is async,
#    and a still-running pod would write into a half-restored tree. Suspend the HelmRelease
#    first: its drift detection would scale the server back up mid-restore.
flux suspend helmrelease immich -n immich
kubectl -n immich scale deploy/immich-server --replicas=0
kubectl -n immich wait --for=delete pod \
  -l app.kubernetes.io/instance=immich,app.kubernetes.io/name=server --timeout=120s

# 2) On the NAS (akhozya owns /home/akhozya): verify SHA, THEN clear + extract — all in ONE
#    guarded chain (`set -e` + `&&`) so a failed verify (or unset $TS) never reaches the
#    delete. The tar's top level is the library's own subdirs (library/ thumbs/
#    encoded-video/ upload/ profile/), so extract -C the library dir. `-mindepth 1 -delete`
#    clears contents INCLUDING dotfiles (immich's .immich markers) while preserving the dir
#    inode (see gotcha). ${TS:?} aborts locally if you forgot to set TS.
POOL="/zettos/pool/1/teams/akhozya-pool1/DATA/akhozya-pool1/backups/homelab/immich/${TS:?set TS to the chosen backup dir first}" && \
ssh zl-nas "set -e; cd '$POOL' && sha256sum -c immich-library.tar.sha256 && \
            find /home/akhozya/immich/library -mindepth 1 -delete && \
            tar -xf '$POOL/immich-library.tar' -C /home/akhozya/immich/library"

# 3) Fix perms: the library subtrees are setgid group-writable (drwxrwsr-x) so the
#    server pod (runAsGroup 1000 = group zettos-admins) can write.
ssh zl-nas "chgrp -R zettos-admins /home/akhozya/immich/library && \
            find /home/akhozya/immich/library -type d -exec chmod 2775 {} +"

# 4) Bring immich back up, then verify the mount + DB↔disk. Run this step only once the
#    library holds complete data: both the scale and the resume start the server. The
#    HelmRelease stays suspended until this resume.
kubectl -n immich scale deploy/immich-server --replicas=1
flux resume helmrelease immich -n immich
kubectl -n immich exec deploy/immich-server -- sh -c 'ls /data/library >/dev/null && echo "library mounted"'
```

| Gotcha | Detail |
|---|---|
| virtiofs follows the directory's inode | `immich-vm` holds the library directory open, so extract **in place**: clear its contents with `find library -mindepth 1 -delete`, then `tar -x -C library/`. The inode stays the same and the guest sees the new files at once. If you swap the directory instead (`mv library library.bad; mv library.new library`), the guest keeps seeing the old directory's inode until the VM is cold-cycled with `virsh shutdown --mode acpi` then `virsh start`. Never `virsh reboot`, `reset` or `destroy`: the GPU reset bug crashes the NAS host. |
| Stop Immich first | Step 1 stops the server; without it, Immich writes thumbnails and uploads during the restore. |

### Step 8: Check the apps

```bash
# All pods running
kubectl get pods -A

# Test apps
curl -I https://authentik.h0melab.work
curl -I https://grafana.h0melab.work
curl -I https://immich.h0melab.work

# Test OIDC login on all apps
```

## Configuration rollback (Git tags)

This is not a data restore. If a GitOps change, rather than lost data, breaks the cluster, roll
the configuration back to a known-good commit. Before a large multi-commit infrastructure or
security change, the owner creates a signed annotated tag (`pre-<name>-<date>`), so there is a
stable point to return to.

| Tag | What it marks |
|---|---|
| `pre-ultrareview-2026-07-03` | The state before the fix waves of the 2026-07-03 ultrareview (52 findings) |

```bash
# Inspect a handle
git show pre-ultrareview-2026-07-03 --stat

# Roll config back (only if no downstream collaborator commits since the tag)
git reset --hard pre-ultrareview-2026-07-03
git push --force-with-lease origin main
# Flux fetches main every 5 min and applies the reverted manifests (to force it: flux reconcile source git flux-system)
```

Create a new tag before the next large change:

```bash
git tag -a pre-<name>-$(date +%Y-%m-%d) -m "Baseline before <description>"
git push origin pre-<name>-$(date +%Y-%m-%d)
# NOTE: must be annotated (-a) — lightweight tags fail under [tag] gpgsign = true
```

## Checks after a recovery

```bash
# All resources
kubectl get all -A

# Flux
kubectl get kustomization -A
kubectl get helmrelease -A

# Certificates
kubectl get certificate -A

# Ingresses
kubectl get ingress -A

# Access URLs
# - https://grafana.h0melab.work
# - https://am.h0melab.work
# - https://authentik.h0melab.work
# - https://immich.h0melab.work
# - https://linkwarden.h0melab.work
# - https://paperless.h0melab.work
# - https://n8n.h0melab.work
```

## What comes back, and how

| How | What |
|---|---|
| Flux, after bootstrap | every Kubernetes manifest (Deployments, Services, Ingresses), every Helm release, NetworkPolicies, RBAC, ConfigMaps, alert rules, Grafana dashboards, Loki and Alloy |
| The secret backup scripts, before Flux | the SOPS age key (without it Flux cannot decrypt anything), every app secret, the OIDC secrets for Authentik sign-in (7 apps and Grafana), database credentials, infrastructure secrets (Cloudflare), monitoring credentials, backup replication credentials |
| The data backups on the NAS, using the procedures above | every PostgreSQL app database; MySQL `homeassistant`, `uptimekuma`, `pricebuddy`; CouchDB `obsidian-personal`; the 14 PVCs; the Immich library |
| By hand, once | DNS A records for `*.h0melab.work`, only if the node IPs changed. Firewall rules need nothing: the Ansible role applies them in step 1. |

## Practices

| Practice | Detail |
|---|---|
| Encrypt the secret backups | keep `.backup/secrets/` output on encrypted storage |
| Rotate after a recovery | rotate the sensitive tokens once the cluster is back |
| Drill | run a restore drill regularly. There is no staging cluster, so restore into scratch databases (the CouchDB Job's `-drill` suffix) or on spare hardware. A scratch namespace alone is not enough: the volume restores write to `hostPath` directories on the node and the Immich restore writes to the NAS library, both shared with production. |
| Keep this page current | update it when you add a secret or a service |
| Keep an offline copy | the backup scripts and the secrets, offline (USB, password manager) |

## If something fails

| Check | Command |
|---|---|
| Flux events | `flux events` |
| Pod logs | `kubectl logs -n <namespace> <pod>` |
| Secrets present | `kubectl get secrets -A` |
| Reconciliation | `flux get kustomizations -A` |
