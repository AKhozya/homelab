# SearXNG Deployment Design

**Date**: 2026-03-16
**Status**: Approved

## Overview

Deploy SearXNG as a privacy-respecting metasearch engine in the homelab cluster. Serves as a daily-driver search engine (internal + external access) and provides a JSON API for n8n/Home Assistant automations.

## Architecture

Raw manifest deployment (Pattern A — like homehub/stirling-pdf). Single container, no Helm chart.

### Components

| File | Purpose |
|------|---------|
| `namespace.yaml` | Namespace with PSS `restricted` |
| `serviceaccount.yaml` | SA `searxng`, `automountServiceAccountToken: false` |
| `deployment.yaml` | Single replica, restricted security context |
| `service.yaml` | ClusterIP, port 8080 |
| `ingress.yaml` | Traefik, `search.h0melab.work`, no auth middleware |
| `networkpolicy.yaml` | Traefik + CF tunnel + uptime-kuma ingress, DNS + HTTPS egress |
| `certificate.yaml` | Let's Encrypt TLS for `search.h0melab.work` (staging overlay) |
| `configmap.yaml` | SearXNG `settings.yml` |
| `secret.yaml` | SOPS-encrypted `SEARXNG_SECRET` |
| `kustomization.yaml` | Resource list |

No PVC — SearXNG is stateless. Configuration via ConfigMap, secret key via env var.

### Image

```
docker.io/searxng/searxng:2026.3.13-3c1f68c59
```

Date+hash versioning. Renovate custom regex manager required (see Renovate section).

## Access Pattern

### Internal (no auth)

```
Browser → AdGuard DNS → Traefik Ingress → SearXNG :8080
```

No Authentik middleware on Ingress. Fast, frictionless search.

### External (Authentik SSO)

```
Browser → Cloudflare DNS → CF Tunnel → Authentik forward-auth → SearXNG :8080
```

Cloudflare Tunnel route configured with Authentik access policy. External users must authenticate via SSO before reaching SearXNG.

### API

```
GET /search?q=query&format=json
```

Available from both internal and external paths. n8n/HA can call internally via `searxng.searxng.svc.cluster.local:8080`.

## Deployment Details

### Security Context

```yaml
# Pod
securityContext:
  runAsNonRoot: true
  runAsUser: 977
  runAsGroup: 977
  fsGroup: 977
  seccompProfile:
    type: RuntimeDefault

# Container
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
```

SearXNG's Dockerfile uses UID/GID 977 (`searxng` user). EmptyDir volumes for `/tmp` and `/etc/searxng` (runtime config rendering).

### Volumes

| Mount | Type | Purpose |
|-------|------|---------|
| `/etc/searxng` | emptyDir | Runtime config directory (SearXNG writes `uwsgi.ini` etc. at startup) |
| `/tmp` | emptyDir | Temp files |

Init container copies `settings.yml` from ConfigMap into the `/etc/searxng` emptyDir before the main container starts (same pattern as homehub's `setup-config`). SearXNG needs write access to `/etc/searxng/` for runtime files.

### Environment Variables

| Var | Source | Purpose |
|-----|--------|---------|
| `SEARXNG_SECRET` | Secret | Instance secret key |
| `SEARXNG_BASE_URL` | Literal | `https://search.h0melab.work` |

### Resources

```yaml
resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

Search engine with external HTTP calls — moderate CPU for request fanout, modest memory.

### Deployment Settings

- `revisionHistoryLimit: 2` (consistent with all other apps)
- `strategy: RollingUpdate` (default)

### Probes

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10
  timeoutSeconds: 3
  failureThreshold: 3
readinessProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10
  timeoutSeconds: 3
  failureThreshold: 3
```

SearXNG exposes `/healthz` (returns `200 OK` plain text, exempt from rate limiting). Defined in `searx/webapp.py`.

### NetworkPolicy

**Ingress:**
- traefik namespace → port 8080
- cloudflare-tunnel namespace → port 8080
- uptime-kuma namespace → port 8080
- n8n namespace → port 8080 (API consumers)
- home-assistant namespace → port 8080 (API consumers)

**Egress:**
- kube-system → UDP 53 (DNS)
- 0.0.0.0/0 → TCP 443 (HTTPS to external search engines)
- 0.0.0.0/0 → TCP 80 (HTTP — some search engines/APIs use plain HTTP)

### Ingress

```yaml
metadata:
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: |
      traefik-redirect-https@kubernetescrd,
      traefik-security-headers@kubernetescrd,
      traefik-rate-limit-standard@kubernetescrd,
      traefik-csp@kubernetescrd
spec:
  ingressClassName: traefik
  tls:
    - hosts: ["search.h0melab.work"]
      secretName: searxng-tls
  rules:
    - host: search.h0melab.work
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: searxng
                port:
                  number: 8080
```

No Authentik middleware — internal access is unauthenticated.

## ConfigMap (settings.yml)

Default SearXNG configuration with:
- JSON API enabled (`formats: ["html", "json"]`)
- Instance name: "SearXNG"
- Default engines: SearXNG defaults (DuckDuckGo, Google, Bing, Wikipedia, etc.)
- Server settings: bind `0.0.0.0:8080`, base_url from env

```yaml
use_default_settings: true
server:
  secret_key: ""  # Overridden by SEARXNG_SECRET env var at runtime
  bind_address: "0.0.0.0"
  port: 8080
  base_url: "https://search.h0melab.work"
  image_proxy: true
search:
  formats:
    - html
    - json
```

`use_default_settings: true` inherits all default engines and settings, allowing minimal config.

## Cloudflare Tunnel

Add SearXNG route to the tunnel SOPS config:

```yaml
- hostname: search.h0melab.work
  service: http://searxng.searxng.svc.cluster.local:8080
  originRequest:
    noTLSVerify: true
    access:
      teamName: h0melab
      audTag:
        - <searxng-access-app-aud>
```

The `access` block enforces Authentik authentication for external requests. Create an Authentik application + provider for SearXNG, configure in CF Zero Trust dashboard.

## DNS

- **Cloudflare**: CNAME `search.h0melab.work` → tunnel (for external access)
- **AdGuard Home**: DNS rewrite `search.h0melab.work` → Traefik LB IP (for internal access)

## Renovate

Custom regex manager for date+hash tags:

```json
{
  "customManagers": [
    {
      "customType": "regex",
      "fileMatch": ["apps/base/searxng/deployment\\.yaml$"],
      "matchStrings": ["image:\\s+docker\\.io/searxng/searxng:(?<currentValue>[\\d.]+[-][a-f0-9]+)"],
      "depNameTemplate": "docker.io/searxng/searxng",
      "datasourceTemplate": "docker",
      "versioningTemplate": "loose"
    }
  ]
}
```

This allows Renovate to detect new tags and create PRs.

## Uptime Kuma

Add HTTP monitor:
- URL: `https://search.h0melab.work/healthz`
- Expected: 200

## Directory Structure

```
apps/base/searxng/
  kustomization.yaml
  namespace.yaml
  serviceaccount.yaml
  deployment.yaml
  service.yaml
  ingress.yaml
  networkpolicy.yaml
  configmap.yaml
  secret.yaml

apps/staging/searxng/
  kustomization.yaml
  certificate.yaml
```

## Flux Wiring

Add `searxng` to `apps/staging/kustomization.yaml` resources list.

## Out of Scope

- No database needed (stateless)
- No PVC (settings in ConfigMap, no persistent preferences)
- No Redis (SearXNG has optional Redis for rate limiting/caching, not needed at homelab scale)
- No HA (single replica sufficient for personal use)
- Engine customization deferred to post-deployment tuning
