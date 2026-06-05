# Networking Codemap

## Ingress
- **Traefik** (traefik ns, chart v40.2.0, image v3.7.1, 1 svc) handles all `*.h0melab.work` via K8s `Ingress` (class=traefik); 0 IngressRoute CRDs in use
- **Cloudflare Tunnel** (cloudflare-tunnel ns) — outbound-only, exposes 9 svcs externally without inbound port
- **Blocky DNS** (blocky ns, image `spx01/blocky:v0.31.0`) — single LB Service `blocky-dns` exposes 192.168.1.129 (W1) + 192.168.1.126 (W2) (servicelb ETP=Local, anti-affinity'd 2 pods). Serves **LAN clients only** since 2026-06-04 — nodes + CoreDNS no longer use it as upstream (circular-dep break)
- **NodeLocalDNS** N/A — using CoreDNS (`10.43.0.10`) cluster-internal

## Service Endpoints
| Service | Endpoint | Used by |
|---------|----------|---------|
| Postgres pooler (PgBouncer 1.25.1) | `main-postgres-rw-pooler.databases.svc:5432` | most apps |
| Postgres direct | `main-postgres-rw.databases.svc:5432` | n8n, blocky (queryLog), CNPG admin |
| MySQL HAProxy 2.8.18 | `main-mysql-haproxy.databases.svc:3306` | uptime-kuma, HA, pricebuddy |
| Redis HA master (static) | `redis-replication-master.databases.svc:6379` | paperless, blocky |
| Redis HA Sentinel | `redis-sentinel-sentinel.databases.svc:26379` | immich (REDIS_URL=ioredis://...) |
| CouchDB | `couchdb-couchdb.databases.svc:5984` | obsidian (LiveSync via Cloudflare Tunnel) |

## Traefik Middlewares
Defined in `traefik` ns (referenced as `traefik-<name>@kubernetescrd`):
- `csp`, `rate-limit-standard`, `rate-limit-high-frequency`, `redirect-https`, `security-headers`

Legacy duplicates also live in `monitoring` ns (`csp`, `rate-limit-standard`, `redirect-https`, `security-headers`) for kube-prometheus-stack ingresses.

## NetworkPolicy invariants
- **44 NetworkPolicies** total (every ingress + every cross-ns egress)
- Default-deny implicit per-ns where NP exists with empty ingress
- Container port (NOT service port) used in NP `ports:`
- Apps with both internal + Cloudflare Tunnel access need 2 Ingress rules (Traefik) but 1 NP (covers both via TCP port)
- Per-ns NP counts: databases 7, monitoring 7, flux-system 3, linkwarden 2, loki 2; all other ns with NP have 1

## Cloudflare Tunnel topology
- Account: `***REMOVED-CF-ACCOUNT-ID***`
- Tunnel ID: `***REMOVED-CF-TUNNEL-UUID***`
- Config sync via `PUT /accounts/{acct}/cfd_tunnel/{tunnel}/configurations` from SOPS Secret `cloudflared-config`
- Mgmt token in `cloudflare-tunnel-mgmt-token` Secret, **expires 2026-12-31**

## DNS chain
1. LAN client → Blocky LB IP (.129 or .126) :53
2. Blocky checks ACL → cache → upstream (DoH: Cloudflare Security + Quad9)
3. Nodes (containerd, system) → systemd-resolved → **public DNS 1.1.1.1 / 9.9.9.9** — **NOT blocky** (decoupled 2026-06-04 to break the node→blocky→kube-proxy-servicelb circular dep; see HISTORY 2026-06-04). resolved stays uplink-mode (real IPs, not 127.0.0.53); networkd `UseDNS=no` drops the DHCP/RA-supplied blocky DNS, resolved global drop-in supplies public.
4. Cluster pods → CoreDNS (`10.43.0.10`); `forward . /etc/resolv.conf` → node resolv.conf (= public, per step 3). Pods snapshot resolv.conf at creation → `rollout restart deploy/coredns-ha` after any node-DNS change.
5. Mac per-domain resolver `/etc/resolver/h0melab.work` forces `*.h0melab.work` to LAN IPs (bypasses VPN-pushed public DNS)

**Blocky `connectIPVersion: v4` is permanent** — K3s podCIDR is v4-only, dual-stack decided NOT-WORTH-IT (2026-04-26). Blocky on pods can't initiate v6 connections; v4-only DoH upstreams (Cloudflare/Quad9) cover all needs.

## UFW firewall (post-reboot drift gotcha)
Workers use `ufw-heal-post-k3s.service` (oneshot, after k3s.service) to re-apply ip6tables rules that K3s flannel CNI clobbers on boot. Phase C rule split (`community.general.ufw` module) preserves order. Verification metric: `ufw_chains_healthy` (textfile collector). If alert fires: `sudo systemctl start ufw-heal-post-k3s.service` + `sudo systemctl start ufw-state-metric.service`.

## TLS / Certs
- **cert-manager** with Cloudflare DNS-01 challenge
- Wildcard cert `*.h0melab.work` for Traefik
- Per-app certs: grafana, alertmanager (kube-prometheus-stack uses own)
- HSTS via `traefik-security-headers@kubernetescrd` middleware
- `minTlsServeVersion: 1.3` on Blocky (inert — no DoT/DoH server configured)

## Firewall (host-side via UFW)
- ansible role `firewall` deploys UFW rules per node
- K3s ports allowlisted (6443, 10250, 8472/UDP flannel)
- Cross-node SSH on custom port 65300
- IPv6 ingress blocked by default
- Phase C rule split managed via `community.general.ufw` ansible module
