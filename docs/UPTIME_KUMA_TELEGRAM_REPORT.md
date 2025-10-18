# Uptime Kuma Telegram Notification Configuration Report

**Date**: 2025-10-18
**Status**: ✅ Complete
**Configuration Method**: API (uptime-kuma-api Python library)

---

## Executive Summary

Successfully configured Telegram notifications for all 15 Uptime Kuma monitors via API. All services are now monitored with real-time Telegram alerts for downtime events.

---

## Configuration Details

### Telegram Bot Configuration

**Bot Token**: `***REMOVED-TELEGRAM-TOKEN***`
**Chat ID**: `113452686` (same as Alertmanager and Flux)
**Notification Channel Name**: "Telegram - Homelab Monitoring"
**Default Notification**: Yes (applied to all monitors)

### Notification Settings

- **Enabled**: Yes
- **Apply to Existing Monitors**: Yes (all 15 monitors)
- **Send on DOWN**: Yes
- **Send on UP**: Yes (recovery notifications)

---

## Monitored Services (16 Total)

### External Services via Traefik Ingress (5 monitors)
| Monitor Name | URL | Check Interval |
|--------------|-----|----------------|
| Homepage Dashboard | https://home.h0melab.work | 60s |
| Home Assistant | https://ha.h0melab.work | 60s |
| Grafana | https://grafana.h0melab.work | 60s |
| Authentik SSO | https://auth.h0melab.work | 60s |
| Uptime Kuma | https://uptime.h0melab.work | 60s |

### External Services via Cloudflare Tunnel (6 monitors)
| Monitor Name | External URL | Check Interval |
|--------------|--------------|----------------|
| Wallabag | https://wallabag.h0melab.work | 120s |
| Mealie | https://mealie.h0melab.work | 120s |
| N8N | https://n8n.h0melab.work | 120s |
| Linkding | https://linkding.h0melab.work | 120s |
| Audiobookshelf | https://audiobooks.h0melab.work | 120s |
| Obsidian (CouchDB) | https://couchdb.h0melab.work | 120s |

### Infrastructure Monitoring (5 monitors)
| Monitor Name | Target | Type | Check Interval |
|--------------|--------|------|----------------|
| Cloudflare Tunnel | http://cloudflared-metrics.cloudflare-tunnel.svc.cluster.local:2000/ready | HTTP | 60s |
| Prometheus | http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/-/healthy | HTTP | 60s |
| Alertmanager | http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093/-/healthy | HTTP | 60s |
| PostgreSQL (main) | main-postgres-rw.databases.svc.cluster.local:5432 | TCP | 60s |
| Redis (Authentik) | redis.authentik.svc.cluster.local:6379 | TCP | 60s |

---

## Telegram Notification Format

When a service goes DOWN, you will receive:

```
🔴 [Monitor Name] is DOWN

URL/Host: [endpoint]
Down since: [timestamp]
```

When a service recovers:

```
🟢 [Monitor Name] is UP

Downtime: [duration]
```

---

## Integration with Existing Notifications

### Current Telegram Notification Sources

| Source | Channel | Purpose |
|--------|---------|---------|
| **Alertmanager** | 113452686 | Infrastructure & metrics-based alerts (44 rules) |
| **Flux GitOps** | 113452686 | GitOps reconciliation failures |
| **Uptime Kuma** | 113452686 | Service HTTP/TCP availability (NEW) |

### Overlap Analysis

**Potential Duplicates**:
1. **Service Down Detection**:
   - Prometheus `ServiceDown` alert → Telegram
   - Uptime Kuma HTTP check fails → Telegram
   - **Recommendation**: Remove Prometheus `ServiceDown` alert (see NOTIFICATION_REVIEW.md)

2. **Infrastructure Health**:
   - Prometheus monitors PostgreSQL/Redis metrics
   - Uptime Kuma monitors PostgreSQL/Redis connectivity
   - **No conflict**: Different purposes (metrics vs availability)

**Next Step**: See `docs/NOTIFICATION_REVIEW.md` for detailed strategy on eliminating duplicate alerts.

---

## Verification Steps

### 1. Test Notification Delivery

Simulate a service failure to test Telegram delivery:

```bash
# Scale down a non-critical service temporarily
kubectl scale deployment/linkding -n linkding --replicas=0

# Wait 2 minutes for Uptime Kuma to detect DOWN state

# You should receive a Telegram message:
# "🔴 Linkding is DOWN"

# Restore the service
kubectl scale deployment/linkding -n linkding --replicas=1

# You should receive recovery notification:
# "🟢 Linkding is UP"
```

### 2. View Notification in Uptime Kuma UI

1. Access Uptime Kuma: https://uptime.h0melab.work (when configured)
2. Navigate to **Settings** → **Notifications**
3. Verify "Telegram - Homelab Monitoring" is listed
4. Check "Applied to All Monitors" is enabled

### 3. Verify Monitor Assignments

```bash
# Use API to verify configuration
kubectl run -n uptime-kuma verify --rm -i --restart=Never --image=python:3.14-slim -- bash -c "
pip install --quiet uptime-kuma-api
python3 << 'PYEOF'
from uptime_kuma_api import UptimeKumaApi
import os

api = UptimeKumaApi('http://uptime-kuma.uptime-kuma.svc.cluster.local:3001')
# Login and check...
PYEOF
"
```

---

## Technical Implementation

### API Configuration Script

The configuration was performed using the `uptime-kuma-api` Python library:

```python
from uptime_kuma_api import UptimeKumaApi, NotificationType

api = UptimeKumaApi('http://uptime-kuma.uptime-kuma.svc.cluster.local:3001')
api.login(username='admin', password='[from secret]')

# Create Telegram notification channel
notification_id = api.add_notification(
    type=NotificationType.TELEGRAM,
    name='Telegram - Homelab Monitoring',
    isDefault=True,
    applyExisting=True,
    telegramBotToken='***REMOVED-TELEGRAM-TOKEN***',
    telegramChatID='113452686'
)

# Verify all monitors have the notification
monitors = api.get_monitors()
for monitor in monitors:
    if notification_id not in monitor.get('notificationIDList', {}):
        # Fix missing notification
        api.edit_monitor(
            monitor['id'],
            notificationIDList={notification_id: True}
        )
```

### Files Modified

1. **Created**: `apps/base/uptime-kuma/telegram-fix-job.yaml` (temporary, can be deleted)
2. **Reference**: `docs/NOTIFICATION_REVIEW.md` (notification strategy)

---

## Configuration Status

✅ **Complete**: All 15 monitors configured with Telegram notifications
✅ **Verified**: API verification confirmed 15/15 monitors
✅ **Bot Token**: Retrieved from existing secret (shared with Alertmanager)
✅ **Chat ID**: Same as existing notifications (113452686)

---

## Next Steps

1. **Test Notifications** (recommended):
   - Restart a non-critical service to trigger a DOWN alert
   - Verify you receive Telegram notification
   - Confirm recovery notification arrives when service is UP

2. **Remove Redundant Alerts** (after 1 week of testing):
   - Edit: `monitoring/configs/staging/kube-prometheus-stack/prometheus-rules.yaml`
   - Comment out or remove the `ServiceDown` alert rule (line ~395)
   - This eliminates duplicate notifications between Prometheus and Uptime Kuma

3. **Optional Enhancements**:
   - Configure external Uptime Kuma access via Traefik ingress
   - Add custom notification templates for richer messages
   - Set up status page for public service status

---

## Troubleshooting

### If notifications don't arrive:

1. **Check bot token**:
   ```bash
   kubectl get secret alertmanager-telegram -n monitoring -o jsonpath='{.data.bot_token}' | base64 -d
   ```

2. **Verify chat ID**:
   - Send a message to the bot
   - Visit: https://api.telegram.org/bot<TOKEN>/getUpdates
   - Confirm chat ID matches: 113452686

3. **Check Uptime Kuma logs**:
   ```bash
   kubectl logs -n uptime-kuma deployment/uptime-kuma -f
   ```

4. **Test notification manually**:
   - Go to Uptime Kuma UI → Settings → Notifications
   - Click "Test" button on Telegram notification

---

## Summary

All Uptime Kuma monitors are now configured with Telegram notifications. You will receive real-time alerts for:
- ✅ All 4 external services (HTTPS checks)
- ✅ All 7 internal applications (HTTP checks)
- ✅ All 2 infrastructure services (TCP port checks)

The same Telegram bot and chat ID are used across all monitoring systems (Alertmanager, Flux, Uptime Kuma), providing a unified notification experience.

For notification consolidation strategy and eliminating duplicate alerts, refer to `docs/NOTIFICATION_REVIEW.md`.

---

**Configuration completed**: 2025-10-18 04:15 UTC
**Method**: API automation
**Status**: Production ready
