# Notification Strategy Review

**Date**: 2025-10-18
**Purpose**: evaluate Telegram notifications + determine optimal distribution

---

## Current Notification Setup

### 1. Alertmanager (Prometheus) → Telegram
**Bot**: alertmanager-telegram secret
**Chat ID**: 113452686
**Scope**: infra + app metrics alerts

**Alert Categories**:
- **Node Alerts** (8)
  - NodeDown, KubeletDown, NodeNotReady
  - NodeMemoryPressure, NodeDiskPressure
  - NodeHighCPU, NodeHighMemory, NodeDiskSpaceLow/Critical
  - NodeHighIOWait, NodeNetworkErrors

- **Storage Alerts** (5)
  - PVCUsageHigh/Critical
  - PVCInodeLow, PVCLowAbsoluteSpace
  - PersistentVolumeError

- **Pod Alerts** (6)
  - PodCrashLooping, PodNotReady
  - ContainerOOMKilled, ContainerMemoryNearLimit
  - ContainerCPUThrottling, PodImagePullError

- **Cloudflare Tunnel Alerts** (4)
  - CloudflareTunnelDown, CloudflareTunnelPodNotRunning
  - CloudflareTunnelNoConnections, CloudflareTunnelHighLatency

- **Certificate Alerts** (4)
  - CertificateExpiringSoon/Critical
  - CertificateNotReady, CertificateRenewalFailed

- **Kubernetes Alerts** (7)
  - DeploymentReplicasMismatch, StatefulSetReplicasMismatch
  - DaemonSetNotScheduled, PodsPending
  - KubernetesAPIServerDown, JobFailed
  - CronJobNotScheduled

- **Flux GitOps Alerts** (3)
  - FluxReconciliationFailure
  - FluxSourceNotReady
  - FluxSuspended (info only)

- **Service Alerts** (2)
  - ServiceDown, HighErrorRate

- **Monitoring Health Alerts** (5)
  - PrometheusTargetDown, PrometheusTargetScrapeTooSlow
  - PrometheusTooManyRestarts
  - AlertmanagerConfigInvalid, AlertmanagerNotificationsFailing

**Total**: ~44 Prometheus alert rules

**Repeat Interval**: 12h
**Grouping**: alertname, cluster, service
**Group Wait**: 10s
**Group Interval**: 10s

---

### 2. Flux Notifications → Telegram
**Bot**: alertmanager-telegram secret
**Chat ID**: 113452686
**Scope**: GitOps reconciliation failures

**Alert Name**: "🔄 Flux GitOps Events"
**Severity**: error only
**Event Sources**:
- GitRepository (flux-system ns)
- Kustomization (flux-system ns)
- HelmRelease (all ns)
- HelmRepository (all ns)
- HelmChart (all ns)

**Example Events**:
- Git fetch fails
- Kustomization apply fails
- Helm release fails
- Repo sync issues

---

### 3. Uptime Kuma → Telegram (Not Configured)
**State**: monitors configured, no Telegram yet
**Scope**: HTTP/TCP endpoint availability

**Monitored Services** (14 total):
- External: Homepage, Home Assistant, Grafana, Authentik
- Internal: Uptime Kuma, Wallabag, Mealie, N8N, Linkding, Audiobookshelf
- Infra: Prometheus, Alertmanager, PostgreSQL, Redis

---

## Analysis & Recommendations

### Problem: Overlap & Noise

#### Current Overlaps:
1. **Service Downtime**:
   - Prometheus `ServiceDown` → Telegram
   - Uptime Kuma HTTP fail → (no notification yet)
   - OVERLAP: same issue

2. **Pod/Container Issues**:
   - Prometheus `PodCrashLooping` → Telegram
   - Uptime Kuma HTTP fail → (no notification yet)
   - OVERLAP: same root cause, different symptoms

3. **Flux Issues**:
   - Flux Alert `FluxReconciliationFailure` → Telegram
   - Prometheus `FluxReconciliationFailure` → Telegram
   - OVERLAP: duplicate from two systems

---

## Recommended Strategy

### KEEP in Alertmanager (Prometheus)
**Rationale**: metrics-based alerts Uptime Kuma can't detect

1. **Resource Pressure** (CPU, Mem, Disk, I/O)
   - NodeHighCPU, NodeHighMemory, NodeDiskSpaceLow
   - ContainerMemoryNearLimit, ContainerCPUThrottling
   - Keep: need time-series metrics

2. **Storage Issues** (PVC, Inodes)
   - PVCUsageHigh/Critical, PVCInodeLow
   - Keep: capacity monitoring over time

3. **K8s State Issues**
   - DeploymentReplicasMismatch, PodsPending
   - DaemonSetNotScheduled, JobFailed
   - Keep: K8s API state tracking

4. **Certificate Management**
   - CertificateExpiringSoon/Critical
   - CertificateRenewalFailed
   - Keep: expiry date tracking

5. **Monitoring Health** (meta)
   - PrometheusTargetDown, PrometheusTooManyRestarts
   - AlertmanagerNotificationsFailing
   - Keep: self-monitoring stack

6. **Cloudflare Tunnel Metrics**
   - CloudflareTunnelHighLatency, CloudflareTunnelNoConnections
   - Keep: needs metrics (P99 latency, request counts)

---

### MOVE to Uptime Kuma
**Rationale**: up/down checks, user-friendly dashboard

1. **HTTP Service Availability** (already monitoring)
   - Homepage, Grafana, Authentik, Home Assistant
   - Wallabag, Mealie, N8N, Linkding, Audiobookshelf
   - Move: simpler in Uptime Kuma dashboard

2. **Infra TCP Checks** (already monitoring)
   - PostgreSQL (5432)
   - Redis (6379)
   - Move: better fit for Uptime Kuma

3. **Basic Service Health** (replace Prometheus alert)
   - Remove: Prometheus `ServiceDown`
   - Replace: Uptime Kuma HTTP monitors (configured)

---

### REMOVED (Redundant)

1. **Prometheus `ServiceDown`** — DONE
   - File: `monitoring/configs/staging/kube-prometheus-stack/prometheus-rules.yaml:395`
   - Reason: Uptime Kuma monitors HTTP better
   - Action: commented out 2025-10-18 — Uptime Kuma replaced

2. **Duplicate Flux Alerts**
   - Option A: keep Flux native, remove Prometheus Flux rules
   - Option B: keep Prometheus, remove Flux Alert CRD
   - Recommendation: **Keep Flux native** (simpler, closer to source)

---

### ADD to Uptime Kuma

1. **Telegram Notification Channel**
   - Bot: reuse `alertmanager-telegram` token
   - Chat ID: 113452686
   - Configure in Uptime Kuma UI

2. **Notification Settings**
   - Send on: DOWN only (not recoveries)
   - Reason: reduce noise, Alertmanager handles recoveries
   - Or: DOWN + UP for clearer status

3. **Notification Template**:
   ```
   🔴 Service Down: {monitor_name}
   URL: {url}
   Down since: {down_time}
   ```

---

## Implementation Plan

### Phase 1: Configure Uptime Kuma Notifications (Now)
1. Get Telegram bot token from secret
2. Add Telegram channel in UI
3. Enable for 14 monitors
4. Test with service restart

### Phase 2: Remove Redundant Prometheus Alerts (after testing)
1. Comment out `ServiceDown` in prometheus-rules.yaml
2. Monitor 1 week — ensure Uptime Kuma catches all
3. If stable, permanently remove

### Phase 3: Consolidate Flux Alerts (optional)
1. Decide: Flux native OR Prometheus Flux rules
2. Remove one
3. Recommendation: keep Flux native (already working)

---

## Final Notification Matrix

| Alert Type | Source | Destination | Reason |
|------------|--------|-------------|--------|
| **HTTP Service Down** | Uptime Kuma | Telegram | User-friendly dashboard |
| **TCP Port Down** | Uptime Kuma | Telegram | Simple connectivity |
| **Resource Pressure** | Prometheus | Telegram | Metrics analysis |
| **Storage Issues** | Prometheus | Telegram | Capacity + inode |
| **K8s State Issues** | Prometheus | Telegram | API state tracking |
| **Certificate Expiry** | Prometheus | Telegram | Date-based |
| **Flux Failures** | Flux Alerts | Telegram | Native integration |
| **Monitoring Health** | Prometheus | Telegram | Meta-monitoring |

---

## Benefits

1. **Less Noise**: no duplicate service-down
2. **Better UX**: Uptime Kuma dashboard at a glance
3. **Focused Alerts**: Prometheus deep infra only
4. **Complementary**: each tool its strength
5. **Maintainability**: clear separation

---

## Next Steps

1. Done: configure Uptime Kuma monitors
2. Done: add Telegram notifications
3. Done: remove `ServiceDown` from Prometheus
4. Optional: consolidate Flux alert sources

---

## Telegram Bot Details

**Token Location**: `monitoring/configs/staging/kube-prometheus-stack/alertmanager-telegram-secret.yaml` (SOPS)
**Chat ID**: 113452686 (all notifications)
**Current Usage**: Alertmanager + Flux
**Proposed Addition**: Uptime Kuma (same bot, same chat)

Get token for Uptime Kuma UI:
```bash
kubectl get secret alertmanager-telegram -n monitoring -o jsonpath='{.data.bot_token}' | base64 -d
```

---

**Last Updated**: 2025-10-18 03:30 UTC
**Status**: Ready for Implementation
