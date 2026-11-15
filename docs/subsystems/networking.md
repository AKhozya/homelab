# Networking map

## Ingress
- **Traefik** (`traefik` ns, chart in `infrastructure/controllers/traefik/release.yaml`) handles all `*.h0melab.work` via K8s `Ingress` (class=traefik); no IngressRoute CRDs in use
- **Cloudflare Tunnel** (`cloudflare-tunnel` ns) — outbound-only, zero inbound router ports; see topology below
- **Blocky DNS** (`blocky` ns, `apps/blocky/`) — single LB Service `blocky-dns` exposes 192.168.1.129 (W1) + 192.168.1.126 (W2) (servicelb ETP=Local, anti-affinity'd 2 pods). Serves **LAN clients only** — nodes + CoreDNS use public DNS (circular-dep break, see DNS chain)
- **RustDesk** (`rustdesk` ns, `apps/rustdesk/`) — self-hosted remote desktop (hbbs rendezvous + hbbr relay, 1 pod/2 containers). Single mixed-protocol LB Service `rustdesk` on 21115/TCP, 21116/TCP+UDP, 21117/TCP. The pod is pinned to **W1**, so under servicelb ETP=Local only **192.168.1.129** serves it, and clients use .129.
  - **LAN and WARP only**: 21116/UDP is mandatory, and a Cloudflare Tunnel public hostname cannot carry UDP. Remote clients come in over Cloudflare WARP through the cloudflared pod.
  - NP: ingress only from `192.168.1.0/24` (ETP=Local preserves the LAN source) or the `cloudflare-tunnel` ns; deny-all egress (nothing upstream is needed, and it limits CVE-2026-30784 UDP reflection).
  - **`-k _` is NOT full auth**: in the master source it checks the key only on the TCP `PunchHoleRequest` (connect-to-peer) path. Registration (`RegisterPk`) and the `PunchHoleSent`/`LocalAddr` reflection handlers take no key. Maintainer commit `80d3a505` only disabled UDP `PunchHoleRequest` and does NOT stop reflection, so building master is no fix. The reachability limits and deny-all egress above contain it.
  - Client key: `kubectl exec -n rustdesk deploy/rustdesk -c hbbs -- cat /data/id_ed25519.pub`
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

CSP tiers are **enforced-only**, with no `report-uri`. Tiers, membership and how to verify: [apps.md](apps.md).

Older copies also live in the `monitoring` namespace (`csp`, `rate-limit-standard`, `redirect-https`, `security-headers`) for the kube-prometheus-stack ingresses, next to `alertmanager-basic-auth`.

## NetworkPolicy invariants
- NP on every ingress + every cross-ns egress (live count: HOMELAB_ANALYSIS.md; gap-finder: [`k8s-diagnostics`](../../agents/skills/k8s-diagnostics/SKILL.md))
- Default-deny implicit per-ns where an NP exists with empty ingress
- **Container port (NOT service port)** in NP `ports:`
- Dual access (internal + Cloudflare Tunnel) = 1 Traefik Ingress + 1 hostname row in `cloudflared-config-secret.yaml`, and 2 `from` rules in the app's NP (`traefik` ns, `cloudflare-tunnel` ns)
- **allow-dns-egress** = Kustomize Component (`apps/components/allow-dns-egress/`); pod-selector excludes Jobs (`batch.kubernetes.io/job-name DoesNotExist`) so Jobs don't silently inherit DNS egress
- Per-Job egress NPs (selector `batch.kubernetes.io/job-name=<job>`): `audiobookshelf-init-egress`, `home-assistant-admin-setup-egress`, `immich-admin-setup-egress`, `n8n-user-provision-egress`. The `immich-vm-heal` CronJob's pods get `immich-vm-heal-egress`, selected by `app.kubernetes.io/name: immich-vm-heal`
- The mealie and uptime-kuma Jobs have no NP of their own, by design: their labels (`app: mealie-user-provision`, `app: uptime-kuma-setup`) match no policy, so their egress is open

## Cloudflare Tunnel
- Central config: `infrastructure/configs/cloudflare/cloudflared.yaml` + SOPS Secret `cloudflared-config-secret.yaml` (source of truth for external hostnames). **New external app = entry here, NOT a 2nd Ingress.**
- Externally exposed (verified 2026-09-27 from SOPS; re-derive: `sops -d infrastructure/configs/cloudflare/cloudflared-config-secret.yaml | grep hostname`): authentik, couchdb, audiobooks, linkwarden, stirling, mealie, paperless, immich, n8n
- Config sync via `PUT /accounts/{acct}/cfd_tunnel/{tunnel}/configurations` from the SOPS Secret; account + tunnel IDs inside it
- Mgmt token in `cloudflare-tunnel-mgmt-token` Secret — expiry tracked in [SECRETS_ROTATION.md](../SECRETS_ROTATION.md)
- Traffic path gotcha: tunnel hops `cloudflared → Service` directly — Traefik middlewares (CSP/headers/rate-limit) apply to the **internal path only**; external visitors get Cloudflare WAF + whatever the app itself sets (see ARCHITECTURE.md traffic flow)

## LAN

| Item | Value |
|---|---|
| Gateway | the eero at 192.168.1.1 ([runbook](../runbooks/lan-router-eero-migration.md)) |
| ISP router (ZTE) | off. The operator keeps it for rollback |
| DHCP pool | .20 to .99; the eero's leases last 4 hours |
| DNS the eero provides | .129 (cluster Blocky) and .127 (CP Blocky fallback), custom DNS in the eero app |
| Node addresses | static on each node: CP .127, worker-node .129, worker-node-2 .126, immich-vm .231. Ansible writes the file from `static_ipv4` in host_vars (hardening role, tag `networkd-static`); W2's file is still hand-made. The eero also reserves each address by MAC |
| NAS address | .136 by DHCP, a 4-hour lease from the eero |
| NAS reservation | the eero reserves .136 for the NAS |
| eero network | one network, `z3us`: Cupboard is the gateway (ONT on port 2, the MS308 switch on port 1); Office and Living Room connect to the gateway by cable through the MS308 |

**eero settings** (read in the eero app 2026-11-15):

| Setting | Value | Why |
|---|---|---|
| DHCP & NAT | Manual IP, 192.168.1.0/24, pool .20 to .99 | 80 addresses cover about 40 devices. The fixed addresses are outside the pool |
| DNS | custom: .129 and .127; IPv6 fields empty | Blocky has no IPv6 address |
| Local DNS caching | off | if on, the eero answers DNS itself, and Blocky logs every query as the eero's |
| IPv6 | off | the Mac gets private IPv6 addresses and IPv6 routers but lists only .129 and .126 as DNS servers. The NAS lists no IPv6 DNS server. These observations date from 2026-11-15. If you turn IPv6 on, the eero restarts the network. Check the DNS servers on the Mac again afterwards |
| UPnP | off | it lets any LAN device open an inbound port with no login. If a console reports a strict NAT type, turn it back on |
| SQM | on | the 500 Mbit line measures 487 Mbit/s from a wired node with SQM on. No test with SQM off has run |
| Encryption | 2.4 GHz WPA2; 5 GHz WPA2 + WPA3 (Hybrid); 6 GHz WPA3 | older smart-home devices use 2.4 GHz. If a device fails to join on 5 GHz, set 5 GHz back to WPA2 |
| Thread | on, with keychain syncing | the household's smart-home devices may use it |
| Client steering | on | — |
| eero Simple Setup, Dynamic DNS, Guest Wi-Fi | off | no current use |
| Amazon Connected Home | state not read | the operator does not use it |

## DNS chain
1. LAN client → the DNS servers the eero's DHCP hands out, port 53: the two IPv4 entries of the eero's custom DNS, its only two (table below)
2. Blocky checks ACL → cache → upstream (DoH: Cloudflare Security + Quad9)

| eero DNS entry | Address | Server |
|---|---|---|
| primary | 192.168.1.129 | cluster Blocky |
| secondary | 192.168.1.127 | **CP Blocky fallback** |

**CP Blocky fallback** (role `blocky_fallback`): a systemd service on the CP, outside Kubernetes. LAN clients use the fallback during a cluster Blocky failure (servicelb, kube-proxy, both pods).

| Fact | Value |
|---|---|
| Config | derived from `apps/blocky/config.yml` on every node-config run: same lists, allowlists, `customDNS`. Drops Redis, the Postgres query log, `clientLookup` and metrics; `queryLog: none` |
| Guard | the run fails if `blocking.clientGroupsBlock` has a key other than `default`, because the fallback cannot match client names |
| Safety | `blocky validate` gates each new config; an invalid one leaves the old config running |
| Version | `blocky_fallback_version` in the role defaults; Renovate bumps it 7 days after release, separately from `spx01/blocky` |
| Alerts | `BlockyFallbackDown`, `BlockyFallbackNoUpstream`, `BlockyFallbackProbeMissing`, from a 1-minute DNS probe (`blocky_fallback.prom`) |
| Not covered | a valid config change that resolves wrongly reaches both copies within one sync |
3. Nodes (containerd, system) → systemd-resolved → **public DNS 1.1.1.1 / 9.9.9.9** — **NOT blocky** (breaks the node→blocky→kube-proxy-servicelb circular dep at boot). resolved stays uplink-mode (real IPs, not 127.0.0.53); networkd `UseDNS=no` drops the DHCP/RA-supplied blocky DNS, a resolved global drop-in supplies public.
4. Cluster pods → CoreDNS (`10.43.0.10`); `forward . /etc/resolv.conf` → node resolv.conf (= public, per step 3). Pods snapshot resolv.conf at creation → `rollout restart ds/coredns-ha` after any node-DNS change. coredns-ha is a **DaemonSet** — a node-local replica on every node except immich-vm, whose taint it does not tolerate (a soft topologySpread kept skewing; a node with 0 local replicas + VXLAN issue = total pod-DNS loss there). PDB `minAvailable: 1` + updateStrategy `maxUnavailable: 1`.
5. Mac per-domain resolver `/etc/resolver/h0melab.work` forces `*.h0melab.work` to LAN IPs (bypasses VPN-pushed public DNS)

**Blocky `connectIPVersion: v4` is permanent** — K3s podCIDR is v4-only, dual-stack decided NOT-WORTH-IT. Blocky pods can't initiate v6; v4-only DoH upstreams cover all needs.

**Blocky config** is plain text in `apps/blocky/config.yml`; its comments give the reason where a setting needs one. The SOPS Secret `apps/blocky/credentials-secret.yaml` holds only the Redis password and the query-log DSN, which the config reads with `file:` (Blocky v0.31+).

## UFW firewall (post-reboot drift gotcha)
At boot, kube-proxy, flannel and fail2ban write netfilter rules while UFW's `iptables-restore` runs, which can leave UFW chains (typically `ufw6-*`) missing. Every node runs `ufw-heal-post-k3s.service` (oneshot, after `k3s-wait-ready.service`): it creates each missing chain, then reloads UFW (`node-maintenance/ansible/roles/firewall/files/ufw-heal-post-k3s.sh`). Metric: `ufw_chains_healthy` (textfile collector). If `UfwChainsUnhealthy` fires: `sudo systemctl start ufw-heal-post-k3s.service` + `sudo systemctl start ufw-state-metric.service`.

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
