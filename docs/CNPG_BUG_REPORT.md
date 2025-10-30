# CNPG Instance Manager Port 8000 Binding Failure on K3s Control-Plane Nodes

## Issue Summary
CNPG instance manager silently fails to bind status port 8000 when running on K3s control-plane nodes. The process logs "Starting webserver :8000 hasTLS=true" but the port never actually binds, with zero error messages.

## Environment
- **CNPG Version**: 1.27.1
- **Kubernetes Distribution**: K3s
- **Node Type**: Control-plane node specifically (worker nodes unaffected)
- **Image**: `ghcr.io/cloudnative-pg/postgresql:18-standard-trixie`
- **Operator Image**: `ghcr.io/cloudnative-pg/cloudnative-pg:1.27.1`

## Cluster Configuration
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: main-postgres
  namespace: databases
spec:
  instances: 2
  imageName: ghcr.io/cloudnative-pg/postgresql:18-standard-trixie
  enableSuperuserAccess: true

  affinity:
    enablePodAntiAffinity: true
    podAntiAffinityType: "required"
    topologyKey: "kubernetes.io/hostname"
    tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule

  resources:
    requests:
      cpu: "250m"
      memory: "512Mi"
    limits:
      cpu: "1000m"
      memory: "2Gi"
  storage:
    size: 10Gi
    storageClass: "local-path"
  monitoring:
    enablePodMonitor: true
```

## Network Policy
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-allow-apps
  namespace: databases
spec:
  podSelector:
    matchLabels:
      cnpg.io/cluster: main-postgres
  policyTypes:
    - Ingress
  ingress:
    # Allow CNPG operator to access status API
    - from:
      - podSelector:
          matchLabels:
            app.kubernetes.io/name: cloudnative-pg
      ports:
      - protocol: TCP
        port: 8000  # CNPG instance manager status API

    # Allow intra-cluster replication
    - from:
      - podSelector:
          matchLabels:
            cnpg.io/cluster: main-postgres
      ports:
      - protocol: TCP
        port: 5432
      - protocol: TCP
        port: 8000
```

## Symptoms
1. **Pod logs show**: `{"msg":"Starting webserver","address":":8000","hasTLS":true}`
2. **But `lsof -i :8000` shows**: Empty (port not listening)
3. **Operator logs show**: `Get "https://10.42.0.140:8000/pg/status": dial tcp 10.42.0.140:8000: connect: connection refused`
4. **Cluster status**: Stuck in "Waiting for the instances to become active"
5. **No error messages**: Complete silent failure

## Behavior
- ✅ **PostgreSQL database (port 5432)**: Works perfectly
- ✅ **Metrics port (9187)**: Works correctly
- ✅ **Localhost port (8010)**: Works correctly
- ❌ **Status port (8000)**: Never binds
- ✅ **Worker node pods**: All ports work, including 8000
- ❌ **Control-plane node pods**: Only port 8000 fails

## Investigation Results

### Working Pod (main-postgres-5 on worker-node)
```
IP: 10.42.1.213
Node: worker-node
Port 8000: ✅ Listening
Operator connectivity: ✅ Success
```

### Failing Pod (main-postgres-6 on control-plane)
```
IP: 10.42.0.140
Node: gmk-k3s-control-plane
Port 8000: ❌ Not listening
Operator connectivity: ❌ Connection refused
```

### Identical Configurations
- ✅ Security contexts identical
- ✅ Seccomp profiles identical (RuntimeDefault)
- ✅ Capabilities identical (all dropped)
- ✅ TLS certificates valid and identical
- ✅ Manager process running with correct flags: `/controller/manager instance run --status-port-tls --log-level=info`
- ✅ Port 8000 not in use by other processes on control-plane node

### Pod Recreation Test
- Deleted and recreated pod multiple times
- Same failure every time (systematic, not transient)
- New IP assigned, same issue persists

## Logs

### Manager Startup (main-postgres-6)
```json
{"level":"info","ts":"2025-10-30T13:49:18.878428275Z","msg":"Starting webserver","address":"localhost:8010","hasTLS":false}
{"level":"info","ts":"2025-10-30T13:49:18.881269313Z","msg":"Starting webserver","address":":8000","hasTLS":true}
{"level":"info","ts":"2025-10-30T13:49:18.881362052Z","msg":"Starting webserver","address":":9187","hasTLS":false}
```

### Port Status
```bash
$ kubectl exec -n databases main-postgres-6 -- lsof -i :8000
# Empty output - port not listening

$ kubectl exec -n databases main-postgres-6 -- netstat -tlnp | grep :8000
# Empty output - port not listening
```

### Operator Logs
```json
{"level":"info","msg":"Cannot extract Pod status","podName":"main-postgres-6","error":"Get \"https://10.42.0.140:8000/pg/status\": dial tcp 10.42.0.140:8000: connect: connection refused"}
{"level":"info","msg":"Waiting for Pods to report HTTP status","podsReportingStatus":["main-postgres-5"],"podsNotReportingStatus":{"main-postgres-6":"connection refused"}}
```

## Impact
- **Database functionality**: ✅ Unaffected (PostgreSQL fully operational)
- **Replication**: ✅ Working correctly
- **Application connectivity**: ✅ All apps connect successfully
- **CNPG operator monitoring**: ❌ Cannot monitor main-postgres-6 health
- **Cluster status**: ❌ Stuck in "Waiting for instances to become active"
- **Flux GitOps health checks**: ⚠️ Timeout (workaround: extended timeout to 120s)

## Workaround
Extended Flux health check timeout from 45s to 120s:
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
spec:
  timeout: 120s  # Extended from 45s
  healthChecks:
    - apiVersion: postgresql.cnpg.io/v1
      kind: Cluster
      name: main-postgres
      namespace: databases
```

## Expected Behavior
Instance manager should successfully bind port 8000 on all nodes, not just worker nodes.

## Questions
1. Is there a known issue with K3s control-plane nodes?
2. Why does port binding fail silently without error messages?
3. Is port 8000 hardcoded, or can it be configured to use a different port?
4. Are there additional debug flags to get more verbose TLS binding logs?

## Request
- Fix the silent failure to provide actionable error messages
- Investigate K3s control-plane node specific binding issues
- Consider making status port configurable as a workaround

---

**Note**: Database is fully functional and this only affects cluster monitoring. We've accepted this state and extended timeout as workaround, but reporting for community awareness and potential fix.
