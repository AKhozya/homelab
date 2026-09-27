# Security

This page describes how the cluster is protected: who can reach what, how people sign in, how
each node's firewall is set, and what went wrong before. The in-cluster layers (admission policy,
which checks each workload before Kubernetes accepts it; NetworkPolicies; container limits) are in
[ARCHITECTURE.md](ARCHITECTURE.md#security-layers).

## Posture

| Area | State |
|---|---|
| Internet access | The published apps are reachable only through a Cloudflare Tunnel, which the cluster opens from the inside; the home router forwards no ports. Nine hostnames are published; the rest of the apps are LAN-only. On the nodes themselves, only 8472/udp accepts traffic from any source (see [Node firewall](#node-firewall)). |
| Sign-in | Authentik, passkey-first since 2026-06-05. Seven apps and Grafana use it through OIDC (the app hands sign-in to Authentik); Homepage sits behind Authentik forward-auth. |
| Admission | 12 Kyverno policies, all `Deny`, plus Pod Security Standards on every app namespace. |
| Network inside the cluster | Each app's NetworkPolicy lists the connections its pods may make and accept; any other connection to or from those pods is blocked. Kyverno's `require-networkpolicy` policy rejects a workload in an app namespace that has no NetworkPolicy. |
| Secrets | Encrypted in Git with SOPS and age. |
| TLS | cert-manager issues the ingress certificates, proving control of the domain through DNS records (a DNS-01 challenge). |
| Node firewall | UFW on every node denies incoming traffic by default; an Ansible role manages the rules. |
| Node SSH | Key-only, on port 65300; root login is off. |
| Updates | Renovate proposes image and chart updates; the nodes update weekly. |

## Reaching the apps from the internet

Internet traffic to the published apps enters only through the Cloudflare Tunnel. The `cloudflared`
pod opens the tunnel outward, so the home router forwards nothing inbound. Tunnel traffic goes from
`cloudflared` straight to each app's Service; it does not pass Traefik. So Traefik's security
headers, CSP (the rules for what a page may load) and rate limits apply only to LAN traffic.

| Hostname | App | Sign-in |
|---|---|---|
| `couchdb` | Obsidian sync | Cloudflare Access service token at the edge, then CouchDB's own password |
| `authentik` | Authentik | Authentik itself; no edge check |
| `audiobooks`, `immich`, `linkwarden`, `mealie`, `paperless`, `stirling` | those apps | Authentik, through OIDC; no edge check |
| `n8n` | n8n | n8n's own user accounts; no edge check |

[ARCHITECTURE.md](ARCHITECTURE.md#traffic-flow-two-ways-in) records why each hostname has or lacks
an edge check. Every sign-in page in the last three rows faces the internet, so a bug in one of
them is exposed to the internet, not only to the LAN. That is an accepted cost.

## Sign-in

### Authentik

Authentik is the identity provider. Since 2026-06-05 its main sign-in flow has no password step:

| Step | How |
|---|---|
| Normal sign-in | A passkey (WebAuthn) |
| Lost passkey | Username and a TOTP code (from an authenticator app), then enrol a new passkey |
| Lost passkey and TOTP | Authentik's email recovery flow |

A TOTP code can be phished; a passkey cannot. The owner keeps TOTP anyway, for account recovery
after losing a device. The blueprints that set this up are in `apps/authentik/blueprints/`, and
[runbooks/authentik-passkey-rollback.md](runbooks/authentik-passkey-rollback.md) undoes them.

The admin account is `akadmin`. The `authentik` hostname has no edge check, so its sign-in page,
including the TOTP and email recovery paths, is reachable from the internet.

### Apps that sign in through Authentik

| App | Method | App's own password login |
|---|---|---|
| Grafana | OIDC | off (`disable_login_form: true`, `auth.basic.enabled: false`) |
| Immich | OIDC | set in the app's web UI, not in Git |
| Paperless-NGX | OIDC | off (`PAPERLESS_DISABLE_REGULAR_LOGIN`) |
| Linkwarden | OIDC | off (`NEXT_PUBLIC_CREDENTIALS_ENABLED: false`) |
| Stirling-PDF | OIDC | off (`loginMethod: oauth2`) |
| Mealie | OIDC | off (`ALLOW_PASSWORD_LOGIN: false`) |
| Audiobookshelf | OIDC | set in the app's web UI, not in Git |
| Home Assistant | OIDC | on, for one emergency account |
| Homepage | forward-auth: Traefik asks Authentik before it passes each request on | — |

n8n has no SSO, because SSO is a paid n8n feature; its own user accounts apply.

### If Authentik is down

| App | Way in |
|---|---|
| Home Assistant | The local emergency account `akhozya`. Its password is in 1Password, not in this repo, and 1Password keeps it available offline. This matters because Home Assistant controls physical devices. |
| Apps whose own login is still on | Their own login |
| Apps with password login off | Wait for Authentik, or restore it from backup |

## Node firewall

### Where the rules live

UFW runs on every node. Ansible manages the rules: the role
[`node-maintenance/ansible/roles/firewall/`](../node-maintenance/ansible/roles/firewall/) applies
them, and the `firewall_preflight` role runs first to settle the kernel's packet-filter state.

| File, under `node-maintenance/ansible/` | Rules |
|---|---|
| `group_vars/all.yml` | `ufw_rules_base` (every node) and `ufw_rules_absent` (rules to delete) |
| `group_vars/control_plane.yml` | the control plane's extra rules |
| `group_vars/workers.yml`, `group_vars/virtual.yml` | worker and VM group rules (none today) |
| `host_vars/<node>.yml` | per-node rules |

The drift-heal run (the Ansible run that puts each node back to its declared state) applies them
at 03:00 and 15:00 UTC and after every merge to `main`.

The role only adds rules. If you drop a rule from a list, the live rule stays; name it in
`ufw_rules_absent` to delete it. If a list still declares a rule that someone deleted by hand, the
next run restores it. Never run `ufw --force reset`: it removes every rule the role added. To repair a
broken firewall, run `sudo systemctl start node-maintenance-config.service`.

### Defaults and rules

| Policy | Value |
|---|---|
| Incoming | deny |
| Outgoing | allow |
| Routed | deny |

| Allowed in | From | Nodes |
|---|---|---|
| SSH, 65300/tcp | LAN (192.168.1.0/24) | all |
| any port | the four node IPs | all |
| any port | pod network 10.42.0.0/16 and service network 10.43.0.0/16 | all |
| port 80, TCP and UDP | LAN | all |
| 443/tcp | LAN | all |
| 8472/udp (flannel VXLAN, which carries pod traffic between nodes) | any source | all |
| Kubernetes API, 6443/tcp | LAN | control plane |

So SSH is open to the LAN, to the other nodes and to pods, not to the internet.

**IPv6.** Every node has a public IPv6 address, and a UFW rule with no source opens its port over
IPv6 as well. 8472/udp is the only rule with no source today, so it is the only port that accepts
traffic from anywhere, over IPv4 or IPv6.

### SSH

`roles/hardening/files/sshd-99-hardening.conf` sets these on every node:

| Setting | Value |
|---|---|
| Password and keyboard-interactive login | off; keys only |
| Root login | off |
| Tries per connection | 3 |
| Key exchange | post-quantum `mlkem768x25519-sha256` first |

fail2ban watches port 65300 and bans a source after 3 failures.

### Check a node

The rule files are readable without sudo:

```bash
cat /etc/ufw/user.rules /etc/ufw/user6.rules
```

With sudo, `ufw status numbered` lists the rules and `ss -tulpn` lists the listening ports.

## Incidents

| Date | What was open | Fix |
|---|---|---|
| 2025-10-30 | A firewall audit found the Kubernetes API (6443/tcp) open to any source, and SSH (65300) and Prometheus (9090) open over IPv6. The rules dated from the first setup. The API needs authentication, so the risk was medium. | The three rules were deleted by hand the same day. |
| 2026-09-27 | The Ansible lists still declared 6443/tcp and 10250/tcp (the kubelet API) with no source, and immich-vm kept a 22/tcp rule from its build; with no source, each was open over IPv6. immich-vm also still accepted SSH passwords. Requests without credentials to the API server and the kubelet were refused (HTTP 401), before and after. | `ufw_rules_absent` deletes the three rules on every drift-heal run, and the SSH settings above now apply to every node (`fd6dc2e2`). |

## Accepted risks and when to revisit

| Risk | Accepted because | Revisit if |
|---|---|---|
| App sign-in pages face the internet | Each app has its own sign-in, most through Authentik | If an app's sign-in has a published vulnerability, or the logs show attacks on it |
| No VPN in front of admin pages | Passkey sign-in; one admin | If Authentik shows suspicious sign-ins, a second person gets admin access, or the cluster starts holding financial or medical data |
| TOTP as a recovery path | Keeps account recovery possible after losing a passkey | If the owner detects a TOTP phishing attempt |
| No offsite backup | The nodes and the NAS share one building; the owner accepts that ([ARCHITECTURE.md](ARCHITECTURE.md#deliberate-simplifications)) | See [BACKUP_STRATEGY.md](BACKUP_STRATEGY.md) |

This page has no review date of its own. The monthly review checks the nodes' security scans.
