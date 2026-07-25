# Homelab Disaster Recovery Guide

This is the disaster-recovery runbook for the homelab K3s cluster — the step-by-step procedure to rebuild from nothing if the cluster is lost. It pairs the scripts in this directory (encrypted secret backup/restore) with the data backups described in `docs/BACKUP_STRATEGY.md`, and walks the full sequence: stand up a fresh cluster, restore secrets, bootstrap GitOps, then restore databases and volumes from backup. The same encryption and ordering rules below apply whether you are recovering one database or the whole fleet.

## Important: Secret Backups Are Encrypted

**All secrets backups ENCRYPTED with GPG AES256!**

- **Encrypted:** all backups auto GPG-encrypted
- **Secure:** unencrypted secrets dir removed after encryption
- **Gitignored:** `.backup/` in `.gitignore`
- **No Default:** no default passphrase — MUST set own
- **Passphrase:** store in 1Password securely!

## Backup Process

### 1. Create Encrypted Backup (run monthly)

```bash
cd .backup
chmod +x secrets-backup.sh
./secrets-backup.sh

# Script prompts for passphrase interactively
# Or set env var to skip prompt:
# export GPG_PASSPHRASE='your-very-secure-passphrase'

# WARNING: Store passphrase in 1Password — need to decrypt!
```

**Output:** `secrets-backup-YYYYMMDD_HHMMSS.tar.gz.gpg` (encrypted archive)

### 2. Decrypt Backup (optional — auto during restore)

**Note:** `secrets-restore.sh` auto-decrypts, manual decrypt rarely needed.

For manual inspection:

```bash
# Interactive (prompts for passphrase)
gpg --decrypt secrets-backup-20251030_120000.tar.gz.gpg | tar -xzf - -C .

# Non-interactive (env var)
export GPG_PASSPHRASE='your-passphrase'
gpg --decrypt --batch --passphrase-file <(echo "$GPG_PASSPHRASE") \
  secrets-backup-20251030_120000.tar.gz.gpg | tar -xzf - -C .
```

Extracts to `secrets/` dir with all secret JSON files.

Extracts **ALL** secrets needed for complete cluster rebuild:

**Critical Infrastructure:**
- SOPS age encryption key (MOST IMPORTANT — decrypts everything)
- Cloudflare API token (cert-manager DNS-01)
- Cloudflare tunnel credentials + config

**Monitoring:**
- Grafana admin creds
- Alertmanager Telegram bot token

**Databases:**
- Redis passwords (all apps)
- PostgreSQL admin creds + all app DB users
- MySQL cluster secrets + app creds (Uptime Kuma, PriceBuddy)

**Applications:**
- Authentik (SSO + identity)
- Immich (photos)
- Home Assistant
- N8N (workflow automation)
- LinkWarden (bookmarks + read-later)
- Mealie (recipes)
- Paperless-NGX (docs)
- Audiobookshelf
- Uptime Kuma
- Stirling PDF (PDF toolkit)
- HomeHub (family dashboard)
- PriceBuddy (price tracking)
- CouchDB (Obsidian sync)

**Backup Replication:**
- NAS rsync creds (rsync daemon auth)
- Telegram bot token (backup failure notifications)

Files saved to `.backup/secrets/` (gitignored)

### 3. Automated Backups (Already Configured)

**Daily backups auto-configured:**

- **PostgreSQL:** Daily 3:00 AM → `/mnt/k8s-storage/backups/postgres/` (30 day retention)
- **CouchDB:** Daily 3:05 AM → `/mnt/k8s-storage/backups/couchdb/` (30 day retention)
- **MySQL:** Daily 3:15 AM → `/mnt/k8s-storage/backups/mysql/` (30 day retention)
- **Critical PVCs:** Daily 3:10 AM → `/mnt/k8s-storage/backups/pvc/` (30 day retention, bumped from 7d on 2026-05-22)
- **Immich library:** Weekly Sunday 3:00 AM — `immich-backup` (`backup-replication` ns) on **worker-node-2** pulls the NAS-resident library (rsync `personal_folder`) → tar+sha on W2 (`/mnt/extra-storage/immich-backup/`) + push to NAS `akhozya-pool1` pool = 2 copies, keep-2 each (~61G uncompressed). Restore: `docs/BACKUP_STRATEGY.md` §5 (extract in-place onto the NAS — virtiofs inode gotcha).
- **Backup Replication:** Daily 3:30 AM → NAS (30d daily / keep-2 immich, Step 4b prune). W2 safety-net leg removed 2026-07-17.

**Details:** `docs/BACKUP_STRATEGY.md`

**No manual action required** — runs via K8s CronJobs

## Recovery Process

### Full Recovery (from scratch)

#### Step 1: Create Fresh K3s Cluster

**Do NOT run a bare `curl -sfL https://get.k3s.io | sh -`** — that installs an
unpinned k3s WITH bundled Traefik + CoreDNS + helm-controller, which collide with
the Flux-managed ones. K3s config (`config.yaml` + `kubelet.yaml`) is
ansible-owned (`k3s_config` role: disables bundled coredns/traefik/helm-controller,
enables secrets-encryption) and must be in place BEFORE first k3s start.

**Per node, control-plane first:**

```bash
# 1. Bootstrap: ansible stack (CP) + K3s config directory (script is bootstrap-only)
sudo bash docs/scripts/setup-node.sh

# 2. Apply ansible-owned config (k3s config.yaml/kubelet.yaml, firewall, sysctls, ...)
sudo systemctl start node-maintenance-sync.service
sudo systemctl start node-maintenance-config.service
```

**On control-plane node (192.168.1.127):**

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.36.2+k3s1" sh -
sudo cat /var/lib/rancher/k3s/server/node-token
```

**On worker-node (192.168.1.129) and worker-node-2 (192.168.1.126):**

```bash
export K3S_URL=https://192.168.1.127:6443
export K3S_TOKEN=<token-from-control-plane>
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.36.2+k3s1" sh -
```

**Get kubeconfig:**

```bash
# On control-plane
sudo cat /etc/rancher/k3s/k3s.yaml
# Copy to local at ~/.kube/config
# Update server IP to 192.168.1.127
```

#### Step 2: Firewall

Already applied by the ansible `firewall` role in Step 1 (`node-maintenance-config.service`).
No manual `ufw` commands — rules are role-managed, additive, never reset.

#### Step 3: Install Flux CLI

```bash
brew install fluxcd/tap/flux  # macOS
```

#### Step 4: Restore ALL Secrets

**WARNING: Run BEFORE bootstrapping Flux!**

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

Auto-decrypts backup + restores ALL secrets needed for cluster ops.

#### Step 5: Bootstrap Flux

```bash
flux bootstrap github \
  --owner=AKhozya \
  --repository=homelab \
  --path=clusters \
  --personal
```

#### Step 6: Wait for Reconciliation

```bash
# Watch deploy
watch kubectl get pods -A

# Flux status
flux get kustomizations -A
kubectl get helmrelease -A
```

#### Step 7: Restore Databases from Backups

Backups from 2 sources (preference order):
1. **NAS** (192.168.1.136) — full history, rsync daemon port 50555
2. **worker-node** (192.168.1.129) — source cleaned daily, may be empty

**Copy backups from NAS to worker-node:**

Either run rsync directly on worker-node (needs a shell there and the password in your env):
```bash
# Get NAS creds from restored secrets or 1Password
export RSYNC_PASSWORD='<nas-rsync-password>'
rsync -avz --port=50555 \
  rsync://akhozya@192.168.1.136/akhozya-pool1/backups/homelab/ \
  /mnt/k8s-storage/backups/
```

…or run it as a Job, which needs neither node SSH nor the password in your shell — it reads
the existing `nas-rsync-credentials` secret and inherits the namespace's NAS egress policy.
Prefer this when the SSH key is locked in 1Password mid-incident. Set `SUBDIR` to the backup
type you need (`couchdb`, `postgres`, `mysql`, `pvc`); it fetches the newest archive plus its
`.sha256` sidecar. Verified 2026-07-24.

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


**PostgreSQL restore:**
```bash
# Find latest backup
LATEST_BACKUP=$(ls -t /mnt/k8s-storage/backups/postgres/postgres_*.tar.gz | head -1)

# Verify integrity
sha256sum -c ${LATEST_BACKUP}.sha256

# Extract
tar -xzf $LATEST_BACKUP -C /tmp

# Restore each DB by iterating the actual dumps (custom-format, pg_dump -F c) so every
# backed-up database is covered and none are invented. Tarball extracts to /tmp/<TIMESTAMP>/<db>.dump
# (the postgres_ prefix is only on the tarball name, not the inner dir).
DUMP_DIR="/tmp/$(basename "$LATEST_BACKUP" .tar.gz | sed 's/^postgres_//')"
PRIMARY=$(kubectl get pod -n databases -l cnpg.io/cluster=main-postgres,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
for DUMP in "$DUMP_DIR"/*.dump; do
  DB=$(basename "$DUMP" .dump)
  echo "Restoring $DB -> $PRIMARY..."
  # -i streams the node-side dump into the pod; pg_restore reads the custom-format dump from stdin
  kubectl exec -i -n databases "$PRIMARY" -- \
    pg_restore -U postgres -d "$DB" -c --if-exists < "$DUMP"
done
```

**MySQL restore:**
```bash
# Find latest backup
LATEST_MYSQL=$(ls -t /mnt/k8s-storage/backups/mysql/mysql_*.tar.gz | head -1)

# Verify integrity
sha256sum -c ${LATEST_MYSQL}.sha256

# Extract
tar -xzf $LATEST_MYSQL -C /tmp

# Get root password
MYSQL_ROOT_PWD=$(kubectl get secret -n databases mysql-cluster-secrets -o jsonpath='{.data.root}' | base64 -d)

# Restore each DB by iterating the actual dumps. Tarball extracts to /tmp/<TIMESTAMP>/<db>.sql
# (the mysql_ prefix is only on the tarball name, not the per-DB files).
SQL_DIR="/tmp/$(basename "$LATEST_MYSQL" .tar.gz | sed 's/^mysql_//')"
for SQL in "$SQL_DIR"/*.sql; do
  DB=$(basename "$SQL" .sql)
  echo "Restoring $DB..."
  # -i streams the node-side dump in; -h haproxy routes the write to the primary
  kubectl exec -i -n databases main-mysql-mysql-0 -- \
    mysql -h main-mysql-haproxy.databases.svc.cluster.local -uroot -p"${MYSQL_ROOT_PWD}" "$DB" < "$SQL"
done
```

**CouchDB restore:**

> The restore Jobs on this page are applied straight to the cluster rather than committed to
> Git — the one carve-out from the GitOps-only invariant in AGENTS.md, noted there too.
> Committing them is not an option: Flux would re-run a destructive restore on every
> reconcile. They are one-shot, ephemeral, and deleted once complete.

`couchrestore` is NOT in the couchdb image — it ships with `@cloudant/couchbackup` (npm),
the same tool the backup CronJob uses. Run it as a Job that reads the archive straight off
the backup hostPath, mirroring how the backup CronJob reaches it. Admin creds come from the
`couchdb-couchdb` secret, so they never land in shell history or the Job spec. They do reach
the couchrestore child's argv inside the pod — `--url` is the only way to pass credentials,
there are no user/password flags — so they are visible to anything that can read that pod's
process list. The previous version carried the same exposure.

**Status: drilled end-to-end on 2026-07-24.** A full restore of the live Obsidian database
into a scratch target completed — 1505 document revisions, 1479 docs against 1494 live (the
gap is edits made after the 03:05 backup), deleted-doc counts matching exactly at 21.

Four things make a naive `kubectl run` fail here, all found by actually running it — and the
reason the previous version of this runbook could not have worked:

1. **Kyverno denies it.** All 12 ValidatingPolicies are Deny-enforcing. Every field below is
   demanded by one of them: the `app` label (require-labels), requests+limits
   (require-resource-limits), runAsNonRoot (require-non-root), seccompProfile
   (require-seccomp-runtimedefault), drop ALL (require-drop-all-capabilities),
   `allowPrivilegeEscalation: false` (disallow-privilege-escalation), readOnlyRootFilesystem
   (require-readonly-rootfs), and a non-default serviceAccountName
   (require-non-default-serviceaccount → `couchdb-jobs`). The webhook names only the FIRST
   failing policy, so dropping one field gives a single misleading error, not a checklist.
2. **ResourceQuota denies it a second time.** `namespace-quota` on `databases` leaves only
   ~800m CPU free on a running cluster, so a 1-CPU limit is rejected even after Kyverno
   passes. Check headroom first: `kubectl get resourcequota namespace-quota -n databases`.
   In a real full restore the namespace is mostly empty and headroom is ample.
3. **`readOnlyRootFilesystem` breaks npm.** Its default `~/.npm` is unwritable, so
   `npm install` fails and couchrestore ends up simply absent. `HOME` and `npm_config_cache`
   must point into the `/tmp` emptyDir.
4. **The default `--parallelism 5` breaks authentication mid-restore.** See the comment on
   the couchrestore invocation below — this one only shows up after several batches have
   already succeeded, so it looks like a partial success rather than a broken command.

Also: `couchrestore` does NOT create the target database, and this image's busybox wget has
**no `--method` flag** (only `--post-data`/`--post-file`) — so the pre-create uses Node's
built-in `fetch` with an Authorization header. HTTP 412 = already exists = fine.

The Job selects and checksum-verifies the archive itself, so this needs no node SSH — which
matters because the key lives in 1Password and may be unavailable mid-incident.

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

After a drill, drop the scratch databases (they are named `<db>-drill`):
```bash
kubectl exec -n databases couchdb-couchdb-0 -c couchdb -- \
  curl -sS -X DELETE -u "$ADMIN_USER:$ADMIN_PASS" "http://127.0.0.1:5984/<db>-drill"
```


**PVC restore:**

The `pvc-backup` CronJob covers **14** PVCs across 10 namespaces, not the three this section used
to name. Nothing needs a lookup table: local-path names each PV directory
`<pv-uuid>_<namespace>_<pvc-name>`, and the owning workload is derivable from the PVC, so both
are discovered at restore time. Hardcoding either goes stale the moment a PVC is recreated.

Archive layout is `/mnt/k8s-storage/backups/pvc/<timestamp>/<namespace>/<pvc-name>.tar[.gz]`
plus a `.sha256` sidecar. `audiobookshelf-audiobooks` and `audiobookshelf-podcasts` are stored
**uncompressed** (`.tar`) because they hold already-compressed audio; everything else is `.tar.gz`.

Three steps, on two different hosts. Every PV backed up by this job is node-local to
`worker-node`. Run each block whole — each one is `set -e` so a failed step stops before the
next, rather than extracting into a running app or restarting on top of a half-extract.

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

kubectl scale "$WORKLOAD" -n "$NS" --replicas=0
kubectl wait --for=delete pod -l "$SEL" -n "$NS" --timeout=5m
echo "stopped — now run STEP 2 on worker-node"
```

```bash
# --- STEP 2 (on worker-node): verify, set aside, extract. DESTRUCTIVE ---
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
kubectl rollout status "$WORKLOAD" -n "$NS" --timeout=5m
```

**If STEP 2 fails partway**, the original data is untouched under `.pre-restore-*`. Leave the
workload stopped and roll back on the node before restarting anything:

```bash
# --- ROLLBACK (on worker-node) ---
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

Delete the `.pre-restore-*` directory only after the app is verified healthy — it is the
rollback. `audiobookshelf` (4 PVCs) and `stirling-pdf` (3) share one Deployment each: run
STEP 1 once, STEP 2 per PVC with `BACKUP_DIR` pinned, then STEP 3 once.

> **Not drilled.** The discovery block and the PVC→PV→path→workload mapping were verified
> against the live cluster on 2026-07-25 for all 14 PVCs. The extract itself has **not** been
> rehearsed end-to-end, unlike the CouchDB restore above. Run the checksum and `tar -tf` steps
> first; they are the cheap guard against discovering a bad archive after the app is already down.

Immich photos are excluded from PVC backups — they are covered by the weekly `immich-backup`
CronJob (NAS `akhozya-pool1` pool).

#### Step 8: Verify Applications

```bash
# All pods running
kubectl get pods -A

# Test apps
curl -I https://authentik.h0melab.work
curl -I https://grafana.h0melab.work
curl -I https://immich.h0melab.work

# Test OIDC login on all apps
```

## Configuration Rollback (Git Tags)

Distinct from data restore above: when a GitOps change (not a data loss) breaks the
cluster, roll the **config** back to a known-good commit. A signed annotated tag is
created before any large multi-commit infrastructure or security change
(`pre-<name>-<date>`) so there is always a stable point to revert to — these tags
survive many subsequent commits and act as named rollback handles.

**Known rollback handles:**

| Tag | Baseline |
|---|---|
| `pre-ultrareview-2026-05-23` | Last known-good commit before a large round of security and reliability changes (Kyverno enforcement, HelmRelease drift fixes, CSP, priority classes). Primary config-rollback handle. |
| `pre-w7-2026-05-24` | Before the CI gates were added (`validate.yaml`). |
| `pre-w8-2026-05-24` | Before promoting Kyverno policies from Audit to Enforce. |

```bash
# Inspect a handle
git show pre-ultrareview-2026-05-23 --stat

# Roll config back (only if no downstream collaborator commits since the tag)
git reset --hard pre-ultrareview-2026-05-23
git push --force-with-lease origin main
# Flux reconciles the reverted manifests within 60s (or force: fr)
```

Create a new handle before the next large change:

```bash
git tag -a pre-<name>-$(date +%Y-%m-%d) -m "Baseline before <description>"
git push origin pre-<name>-$(date +%Y-%m-%d)
# NOTE: must be annotated (-a) — lightweight tags fail under [tag] gpgsign = true
```

## Verification

After recovery, verify:

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

## What Gets Restored

### Automatically (via GitOps after Flux bootstrap)
- All K8s manifests (deployments, services, ingresses)
- All Helm releases (monitoring, databases, apps)
- NetworkPolicies, RBAC, ConfigMaps
- VMAlert rules (VMRules)
- Grafana dashboards (via ConfigMaps)
- Loki + Alloy log aggregation

### Via Backup Scripts (run BEFORE Flux bootstrap)
- **SOPS age encryption key** (CRITICAL — enables Flux to decrypt secrets)
- **All application secrets** (creds, API keys, env vars)
- **All OIDC integration secrets** (Authentik SSO for 8 apps)
- **Database credentials** (Redis, PostgreSQL users, MySQL cluster + app users)
- **Infrastructure secrets** (Cloudflare tokens, tunnel creds)
- **Monitoring credentials** (Grafana admin, Telegram bot)
- **Backup replication credentials** (NAS rsync creds, Telegram)

### Via Automated Backups (restore from NAS)
- **PostgreSQL databases** — all app DBs backed up daily
- **MySQL databases** — homeassistant, uptimekuma, pricebuddy backed up daily
- **CouchDB databases** — obsidian-personal backed up daily
- **Critical PVCs** — HA, Paperless, Audiobookshelf
- Use restore procedures in `docs/BACKUP_STRATEGY.md`

### Manual Steps Required (one-time)
- **DNS A records** — only if node IPs changed:
  - `*.h0melab.work` records → node IPs
- **Firewall rules** — none: ansible `firewall` role applies them (Step 1)

## Security Best Practices

1. **Encrypt backups:** encrypted storage for `.backup/secrets/`
2. **Rotate creds:** after recovery, rotate sensitive tokens
3. **Test recovery:** periodic restore drill (single env — no staging)
4. **Document changes:** update guide when adding secrets/services
5. **Offline copy:** backup scripts + secrets offline (USB, password manager)

## Support

Issues:
1. Flux events: `flux events`
2. Pod logs: `kubectl logs -n <namespace> <pod>`
3. Secrets exist: `kubectl get secrets -A`
4. Reconciliation: `flux get kustomizations -A`
