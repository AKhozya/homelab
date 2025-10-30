# Database Architecture Documentation

## Overview

This document explains the intentional architecture decisions for the homelab database infrastructure, specifically regarding single-instance deployments for Redis and CouchDB.

---

## Single Instance Databases

### Redis (Cache & Session Store)

**Current Configuration**: Single instance
**Status**: ✅ **Intentional design decision for homelab environment**

#### Configuration Details
- **Replicas**: 1 (StatefulSet)
- **Storage**: 5Gi PVC (local-path)
- **Persistence**: RDB snapshots enabled (`--save 60 1`)
  - Snapshots every 60 seconds if at least 1 key changed
  - Automatic crash recovery from RDB file
- **Memory**: 256MB with `allkeys-lru` eviction policy
- **Security**: ACL-based authentication (3 users: admin, paperless, immich)
- **Monitoring**: redis-exporter sidecar for Prometheus metrics

#### Persistence Strategy
```yaml
args:
  - --save "60" "1"  # RDB snapshots every 60s if ≥1 key changed
  - --maxmemory 256mb
  - --maxmemory-policy allkeys-lru
```

#### Consumers
- **Paperless-NGX**: Session storage, task queue (Celery)
- **Immich**: Job queue, cache

---

### CouchDB (Obsidian Sync)

**Current Configuration**: Single instance cluster
**Status**: ✅ **Intentional design decision for homelab environment**

#### Configuration Details
- **Cluster Size**: 1
- **Storage**: 30Gi PVC (local-path)
- **Persistence**: Immediate writes (`delayed_commits: false`)
  - Zero data loss on crashes (slower, but safer)
  - Automatic compaction at 70% DB fragmentation
- **Backups**: Daily CronJob (3:05 AM, 30-day retention)
- **Security**:
  - Admin authentication required
  - CORS configured for Obsidian clients
  - Rate limiting: 100 req/sec per connection
- **Monitoring**: Built-in metrics endpoint

#### Persistence Strategy
```yaml
couchdbConfig:
  couchdb:
    delayed_commits: "false"  # Immediate writes for safety
  compactions:
    _default: "[{db_fragmentation, \"70%\"}, {view_fragmentation, \"60%\"}]"
```

#### Backup Strategy
- **Schedule**: Daily at 3:05 AM (after PostgreSQL backups)
- **Retention**: 30 days
- **Location**: `/mnt/k8s-storage/backups/couchdb/`
- **Method**: `curl -X POST http://couchdb:5984/_replicate` to backup database

#### Consumers
- **Obsidian**: Note synchronization and versioning

---

## Risk Assessment

### Risks of Single Instance Architecture

| Risk | Impact | Probability | Severity |
|------|--------|-------------|----------|
| Pod failure | Temporary service unavailability (1-2 min restart) | Medium | **LOW** |
| Node failure | Extended downtime until node recovery | Low | **MEDIUM** |
| Data corruption | Potential data loss between backups | Very Low | **MEDIUM** |

### Why Single Instance is Acceptable for Homelab

#### 1. Personal Use Case
- **Users**: 1 person (homelab owner)
- **Availability**: 99% uptime acceptable for personal use
- **Traffic**: Low volume, non-critical applications
- **SLA**: No formal SLA requirements

#### 2. Data Characteristics
- **Redis**:
  - Cache data (ephemeral, can be rebuilt)
  - Session storage (1-2 hour timeout acceptable)
  - Job queues (retry mechanisms in apps)

- **CouchDB**:
  - Obsidian notes (backed up daily)
  - Local Obsidian vault acts as secondary backup
  - Conflict resolution handles sync issues

#### 3. Cost-Benefit Analysis
- **HA Complexity**: Redis Sentinel/Cluster or CouchDB 3-node cluster adds significant complexity
- **Resource Usage**: ~2GB RAM + 2 CPU cores for HA setup (40% increase)
- **Maintenance**: 3x deployment/update complexity, network policies, quorum management
- **Benefit**: Marginal (~10 min/month reduced downtime)

#### 4. Adequate Safeguards in Place

**Persistence**:
- ✅ Redis: RDB snapshots every 60s
- ✅ CouchDB: Immediate writes, daily backups

**Recovery Time**:
- ✅ Pod restart: 30-90 seconds
- ✅ Data restore from backup: 5-10 minutes

**Monitoring**:
- ✅ Prometheus metrics for both services
- ✅ Liveness/readiness probes
- ✅ Alerting for pod failures

---

## PostgreSQL Architecture

PostgreSQL uses a **2-node HA configuration** with CloudNativePG:
- **Primary**: worker-node
- **Replica**: control-plane node (required anti-affinity)
- **Justification**:
  - PostgreSQL stores **critical application data** (cannot be rebuilt)
  - 16 apps depend on it (vs. 2 apps for Redis, 1 for CouchDB)
  - RPO requirement: < 1 minute (vs. 1-60 minutes acceptable for Redis/CouchDB)
  - Automatic failover prevents extended outages

**Key Difference**: PostgreSQL data is **irreplaceable** without backups, while Redis/CouchDB data is either:
- Ephemeral (cache)
- Recoverable from application state (queues)
- Backed up externally (Obsidian vault)

### PgBouncer Connection Pooling

**Status**: ✅ **Standardized across all applications**

#### Configuration
- **Pooler**: `main-postgres-rw-pooler.databases.svc.cluster.local`
- **Pool Mode**: Transaction pooling (works with most apps)
- **Instances**: 3 (matches PostgreSQL HA instances)
- **Connection Limits**:
  - Max client connections: 75
  - Default pool size: 20 connections per user/db
  - Reserve pool: 5 connections for emergencies

#### Application Usage Pattern

**Init/Setup/Provision Jobs** → Direct connection (`main-postgres-rw`)
- DDL operations (CREATE TABLE, ALTER, migrations)
- Database initialization (CRD waiting)
- One-time setup tasks
- Examples: linkding migrations, immich admin-setup, mealie user-provision

**Application Deployments** → PgBouncer pooler (`main-postgres-rw-pooler`)
- Normal CRUD operations
- Transaction pooling compatible
- Connection pooling prevents exhaustion
- Examples: linkding, mealie, n8n, wallabag, immich, authentik, paperless

#### Benefits
- **Connection Efficiency**: Reuses PostgreSQL connections across requests
- **Resource Protection**: Prevents connection exhaustion (max 75 clients vs. PostgreSQL limit)
- **Automatic Failover**: Pooler tracks primary/replica changes
- **Transaction Isolation**: Each client transaction gets isolated connection from pool

---

## When to Reconsider Single Instance

Consider migrating to HA architecture if:

1. **Multi-user deployment**: Multiple users relying on services
2. **Critical workflows**: Redis/CouchDB become critical dependencies
3. **SLA requirements**: Need < 99.9% uptime guarantees
4. **Compliance**: Regulatory requirements for data availability
5. **Scale**: Traffic patterns require load balancing

For homelab use: **Current architecture is optimal.**

---

## Migration Path (If Needed)

### Redis HA (Future)
```yaml
# Redis Sentinel (3 nodes: 1 master + 2 replicas)
clusterSize: 3
sentinel:
  enabled: true
  quorum: 2
```

### CouchDB HA (Future)
```yaml
# CouchDB Cluster (3 nodes for quorum)
clusterSize: 3
persistentVolume:
  enabled: true
  size: 30Gi  # Per node (90Gi total)
```

**Estimated effort**: 4-6 hours per service
**Resource increase**: +2GB RAM, +2 CPU cores
**Priority**: P3-LOW (defer until homelab requirements change)

---

## References

- **PostgreSQL Architecture**: `infrastructure/configs/base/databases/postgres/cluster.yaml`
- **Redis Configuration**: `infrastructure/controllers/base/databases/redis/statefulset.yaml`
- **CouchDB Configuration**: `infrastructure/controllers/base/databases/couchdb/release.yaml`
- **Backup Strategy**: `docs/BACKUP_STRATEGY.md`
- **Comprehensive Review**: `docs/COMPREHENSIVE_CODEBASE_REVIEW.md` (Task #22)
