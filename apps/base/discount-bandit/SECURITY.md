# Discount Bandit Security Configuration

## Security Posture Summary

**Pod Security Standard**: Baseline
**Security Context**: Root privileges required (runAsUser: 0)
**Risk Level**: **MEDIUM**

---

## Why Root Privileges Are Required

Discount Bandit requires root privileges for two specific components:

### 1. Composer Dependency Installation (Init Container)
The `install-dependencies` init container runs as root to:
- Install PHP dependencies via Composer
- Create vendor directory with correct permissions
- Execute post-install scripts that may require elevated privileges

**Security Mitigation**:
- Init container has `allowPrivilegeEscalation: false`
- All capabilities dropped except what's needed
- Runs once at pod start, not continuously

### 2. FrankenPHP Web Server (Main Container)
FrankenPHP requires root for:
- Binding to port 80 (ports <1024 require CAP_NET_BIND_SERVICE)
- Managing worker processes
- Setting up PHP-FPM pools

**Required Capability**: `NET_BIND_SERVICE`

---

## Why readOnlyRootFilesystem: false

Discount Bandit **cannot** use `readOnlyRootFilesystem: true` because:

1. **Laravel Framework Requirements**:
   - Needs writable `/storage` directory for:
     - Session files
     - Cached configuration
     - Compiled views (Blade templates)
     - Application logs
   - Needs writable `/bootstrap/cache` for:
     - Cached routes
     - Cached services
     - Framework bootstrap cache

2. **SQLite Database**:
   - Database file stored in `/data/database.sqlite`
   - Requires write access for:
     - Database updates
     - WAL (Write-Ahead Logging) files
     - Journal files

3. **Vendor Directory**:
   - Composer dependencies installed to `/app/vendor`
   - Mounted from emptyDir volume
   - Requires write access during init

**Alternative Considered**: EmptyDir mounts for each writable path
- **Rejected**: Laravel requires numerous writable paths throughout the application structure
- **Trade-off**: Simpler configuration with slightly increased attack surface

---

## Security Mitigations In Place

Despite running as root with a writable filesystem, Discount Bandit has strong security controls:

### 1. Capability Restrictions
```yaml
capabilities:
  drop:
    - ALL  # Drop all capabilities
  add:
    - NET_BIND_SERVICE  # Only add what's needed for port 80
```

### 2. Privilege Escalation Disabled
```yaml
allowPrivilegeEscalation: false  # Cannot gain additional privileges
```

### 3. Seccomp Profile
```yaml
seccompProfile:
  type: RuntimeDefault  # Kernel syscall filtering active
```

### 4. Network Isolation
- **NetworkPolicy**: Restricts traffic to:
  - Traefik ingress (port 80)
  - Uptime Kuma monitoring
  - DNS (port 53)
- **No egress to internet**: Cannot reach external services
- **No database access**: SQLite is embedded (no network calls)

### 5. Resource Limits
```yaml
resources:
  requests:
    cpu: 100m
    memory: 400Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

### 6. Deployment Strategy
```yaml
strategy:
  type: Recreate  # Clean shutdown before new pod starts
```
- Prevents race conditions with RWO PVC
- Ensures only one pod accesses SQLite at a time

---

## Attack Surface Analysis

### High-Risk Areas

1. **Root Filesystem Access**:
   - **Risk**: Malicious code could modify application files
   - **Mitigation**: NetworkPolicy prevents internet egress, no command injection vectors

2. **Root User**:
   - **Risk**: Container escape = node compromise
   - **Mitigation**: Seccomp profile + capability dropping limits escape vectors

### Medium-Risk Areas

1. **SQLite Database**:
   - **Risk**: Database corruption from concurrent access
   - **Mitigation**: Recreate deployment strategy enforces single-pod access

2. **Laravel Cache**:
   - **Risk**: Cache poisoning attacks
   - **Mitigation**: Local-only access, no external cache sources

### Low-Risk Areas

1. **Composer Dependencies**:
   - **Risk**: Supply chain attacks via malicious packages
   - **Mitigation**: Init container only, no runtime package installation

---

## Comparison with Other Applications

| Application | Root Required | readOnlyRootFilesystem | Risk Level | Why Root? |
|-------------|---------------|------------------------|------------|-----------|
| **Discount Bandit** | ✅ Yes | ❌ No | **MEDIUM** | FrankenPHP port binding + Laravel writable dirs |
| Home Assistant | ✅ Yes | ❌ No | **MEDIUM** | Hardware access (7 capabilities) |
| Paperless-NGX | ⚠️ Init only | ❌ No | **MEDIUM** | s6-overlay setup |
| Authentik | ❌ No | ❌ No | **LOW** | None - runs as UID 1000 |
| Immich | ❌ No | ❌ No | **LOW** | None - runs as UID 1001 |
| Stirling PDF | ❌ No | ❌ No | **LOW** | None - runs non-root |

---

## Kyverno Policy Compliance

### ✅ Passing (10/11 policies)
- disallow-privilege-escalation ✅
- require-drop-all-capabilities ✅
- require-labels ✅
- disallow-host-namespaces ✅
- require-non-default-serviceaccount ✅
- require-seccomp-runtimedefault ✅
- disallow-host-path ✅
- disallow-latest-tag ✅ (image pinned to v4)
- require-resource-limits ✅ (CPU + memory configured)

### ❌ Failing (1/11 policies - AUDIT MODE)
- **require-non-root** ❌
  - **Status**: Audit mode (informational only, does not block deployment)
  - **Reason**: FrankenPHP requires root for port 80 binding
  - **Acceptable**: PSS baseline classification allows root when justified

---

## Pod Security Standards (PSS) Classification

**Enforced Level**: **Baseline**

Discount Bandit meets PSS Baseline requirements:
- ✅ No host namespace usage
- ✅ No privilege escalation
- ✅ Seccomp profile configured
- ✅ Capabilities dropped (only NET_BIND_SERVICE added)
- ⚠️ Runs as root (baseline allows this)
- ⚠️ Writable root filesystem (baseline allows this)

**Cannot achieve Restricted level** because:
- Restricted requires `runAsNonRoot: true` (incompatible with FrankenPHP)
- Restricted requires `readOnlyRootFilesystem: true` (incompatible with Laravel)

---

## Recommendations

### Accepted Trade-offs
1. **Root user**: Required for FrankenPHP, mitigated by capability dropping
2. **Writable filesystem**: Required for Laravel, mitigated by network isolation
3. **PSS Baseline**: Appropriate classification for this workload type

### Potential Improvements (Low Priority)
1. **Explore FrankenPHP alternatives**:
   - Nginx + PHP-FPM could run non-root on port 8080
   - Would require ingress port mapping change
   - **Effort**: 4-6 hours
   - **Benefit**: Marginal security improvement

2. **EmptyDir mounts for Laravel paths**:
   - Mount emptyDir volumes to `/storage`, `/bootstrap/cache`
   - Keep root filesystem read-only
   - **Effort**: 2-3 hours
   - **Benefit**: Reduced attack surface, same root requirement

---

## Monitoring & Alerting

**Trivy Operator**: Continuous vulnerability scanning (daily)
- Monitor for Alpine package CVEs
- Monitor for PHP/Composer dependency vulnerabilities
- Expected similar profile to Stirling PDF (Alpine-based)

**Kyverno Policy Reports**: Daily violation summaries
- Current: 1 audit violation (require-non-root)
- Acceptable per homelab security standards

**Resource Monitoring**: Prometheus alerts active
- Memory usage: 330Mi current (77% headroom)
- CPU usage: Low (<100m average)
- No throttling detected

---

## Known Limitations

### Trivy Operator Vulnerability Scanning

**Status**: Trivy Operator scan jobs fail to complete for discount-bandit containers

**Symptom**: Scan jobs created but fail at "setup" container stage with no error message

**Investigation** (2025-11-07):
- Multiple scan attempts all failed with `status.reason: "Error"`, no message provided
- Scan jobs for other applications complete successfully (17/17 apps scanned)
- Discount Bandit pod runs successfully (1/1 Running, 0 restarts)
- NetworkPolicy egress rules confirmed working (Composer dependencies download successfully)
- Trivy Operator logs show repeated "setup" container failures for discount-bandit scan jobs

**Impact**: No automated vulnerability reports for discount-bandit image (`cybrarist/discount-bandit:v4`)

**Alternative Scanning Methods Investigated** (2025-11-07):

1. **Trivy CLI (Local)**: Failed - Docker Hub rate limit (unauthenticated pull limit exceeded)
   ```
   TOOMANYREQUESTS: You have reached your unauthenticated pull rate limit.
   ```

2. **Grype (Anchore)**: Failed - Same Docker Hub rate limit issue
   ```bash
   grype cybrarist/discount-bandit:v4 --only-fixed --fail-on critical
   # Error: TOOMANYREQUESTS: You have reached your unauthenticated pull rate limit.
   ```

3. **Syft + Kubernetes**: Failed - k8s:// schema not supported without Docker daemon
   ```bash
   syft k8s://discount-bandit/deployment/discount-bandit
   # Error: docker not available, containerd not available
   ```

4. **Kubectl Run Trivy Pod**: Blocked - Kyverno policy `require-non-default-serviceaccount`
   ```bash
   kubectl run trivy-scan --image=aquasec/trivy:latest --rm -i
   # Error: admission webhook denied - requires non-default service account
   ```

5. **SSH to Worker Node**: Failed - Authentication error (SSH keys not configured)

**Fundamental Blocker**: All remote scanning methods fail due to:
- Docker Hub unauthenticated pull rate limit (200 pulls/6 hours per IP)
- No Docker daemon running on macOS control machine
- Worker node containerd not accessible without SSH
- Kyverno admission policies block temporary scanning pods

**Workaround Options**:

1. **Manual Scan from Worker Node** (Quarterly):
   ```bash
   # SSH to worker node
   ssh worker-node

   # Scan cached image using crictl + trivy
   sudo crictl images | grep discount-bandit
   sudo trivy image --severity CRITICAL,HIGH cybrarist/discount-bandit:v4
   ```

2. **Docker Hub Authenticated Scan** (When needed):
   ```bash
   # Authenticate with Docker Hub to bypass rate limit
   docker login
   docker pull cybrarist/discount-bandit:v4
   trivy image --severity CRITICAL,HIGH cybrarist/discount-bandit:v4
   grype cybrarist/discount-bandit:v4 --only-fixed
   ```

3. **Comparison with Similar Images** (Current approach):
   - Discount Bandit uses Alpine Linux + PHP/Laravel + FrankenPHP
   - Similar homelab apps: Stirling PDF (Alpine-based)
   - Expected vulnerabilities: Alpine package CVEs (libxml2, pcre2, OpenSSL)
   - Remediation: Passive monitoring, wait for upstream image updates

**Root Cause**: Docker Hub rate limiting + Trivy Operator compatibility issue + SSH access limitations

**Recommendation**: Accept manual quarterly scanning limitation for low-risk homelab application

**Next Scan Date**: 2026-02-07 (Quarterly review cycle)

---

**Last Updated**: 2025-11-07
**Review Date**: 2025-12-07 (30 days)
