# Monitoring Stack — access model

Config objects for the `kube-prometheus-stack` HelmRelease: Grafana and Alertmanager
ingress, TLS, auth, and the per-component NetworkPolicies.

**There is no Prometheus pod.** `prometheus.enabled: false` in
`monitoring/controllers/kube-prometheus-stack/release.yaml` — VictoriaMetrics (VMSingle +
VMAgent + VMAlert) replaced it. The chart stays for Grafana, Alertmanager, the operator,
kube-state-metrics, and node-exporter.

## Ingress

Both hostnames terminate at Traefik on the LAN. Hosts, TLS secrets, and the middleware
chains are set in the HelmRelease values, not here.

| Host | Component | Middleware chain |
|---|---|---|
| `grafana.h0melab.work` | Grafana | redirect-https · security-headers · rate-limit-standard · csp |
| `am.h0melab.work` | Alertmanager | redirect-https · security-headers · rate-limit-standard · **basic-auth** · csp |

Alertmanager's basic-auth sits after rate-limit on purpose: a 401 short-circuits the
chain, so auth placed earlier would leave brute-force attempts unthrottled.

Certificates come from cert-manager over DNS-01 (`grafana-certificate.yaml`,
`alertmanager-certificate.yaml`). The `cloudflared` NetworkPolicy permits egress to
`monitoring` on 3000 and 9093, so a tunnel hostname can reach either component; the
hostname list itself lives in the SOPS-encrypted tunnel config.

## Authentication

- **Grafana** — Authentik OIDC only. The HelmRelease values set
  `auth.disable_login_form: true`, which hides the UI login form, and
  `auth.basic.enabled: false`, which closes the API basic-auth path. The local admin user
  that `grafana-admin-secret.yaml` provisions therefore has no way in while both hold.
- **Alertmanager** — Traefik basic-auth middleware (`alertmanager-basic-auth-secret.yaml`).

Read the local Grafana admin credentials:

```bash
kubectl get secret -n monitoring grafana-admin-secret -o jsonpath='{.data.admin-user}' | base64 -d
kubectl get secret -n monitoring grafana-admin-secret -o jsonpath='{.data.admin-password}' | base64 -d
```

## NetworkPolicies

| File | Scope |
|---|---|
| `grafana-networkpolicy.yaml` | ingress from any namespace on 3000; egress to DNS, the K8s API (dashboard sidecar), VictoriaMetrics, Alertmanager, Loki, and plugin downloads |
| `alertmanager-networkpolicy.yaml` | ingress on 9093 from any namespace and from the LAN (the CP `kubectl proxy` path for silences), plus cluster gossip on 9094; egress to DNS, gossip, and webhook notifications |
| `kube-state-metrics-networkpolicy.yaml` | metrics scrape only |
| `prometheus-operator-networkpolicy.yaml` | metrics scrape only |

## Access away from home

Do not publish Grafana or Alertmanager on a bare public hostname. Use the Cloudflare
Tunnel with an Access policy, or a VPN back to the LAN.
