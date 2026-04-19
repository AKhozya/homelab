# MySQL Operator Analysis: Percona Operator Brittleness

**Analysis Date**: 2025-12-17
**Operator**: Percona Operator for MySQL (PS) v1.0.0
**Cluster Type**: Async Replication (2 replicas)
**Components**: MySQL 8.4.6, Orchestrator 3.2.6, HAProxy 2.8.15

---

## Executive Summary

Percona Operator for MySQL shows recurring brittleness in recovery scenarios. Manages day-to-day OK, but manual intervention often needed during:
- Pod restarts
- Node failures
- Clone operations
- Replication topology changes

**Recommendation**: Keep current setup + documented manual recovery. Consider MOCO operator if issues persist.

---

## Issues Encountered

### 1. Clone Lock File Not Cleaned Up

**Symptom**: After clone completes, `pt-heartbeat` sidecar stuck waiting.

**Root Cause**: Clone creates `/var/lib/mysql/clone.lock` but doesn't always remove after completion.

**Impact**: pt-heartbeat never starts → replication lag monitoring broken.

**Manual Fix**:
```bash
kubectl exec -n databases main-mysql-mysql-X -c mysql -- rm -f /var/lib/mysql/clone.lock
kubectl delete pod -n databases main-mysql-mysql-X  # Restart to pick up changes
```

**Operator Fix Needed**: auto-cleanup clone.lock when MySQL healthy + replicating.

---

### 2. Stale IP Addresses in Operator Cache

**Symptom**: Operator logs `dial tcp 10.42.X.X:33062: connect: connection refused` for old pod IPs.

**Root Cause**: Pods recreated → new IPs. Operator caches old IPs.

**Impact**: Operator can't communicate with MySQL pods → status updates fail.

**Manual Fix**:
```bash
kubectl rollout restart deployment -n databases percona-server-mysql-operator
```

**Operator Fix Needed**: better pod IP tracking + cache invalidation on pod recreation.

---

### 3. Read-Only State Not Automatically Set

**Symptom**: After recovery, both MySQL nodes writable OR both read-only.

**Root Cause**: MySQL defaults `read_only=ON` on restart for safety. Operator/Orchestrator doesn't always correct.

**Impact**:
- Primary stuck read-only → apps fail
- Replica writable → split-brain risk

**Manual Fix**:
```bash
# On PRIMARY (should be writable):
SET GLOBAL read_only=0; SET GLOBAL super_read_only=0;

# On REPLICA (should be read-only):
SET GLOBAL read_only=1; SET GLOBAL super_read_only=1;
```

**Operator Fix Needed**: Orchestrator should enforce read_only based on topology.

---

### 4. Errant GTID Transactions

**Symptom**: Replica has transactions not on primary.

**Root Cause**: Replica briefly writable (before read_only set) + accepted writes.

**Impact**: Replication breaks → replica can't sync.

**Manual Fix**:
```bash
# Option 1: Re-clone replica from primary
kubectl delete pod -n databases main-mysql-mysql-1

# Option 2: Reset GTIDs (data loss risk)
# Not recommended for production
```

**Prevention**: Ensure replicas always read_only before apps connect.

---

### 5. HAProxy Config Not Updated

**Symptom**: HAProxy only routes to one server after topology change.

**Root Cause**: Operator may not update HAProxy config after pod recreation.

**Impact**: Load balancing broken → connections fail.

**Manual Fix**:
```bash
kubectl delete pod -n databases main-mysql-haproxy-0 main-mysql-haproxy-1
```

**Operator Fix Needed**: HAProxy config reconciled on topology change.

---

### 6. Orchestrator Not Recognizing Topology

**Symptom**: Orchestrator shows `"IsCoMaster": true` both nodes (circular replication).

**Root Cause**: After failures, Orchestrator detects wrong topology.

**Impact**: Failover decisions may be incorrect.

**Manual Fix**: Usually resolves after pods healthy + replication established.

---

## Known Operator Issues (GitHub)

### Issue #1099: Readiness Probe Causes Infinite Restart Loop
- **Status**: Open
- **Desc**: During recovery, MySQL status = `RECOVERING`. Readiness probe treats as unhealthy → restart.
- **Impact**: Cluster can't recover from certain failures.
- **Workaround**: None (needs operator fix).

### Issue #1097: Endless Status Update Failures
- **Status**: Open
- **Desc**: Operator repeatedly fails to update CR status.
- **Impact**: Stale status in kubectl, reconciliation issues.
- **Workaround**: Restart operator deployment.

---

## Configuration Recommendations

### Resilience Configuration (Applied 2025-12-17)

```yaml
mysql:
  autoRecovery: true
  clusterType: async
  size: 2
  gracePeriod: 30

  # Environment variables for longer timeouts during clone/recovery
  env:
    - name: BOOTSTRAP_CLONE_TIMEOUT
      value: "7200"  # 2 hours (default 3600s)
    - name: BOOTSTRAP_READ_TIMEOUT
      value: "3600"  # 1 hour
    - name: BOOTSTRAP_WRITE_TIMEOUT
      value: "3600"  # 1 hour

  # More lenient probes to handle recovery scenarios
  startupProbe:
    failureThreshold: 1
    timeoutSeconds: 43200  # 12 hours for clone
  readinessProbe:
    failureThreshold: 6    # Increased from 3
    periodSeconds: 10      # Increased from 5
  livenessProbe:
    failureThreshold: 6    # Increased from 3
    initialDelaySeconds: 300  # 5 min for recovery

orchestrator:
  enabled: true
  size: 3  # One per node for HA

proxy:
  haproxy:
    enabled: true
    size: 2
```

### Key Configuration Changes

| Setting | Default | New Value | Reason |
|---------|---------|-----------|--------|
| BOOTSTRAP_CLONE_TIMEOUT | 3600s | 7200s | Prevent clone timeouts, large data |
| readinessProbe.failureThreshold | 3 | 6 | Tolerance during recovery |
| livenessProbe.failureThreshold | 3 | 6 | Prevent premature pod kills |
| livenessProbe.initialDelaySeconds | 15 | 300 | Time for recovery |

### Known Limitations

1. **orchestrator.configuration field** — in CRD but NOT implemented by operator v1.0.0
   - Custom Orchestrator settings (RecoveryPeriodBlockSeconds, etc.) can't be applied
   - Feature request: https://github.com/percona/percona-server-mysql-operator/issues

2. **Monitoring alerts** — recommend adding:
   - Replication lag > 30s
   - Both nodes read_only or writable
   - Clone ops > 10 min
   - pt-heartbeat container not running

3. **Daily backup verification** — backups = safety net

---

## Alternative Operators Considered

### 1. MOCO (Cybozu)
- **Pros**:
  - Most CloudNativePG-like
  - Single CRD, simpler
  - Active dev
- **Cons**:
  - Less mature than Percona
  - Smaller community
- **Verdict**: Best alt if Percona issues persist

### 2. Oracle MySQL Operator
- **Pros**:
  - Official Oracle support
  - Group Replication (sync)
- **Cons**:
  - Past brittleness with GR
  - Complex RBAC
  - Already migrated away
- **Verdict**: Not recommended (past experience)

### 3. Bitpoke MySQL Operator
- **Pros**:
  - Simple async replication
  - Lightweight
- **Cons**:
  - Less maintained
  - Fewer features
- **Verdict**: Possible fallback

---

## Recovery Runbook

### Scenario: Cluster Won't Recover After Node Failure

1. **Check cluster status**:
   ```bash
   kubectl get ps main-mysql -n databases -o jsonpath='{.status.state}'
   ```

2. **Check pod status**:
   ```bash
   kubectl get pods -n databases -l app.kubernetes.io/instance=main-mysql
   ```

3. **Check operator logs**:
   ```bash
   kubectl logs -n databases deployment/percona-server-mysql-operator --tail=100
   ```

4. **Stale IPs**:
   ```bash
   kubectl rollout restart deployment -n databases percona-server-mysql-operator
   ```

5. **MySQL pods stuck in clone**:
   ```bash
   kubectl exec -n databases main-mysql-mysql-X -c mysql -- rm -f /var/lib/mysql/clone.lock
   kubectl delete pod -n databases main-mysql-mysql-X
   ```

6. **Verify topology after recovery**:
   ```bash
   # Check PRIMARY (should be read_only=0)
   kubectl exec -n databases main-mysql-mysql-0 -c mysql -- mysql -uroot -p... -e "SELECT @@read_only"

   # Check REPLICA (should be read_only=1)
   kubectl exec -n databases main-mysql-mysql-1 -c mysql -- mysql -uroot -p... -e "SELECT @@read_only"
   ```

7. **Fix read_only**:
   ```bash
   # On PRIMARY:
   SET GLOBAL read_only=0; SET GLOBAL super_read_only=0;

   # On REPLICA:
   SET GLOBAL read_only=1; SET GLOBAL super_read_only=1;
   ```

---

## Conclusion

Percona Operator for MySQL functional but needs manual intervention in failures. Homelab with:
- Daily backups (3:15 AM, 30-day retention)
- Low write frequency
- Acceptable downtime (min-hours)

Current setup adequate. Keep runbook handy.

**Future**: If manual interventions > 1/month → evaluate MOCO operator.

---

**Last Updated**: 2025-12-17
**Author**: Automated analysis based on incident investigation
