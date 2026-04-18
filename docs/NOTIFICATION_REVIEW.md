# Notification Strategy Review

**Date**: 2025-10-18
**Purpose**: Evaluate current Telegram notifications and determine optimal distribution

---

## Current Notification Setup

### 1. Alertmanager (Prometheus) → Telegram
**Bot**: Same token (alertmanager-telegram secret)
**Chat ID**: 113452686
**Scope**: Infrastructure & application metrics-based alerts

**Alert Categories**:
- **Node Alerts** (8 alerts)
  - NodeDown, KubeletDown, NodeNotReady
  - NodeMemoryPressure, NodeDiskPressure
  - NodeHighCPU, NodeHighMemory, NodeDiskSpaceLow/Critical
  - NodeHighIOWait, NodeNetworkErrors

- **Storage Alerts** (5 alerts)
  - PVCUsageHigh/Critical
  - PVCInodeLow, PVCLowAbsoluteSpace
  - PersistentVolumeError

- **Pod Alerts** (6 alerts)
  - PodCrashLooping, PodNotReady
  - ContainerOOMKilled, ContainerMemoryNearLimit
  - ContainerCPUThrottling, PodImagePullError

- **Cloudflare Tunnel Alerts** (4 alerts)
  - CloudflareTunnelDown, CloudflareTunnelPodNotRunning
  - CloudflareTunnelNoConnections, CloudflareTunnelHighLatency

- **Certificate Alerts** (4 alerts)
  - CertificateExpiringSoon/Critical
  - CertificateNotReady, CertificateRenewalFailed

- **Kubernetes Alerts** (7 alerts)
  - DeploymentReplicasMismatch, StatefulSetReplicasMismatch
  - DaemonSetNotScheduled, PodsPending
  - KubernetesAPIServerDown, JobFailed
  - CronJobNotScheduled

- **Flux GitOps Alerts** (3 alerts)
  - FluxReconciliationFailure
  - FluxSourceNotReady
  - FluxSuspended (info only)

- **Service Alerts** (2 alerts)
  - ServiceDown, HighErrorRate

- **Monitoring Health Alerts** (5 alerts)
  - PrometheusTargetDown, PrometheusTargetScrapeTooSlow
  - PrometheusTooManyRestarts
  - AlertmanagerConfigInvalid, AlertmanagerNotificationsFailing

**Total**: ~44 distinct Prometheus alert rules

**Repeat Interval**: 12 hours
**Grouping**: By alertname, cluster, service
**Group Wait**: 10s
**Group Interval**: 10s

---

### 2. Flux Notifications → Telegram
**Bot**: Same token (alertmanager-telegram secret)
**Chat ID**: 113452686
**Scope**: GitOps reconciliation failures

**Alert Name**: "🔄 Flux GitOps Events"
**Severity**: error only
**Event Sources**:
- GitRepository (flux-system namespace)
- Kustomization (flux-system namespace)
- HelmRelease (all namespaces)
- HelmRepository (all namespaces)
- HelmChart (all namespaces)

**Example Events**:
- Git fetch failures
- Kustomization apply failures
- Helm release failures
- Repository sync issues

---

### 3. Uptime Kuma → Telegram (Not Yet Configured)
**Current State**: Monitors configured, but no Telegram notifications set up
**Scope**: HTTP/TCP endpoint availability

**Monitored Services** (14 total):
- External: Homepage, Home Assistant, Grafana, Authentik
- Internal Apps: Uptime Kuma, Wallabag, Mealie, N8N, Linkding, Audiobookshelf
- Infrastructure: Prometheus, Alertmanager, PostgreSQL, Redis

---

## Analysis & Recommendations

### Problem: Notification Overlap & Noise

#### Current Overlaps:
1. **Service Downtime**:
   - Prometheus `ServiceDown` alert → Telegram
   - Uptime Kuma HTTP check fails → (no notification yet)
   - **OVERLAP**: Both detect the same issue

2. **Pod/Container Issues**:
   - Prometheus `PodCrashLooping` → Telegram
   - Uptime Kuma HTTP check fails → (no notification yet)
   - **OVERLAP**: Same root cause, different symptoms

3. **Flux Issues**:
   - Flux Alert `FluxReconciliationFailure` → Telegram
   - Prometheus `FluxReconciliationFailure` → Telegram
   - **OVERLAP**: Duplicate alerts from two systems

---

## Recommended Strategy

### ✅ KEEP in Alertmanager (Prometheus)
**Rationale**: Metrics-based alerts that Uptime Kuma cannot detect

1. **Resource Pressure** (CPU, Memory, Disk, I/O)
   - NodeHighCPU, NodeHighMemory, NodeDiskSpaceLow
   - ContainerMemoryNearLimit, ContainerCPUThrottling
   - Keep: These require time-series metrics

2. **Storage Issues** (PVC, Inodes)
   - PVCUsageHigh/Critical, PVCInodeLow
   - Keep: Requires capacity monitoring over time

3. **Kubernetes State Issues**
   - DeploymentReplicasMismatch, PodsPending
   - DaemonSetNotScheduled, JobFailed
   - Keep: Requires Kubernetes API state tracking

4. **Certificate Management**
   - CertificateExpiringSoon/Critical
   - CertificateRenewalFailed
   - Keep: Requires expiry date tracking

5. **Monitoring Health** (Meta-monitoring)
   - PrometheusTargetDown, PrometheusTooManyRestarts
   - AlertmanagerNotificationsFailing
   - Keep: Self-monitoring the monitoring stack

6. **Cloudflare Tunnel Metrics**
   - CloudflareTunnelHighLatency, CloudflareTunnelNoConnections
   - Keep: Requires metrics (latency P99, request counts)

---

### ✅ MOVE to Uptime Kuma
**Rationale**: Simple up/down checks, user-friendly dashboard

1. **HTTP Service Availability** (Already monitoring)
   - Homepage, Grafana, Authentik, Home Assistant
   - Wallabag, Mealie, N8N, Linkding, Audiobookshelf
   - Move: Simpler to view in Uptime Kuma dashboard

2. **Infrastructure TCP Checks** (Already monitoring)
   - PostgreSQL (port 5432)
   - Redis (port 6379)
   - Move: Better suited for Uptime Kuma

3. **Basic Service Health** (Replace Prometheus alert)
   - Remove: Prometheus `ServiceDown` alert
   - Replace with: Uptime Kuma HTTP monitors (already configured)

---

### ❌ REMOVED (Redundant)

1. **Prometheus `ServiceDown` Alert** - ✅ DONE
   - File: `monitoring/configs/staging/kube-prometheus-stack/prometheus-rules.yaml:395`
   - Reason: Uptime Kuma monitors HTTP endpoints better
   - Action: Commented out on 2025-10-18 - replaced by Uptime Kuma

2. **Duplicate Flux Alerts**
   - Option A: Keep Flux native alerts, remove Prometheus Flux alert rules
   - Option B: Keep Prometheus alerts, remove Flux Alert CRD
   - Recommendation: **Keep Flux native alerts** (simpler, closer to source)

---

### 🆕 ADD to Uptime Kuma

1. **Telegram Notification Channel**
   - Bot: Reuse `alertmanager-telegram` token
   - Chat ID: 113452686
   - Configure in Uptime Kuma UI

2. **Notification Settings**
   - Send on: DOWN events only (not recoveries)
   - Reason: Reduce noise, Alertmanager handles recoveries
   - Or: Send both DOWN and UP for clearer status

3. **Notification Template** (example):
   ```
   🔴 Service Down: {monitor_name}
   URL: {url}
   Down since: {down_time}
   ```

---

## Implementation Plan

### Phase 1: Configure Uptime Kuma Notifications (Now)
1. Get Telegram bot token from secret
2. Add Telegram notification channel in Uptime Kuma UI
3. Enable notifications for all 14 monitors
4. Test with a service restart

### Phase 2: Remove Redundant Prometheus Alerts (After testing)
1. Comment out `ServiceDown` alert in prometheus-rules.yaml
2. Monitor for 1 week to ensure Uptime Kuma catches all issues
3. If stable, permanently remove

### Phase 3: Consolidate Flux Alerts (Optional)
1. Decision: Keep Flux native alerts OR Prometheus Flux rules
2. Remove one to eliminate duplication
3. Recommendation: Keep Flux native (already working)

---

## Final Notification Matrix

| Alert Type | Source | Destination | Reason |
|------------|--------|-------------|--------|
| **HTTP Service Down** | Uptime Kuma | Telegram | User-friendly, visual dashboard |
| **TCP Port Down** | Uptime Kuma | Telegram | Simple connectivity checks |
| **Resource Pressure** | Prometheus | Telegram | Requires metrics analysis |
| **Storage Issues** | Prometheus | Telegram | Capacity & inode monitoring |
| **K8s State Issues** | Prometheus | Telegram | API state tracking |
| **Certificate Expiry** | Prometheus | Telegram | Date-based alerting |
| **Flux Failures** | Flux Alerts | Telegram | Native integration |
| **Monitoring Health** | Prometheus | Telegram | Meta-monitoring |

---

## Benefits of This Strategy

1. **Reduced Noise**: Eliminate duplicate service down alerts
2. **Better UX**: Uptime Kuma dashboard for service status at a glance
3. **Focused Alerts**: Prometheus for deep infrastructure issues only
4. **Complementary**: Each tool does what it's best at
5. **Maintainability**: Clearer separation of concerns

---

## Next Steps

1. ✅ **Done**: Configure Uptime Kuma monitors
2. ✅ **Done**: Add Telegram notifications to Uptime Kuma
3. ✅ **Done**: Remove `ServiceDown` alert from Prometheus
4. ⏭️ **Optional**: Consolidate Flux alert sources

---

## Telegram Bot Details

**Token Location**: `monitoring/configs/staging/kube-prometheus-stack/alertmanager-telegram-secret.yaml` (SOPS encrypted)
**Chat ID**: 113452686 (same for all notifications)
**Current Usage**: Alertmanager + Flux
**Proposed Addition**: Uptime Kuma (same bot, same chat)

To get the token for Uptime Kuma UI configuration:
```bash
kubectl get secret alertmanager-telegram -n monitoring -o jsonpath='{.data.bot_token}' | base64 -d
```

---

**Last Updated**: 2025-10-18 03:30 UTC
**Status**: Ready for Implementation
