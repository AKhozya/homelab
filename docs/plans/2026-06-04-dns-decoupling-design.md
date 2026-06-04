# Node DNS decoupling — break the node→blocky circular dependency

**Date:** 2026-06-04
**Status:** design (approved Option A)
**Trigger:** 2026-06-04 CSP/DNS incident hardening follow-up. See `gotcha_k3s_reboot_ordering.md` "2026-06-04 incident" delta #3.

## Problem

All 3 nodes' upstream DNS = `192.168.1.129` + `192.168.1.126` (the worker IPs = blocky's K3s servicelb LB IPs). blocky runs as cluster pods (W1+W2). CoreDNS Corefile `forward . /etc/resolv.conf`, and the coredns-ha Deployment uses `dnsPolicy: Default` → CoreDNS pods inherit the node resolv.conf → cluster-external DNS (flux→github) flows CoreDNS → node upstream → blocky pod.

**Circular path (exact):** `node → 192.168.1.129:53 → K3s servicelb (LoadBalancer, ETP=Local) → kube-proxy iptables DNAT → blocky pod → DoH Cloudflare/Quad9`. A worker kube-proxy/flannel wedge kills the `.129:53` DNAT *and* blocky's pod net together → cluster can't self-heal DNS. Self-amplifying.

blocky is more cluster-coupled than the loop alone: config has **`redis.required: true`** (databases ns, hard start dep), `queryLog` → CNPG postgres (soft), `clientLookup` → `10.43.0.10` CoreDNS (soft).

## Goal

Nodes (and therefore CoreDNS upstream) resolve DNS with **zero dependency on any cluster pod / kube-proxy / flannel**, so a cluster networking blip cannot take out node + CoreDNS external DNS. Preserve blocky adblock for LAN client devices.

## Investigation findings (2026-06-04, read-only)

| Fact | Value | Source |
|---|---|---|
| Resolver stack | systemd-networkd + systemd-resolved, uplink mode; `/etc/resolv.conf` → `/run/systemd/resolve/resolv.conf`. NM/dhcpcd off | SSH all 3 nodes |
| DNS source (CP, W1) | `DHCP=yes`, no static DNS → router DHCP DNS option hands out `.129`,`.126` | `10-enp3s0.network`, `20-ethernet.network` |
| DNS source (W2) | static `20-wired-static.network`: `DNS=192.168.1.129` + `DNS=1.1.1.1` (already half-decoupled) | W2 `.network` |
| IPv6 DNS | `fe80::1` (router link-local) via IPv6 RA — router, **not** cluster | resolvectl |
| Ansible coverage | does **NOT** manage these `.network` files (hand-placed Aug/Dec 2025). `hardening` owns only `resolved.conf.d/no-llmnr.conf`; `base_config` owns `/etc/hosts` LAN block | role grep |
| CoreDNS | `forward . /etc/resolv.conf`; Deployment `dnsPolicy: Default`; 3 replicas; **no NetworkPolicy** restricting egress | `infrastructure/coredns/` |
| coredns-ha placement | W1 ×1, CP ×2, **W2 ×0** | kubectl |
| blocky | `spx01/blocky:v0.31.0`, 2 replicas pinned W1/W2, anti-affinity; LoadBalancer + servicelb → `.129`/`.126`; `redis.required:true`; DoH upstream | manifests + decrypted config |
| host `:53` | only loopback `127.0.0.53`/`127.0.0.54` (resolved) + `5353` mDNS bound → **node-IP:53 free** | `ss` all nodes |
| k3s resolv-conf | no `--resolv-conf` override; `/var/lib/rancher/k3s/agent/etc/resolv.conf` absent → kubelet/CoreDNS use host `/etc/resolv.conf` | SSH |
| UFW | incoming=deny, outgoing=**allow**, routed=deny → node→public:53 egress works, no new rule needed | `group_vars/all.yml` |

## Decision

**Option A — pin nodes to a static cluster-independent upstream; leave blocky untouched.**

Override the DHCP-provided DNS on the 3 nodes only → static `1.1.1.1` + `9.9.9.9`. Router DHCP DNS option stays = blocky, so **LAN client adblock is unchanged**. Nodes/pods lose adblock + DoT — near-zero value (node queries are github/ghcr/registries/NTP, not ad domains).

Rejected alternatives:
- **B (blocky hostNetwork DaemonSet):** redis `required:true` → hostNetwork pod still reaches redis ClusterIP via kube-proxy, so the wedge isn't escaped; **Kyverno `disallow-host-namespaces` is Enforce** → hostNetwork denied without a ns exception. Partial goal, high friction.
- **C (blocky off-cluster host service):** meets goal but must set `redis.required:false`/in-memory + drop queryLog, plus a whole new node-side service surface. Over-engineered for marginal node adblock.
- **D (router primary + public fallback):** if the router's own resolver forwards to blocky it stays circular; unverifiable without router access. Public-only is strictly safer.

## Design — implementation

Keep resolved **uplink mode** (real IPs in resolv.conf, never the `127.0.0.53` stub — a loopback resolv.conf makes k3s generate its own and the change wouldn't propagate).

### Change 1 — ansible networkd DNS drop-in (per node)

New `hardening`-role task deploys `/etc/systemd/network/<primary>.network.d/10-dns.conf`:

```ini
[Network]
DNS=1.1.1.1
DNS=9.9.9.9

[DHCP]
UseDNS=no

[IPv6AcceptRA]
UseDNS=no
```

- `UseDNS=no` (DHCP + RA) stops resolved consuming the router-supplied DNS (the blocky IPs + `fe80::1`). `[IPv6AcceptRA] UseDNS=no` is optional — `fe80::1` is the router, not the cluster, so keeping it is a benign fallback; dropping it gives a deterministic upstream.
- Drop-in (not file rewrite) preserves hand-tuned `.network` (W1 RouteMetric, W2 static address).
- Per-host var maps the NIC `.network` filename: CP `10-enp3s0.network`, W1 `20-ethernet.network`, W2 `20-wired-static.network`.
- Handler: `networkctl reload` + `resolvectl flush-caches`. DNS-only change → no address/route reconfigure → **link does not flap → SSH survives**. Never `systemctl restart systemd-networkd`.

### Change 2 — restart CoreDNS to re-read upstream

CoreDNS `dnsPolicy: Default` copies node resolv.conf at **pod creation**; the `forward` plugin reads it at startup. Running pods keep the old upstream until restarted. After the node changes: `kubectl rollout restart deploy/coredns-ha -n kube-system` (serialized — `cluster-roll`). Node-level resolution + containerd pulls pick up the change immediately (not pods).

### Rollout order — W2 → W1 → CP

DNS is load-bearing; one node at a time, verify between.

1. **W2 first** — hosts **0** coredns replicas, already static config (trivial edit + revert). Lowest blast radius.
2. **W1** — hosts 1 coredns replica.
3. **CP last** — hosts 2 coredns replicas + control plane. Highest blast radius.

Apply path: user-run sudo `ansible-playbook … --limit <node>` (Claude has no sudo), or scoped drift-heal. After each node:
- `resolvectl status` shows `DNS Servers: 1.1.1.1 9.9.9.9`; `cat /etc/resolv.conf`; `dig github.com` resolves; SSH still alive.

After all nodes + coredns restart:
- `fr` (flux reconcile) green; CoreDNS resolves `cluster.local` (internal, NodeHosts) **and** `github.com` (external→public); apps healthy; verify a coredns pod forwards externally (flux github source reconcile succeeds).

### Rollback

Delete `10-dns.conf` + `networkctl reload` → DHCP DNS (blocky) returns. `rollout restart deploy/coredns-ha` to revert pods. Per-node, clean.

## Residual risks (flagged, out of scope)

- **LAN-wide DNS SPOF unchanged:** all LAN clients → blocky → `redis.required:true`. A redis outage takes LAN DNS down. This task only breaks the node/CoreDNS loop so the *cluster* can self-recover. A 2nd off-cluster resolver, or `redis.required:false`, is a separate decision.
- **Security:** the `blocky` Postgres queryLog password surfaced in the design session transcript (encrypted at rest; decrypt access already held). Rotate if desired — low urgency.
- **First ansible apply shows drift** — net-new managed files; existing `.network` preserved (drop-in).

## Verification checklist

- [ ] W2: resolv.conf upstream = `1.1.1.1`,`9.9.9.9`; `dig github.com` ok; cluster healthy
- [ ] W1: same
- [ ] CP: same
- [ ] `rollout restart deploy/coredns-ha` complete (3/3)
- [ ] CoreDNS resolves internal (`*.cluster.local`) + external (`github.com`)
- [ ] `fr` green; flux github source `Ready`; no node resolv.conf entry = a worker IP
- [ ] blocky + LAN clients still using blocky (router DHCP unchanged)
