# Networking map

## Ingress
- **Traefik** (`traefik` ns, chart in `infrastructure/controllers/traefik/release.yaml`) handles all `*.h0melab.work` via K8s `Ingress` (class=traefik); no IngressRoute CRDs in use
- **Cloudflare Tunnel** (`cloudflare-tunnel` ns) — outbound-only, zero inbound router ports; see topology below
- **Blocky DNS** (`blocky` ns, `apps/blocky/`) — single LB Service `blocky-dns` exposes 192.168.1.129 (W1) + 192.168.1.126 (W2) (servicelb ETP=Local, anti-affinity'd 2 pods). Serves **LAN clients only** — nodes + CoreDNS use public DNS (circular-dep break, see DNS chain)
- **RustDesk** (`rustdesk` ns, `apps/rustdesk/`) — self-hosted remote desktop (hbbs rendezvous + hbbr relay, 1 pod/2 containers). Single mixed-protocol LB Service `rustdesk` on ports 21115/TCP, 21116/TCP+UDP, 21117/TCP; pod pinned to **W1**, so under servicelb ETP=Local servicelb advertises and serves only **192.168.1.129**, so clients use .129. **LAN and WARP only**: no public hostname, because 21116/UDP is mandatory and a Cloudflare Tunnel public hostname cannot carry RustDesk's UDP. Remote clients come in over Cloudflare WARP through the cloudflared pod. Deny-all egress NP (no upstream needed; also defense-in-depth for CVE-2026-30784 UDP-reflection). Ingress restricted to `192.168.1.0/24` (LAN, ETP=Local source preserved) OR `cloudflare-tunnel` ns (WARP-routed via cloudflared pod) — no other cluster source can reach it. **`-k _` is NOT full auth**: from master source it enforces the key only on the TCP `PunchHoleRequest` (connect-to-peer) path — registration (`RegisterPk`) and the `PunchHoleSent`/`LocalAddr` reflection handlers take no key. Maintainer commit `80d3a505` only disabled UDP `PunchHoleRequest` (does NOT stop reflection), so self-building master is no fix. Reflection is contained here by LAN-and-WARP-only reachability + deny-all-egress. Client key = `kubectl exec -n rustdesk deploy/rustdesk -c hbbs -- cat /data/id_ed25519.pub`
- **warp-beacon** (`rustdesk` ns, `apps/rustdesk/beacon-*.yaml`) — Cloudflare Zero Trust managed-network TLS beacon: `nginx-unprivileged` with a 10-yr self-signed cert on **192.168.1.129:18443** (same W1 ETP=Local pin). WARP clients probe it on network change, match the SHA-256 pinned in the ZT `home-lan` managed network → "Home LAN - direct" profile (tunnel nothing at home); unreachable away → Default profile (tunnel `.129/32`). NP: ingress 8443/TCP from LAN only, deny-all egress — **deliberately not tunnel-reachable** (off-LAN detection must fail). Cert rotation = coordinated event: subPath mounts don't hot-reload AND the dashboard fingerprint must change in the same window.
- **CoreDNS** `10.43.0.10` cluster-internal (`infrastructure/coredns/`, coredns-ha DaemonSet). **Never `--disable=coredns`** — it deletes addon-owned kube-dns objects Flux can't recreate (Flux fetches source over the deleted DNS → all reconciles stall); break-glass: `kubectl apply -k infrastructure/coredns/`

## Service endpoints
| Service | Endpoint | Used by |
|---------|----------|---------|
| Postgres pooler (PgBouncer, transaction mode) | `main-postgres-rw-pooler.databases.svc:5432` | linkwarden, paperless-ngx, mealie, n8n (verified 2026-10-02 from live specs and pooler login logs). Each app's SOPS env Secret holds the host; check with `sops -d <app secret> \| grep -o 'main-postgres-rw[a-z-]*'` |
| Postgres direct | `main-postgres-rw.databases.svc:5432` | immich server (its startup advisory lock fails under transaction pooling), authentik (server and worker; the Secret names the pooler, but a Deployment `env` entry overrides it), blocky (query log), the wait-for-database init containers of mealie, n8n and immich, immich's admin-setup Job, the backup and extension Jobs |
| MySQL HAProxy | `main-mysql-haproxy.databases.svc:3306` | uptime-kuma, home-assistant, pricebuddy |
| Redis HA master (static) | `redis-replication-master.databases.svc:6379` | paperless, blocky, immich |
| Redis HA Sentinel | `redis-sentinel-sentinel.databases.svc:26379` | operator-internal failover only; no direct app clients |
| CouchDB | `couchdb-couchdb.databases.svc:5984` | obsidian (LiveSync via Cloudflare Tunnel) |

## Traefik middlewares
Defined in `traefik` ns, in `infrastructure/configs/traefik-middlewares/` (applied by `infrastructure-configs`, after the Traefik chart installs the Middleware CRD); referenced as `traefik-<name>@kubernetescrd`:
`csp`, `csp-strict-enforced`, `csp-inline-enforced`, `csp-permissive-enforced`, `rate-limit-standard`, `rate-limit-high-frequency`, `redirect-https`, `security-headers`, `authentik-forward-auth`

CSP tiers are **enforced-only** (report-only middlewares deleted — dead config). `report-uri` omitted everywhere: a cluster-internal report sink is browser-unreachable (Mixed-Content) — verify CSP via browser console, not Loki. Tier membership: [apps.md](apps.md).

Older copies also live in the `monitoring` namespace (`csp`, `rate-limit-standard`, `redirect-https`, `security-headers`) for the kube-prometheus-stack ingresses, next to `alertmanager-basic-auth`.

## NetworkPolicy invariants
- NP on every ingress + every cross-ns egress (live count: HOMELAB_ANALYSIS.md; gap-finder: `k8s-diagnostics` skill)
- Default-deny implicit per-ns where an NP exists with empty ingress
- **Container port (NOT service port)** in NP `ports:`
- Dual access (internal + Cloudflare Tunnel) = 1 Traefik Ingress + 1 hostname row in `cloudflared-config-secret.yaml`, and 2 `from` rules in the app's NP (`traefik` ns, `cloudflare-tunnel` ns)
- **allow-dns-egress** = Kustomize Component (`apps/components/allow-dns-egress/`); pod-selector excludes Jobs (`batch.kubernetes.io/job-name DoesNotExist`) so Jobs don't silently inherit DNS egress
- Per-Job egress NPs (selector `batch.kubernetes.io/job-name=<job>`): `audiobookshelf-init-egress`, `home-assistant-admin-setup-egress`, `immich-admin-setup-egress`, `n8n-user-provision-egress`. The `immich-vm-heal` CronJob's pods get `immich-vm-heal-egress`, selected by `app.kubernetes.io/name: immich-vm-heal`
- mealie + uptime-kuma Jobs deliberately NP-naked (by decision)

## Cloudflare Tunnel
- Central config: `infrastructure/configs/cloudflare/cloudflared.yaml` + SOPS Secret `cloudflared-config-secret.yaml` (source of truth for external hostnames). **New external app = entry here, NOT a 2nd Ingress.**
- Externally exposed (verified 2026-09-27 from SOPS; re-derive: `sops -d infrastructure/configs/cloudflare/cloudflared-config-secret.yaml | grep hostname`): authentik, couchdb, audiobooks, linkwarden, stirling, mealie, paperless, immich, n8n
- Config sync via `PUT /accounts/{acct}/cfd_tunnel/{tunnel}/configurations` from the SOPS Secret; account + tunnel IDs inside it
- Mgmt token in `cloudflare-tunnel-mgmt-token` Secret — expiry tracked in [SECRETS_ROTATION.md](../SECRETS_ROTATION.md)
- Traffic path gotcha: tunnel hops `cloudflared → Service` directly — Traefik middlewares (CSP/headers/rate-limit) apply to the **internal path only**; external visitors get Cloudflare WAF + whatever the app itself sets (see ARCHITECTURE.md traffic flow)

## DNS chain
1. LAN client → Blocky LB IP (.129 or .126) :53
2. Blocky checks ACL → cache → upstream (DoH: Cloudflare Security + Quad9)
3. Nodes (containerd, system) → systemd-resolved → **public DNS 1.1.1.1 / 9.9.9.9** — **NOT blocky** (breaks the node→blocky→kube-proxy-servicelb circular dep at boot). resolved stays uplink-mode (real IPs, not 127.0.0.53); networkd `UseDNS=no` drops the DHCP/RA-supplied blocky DNS, a resolved global drop-in supplies public.
4. Cluster pods → CoreDNS (`10.43.0.10`); `forward . /etc/resolv.conf` → node resolv.conf (= public, per step 3). Pods snapshot resolv.conf at creation → `rollout restart ds/coredns-ha` after any node-DNS change. coredns-ha is a **DaemonSet** — guarantees a node-local replica (a soft topologySpread kept skewing; a node with 0 local replicas + VXLAN issue = total pod-DNS loss there). PDB `minAvailable: 1` + updateStrategy `maxUnavailable: 1`.
5. Mac per-domain resolver `/etc/resolver/h0melab.work` forces `*.h0melab.work` to LAN IPs (bypasses VPN-pushed public DNS)

**Blocky `connectIPVersion: v4` is permanent** — K3s podCIDR is v4-only, dual-stack decided NOT-WORTH-IT. Blocky pods can't initiate v6; v4-only DoH upstreams cover all needs.

## UFW firewall (post-reboot drift gotcha)
Workers use `ufw-heal-post-k3s.service` (oneshot, after k3s.service) to re-apply ip6tables rules that K3s flannel CNI clobbers on boot. Phase C rule split (`community.general.ufw` module) preserves order. Verification metric: `ufw_chains_healthy` (textfile collector). If alert fires: `sudo systemctl start ufw-heal-post-k3s.service` + `sudo systemctl start ufw-state-metric.service`.

## TLS / certs
- **cert-manager** with Cloudflare DNS-01 challenge
- One Certificate per ingress hostname, in the namespace that serves it (for example `authentik/authentik-tls`, `databases/couchdb-tls-cert`, `monitoring/grafana-tls`); no wildcard certificate. Two more (`main-mysql-ca-cert`, `main-mysql-ssl`) are MySQL's internal TLS.
- HSTS via `traefik-security-headers@kubernetescrd` — `max-age=31536000; includeSubDomains; preload` (customResponseHeaders, not Traefik sts* fields)
- `minTlsServeVersion: 1.3` on Blocky is inert — no DoT/DoH server configured; don't "fix" it

## Host firewall (UFW via ansible)
- The ansible role `firewall` applies the UFW rules on every node (`node-maintenance/ansible/`); the rules, the defaults and the IPv6 behaviour are in [SECURITY.md](../SECURITY.md#node-firewall)

| Port | Source | Nodes |
|---|---|---|
| 6443 | LAN | control plane |
| every port | node IPs, pod and service networks | all |
| 65300 (SSH) | LAN | all |
| 8472/UDP (flannel) | LAN | worker-node-2 |

Every incoming rule names an IPv4 source, so no rule is open over IPv6. `ufw_rules_absent` in `group_vars/all.yml` deletes the old no-source rules.
