# Home IPv6 Enablement Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** turn IPv6 on at the eero with ad blocking intact, nothing new reachable from the internet, and a tested revert.

**Architecture:** only the CP's systemd Blocky fallback answers DNS over IPv6, on a fixed suffix of the eero's private range. The eero announces that one address as its only IPv6 DNS server. The workers and immich-vm take no IPv6 addresses. The NAS keeps link-local addresses only.

**Tech stack:** eero app (firmware 7.x), systemd-networkd, UFW, Blocky v0.36.0 (role `blocky_fallback`), node-exporter textfile metrics, VMRule alerts.

**Status:** reviewed (Codex). Task 0 and the spike ran on 2026-11-15, except the NAS line. Tasks 1-3 are in review. The IPv6-on window has not run.

**Spec:** the operator's request of 2026-11-15: research IPv6, find the firewall rules needed on the eero, the homelab and elsewhere, and give a mitigation for each risk. There is no separate spec file.

## Global Constraints

| Constraint | Detail |
|---|---|
| Public repo | no prefix, no global address, no EUI-64 address, no MAC. Ansible reads prefixes live on the node |
| Change path | repo change → PR → `node-maintenance-sync`. The NAS is the exception: Ansible does not manage it, so the operator changes it by hand |
| eero | the operator makes every eero change. iPhone Mirroring cannot type |
| Network restarts | before each one: a watcher that survives the internet loss, a printed resume note, a printed revert path |
| Timing | not near 03:00 (backups) or the Saturday 04:30 reboot window |

## Decision status

| Question | State |
|---|---|
| Is IPv6 worth it? | The gains are small (see [Benefit](#benefit)). The operator said go on 2026-11-15, and decides to keep IPv6 or turn it off at the end of Task 6 |
| Per-device logs for IPv6 lookups | option B, Loki for 7 days (operator, 2026-11-15) |
| Prefix in the repo | no: Ansible reads it live (operator, 2026-11-15) |

## Benefit

| Gain | Size here | Tier |
|---|---|---|
| Xbox peer-to-peer and party chat | helps only with another native-IPv6 player. Microsoft says Teredo is sometimes more reliable. It needs inbound IKE/ESP, and whether the eero allows that is unknown | 🟡 |
| PS5 | none: PSN, the store and games stay on IPv4 | 🟡 |
| Latency to CDNs | about equal on fibre. APNIC measured IPv6 within 10 ms of IPv4 in about 60% of cases | 🟡 |
| Thread / Matter | no change: they work with the eero's IPv6 off | ✅ |
| Reaching home from outside | not needed: services use the Cloudflare Tunnel | ✅ |

## Exposure and mitigation, per layer

| Layer | Risk with IPv6 on | Control 1 | Control 2 | Proof |
|---|---|---|---|---|
| eero gateway | the internet reaches LAN devices directly | the eero's stateful inbound block (default; eero support documents an opt-in "IPv6 Firewall Rules" list) | keep that list empty | W2b: external probe with a positive control |
| eero DNS | the eero announces Google's IPv6 DNS, so lookups skip Blocky | the fallback's address in the eero's IPv6 DNS field | alert `BlockyIPv6DNSBypass` from the CP's own RA read | W7: packet capture shows client lookups reach the fallback |
| CP (fallback host) | would gain a global address. sshd, 6443, 10250 and node-exporter listen on IPv6 too | `PrefixAllowList=fc00::/7`: the CP takes addresses on private prefixes only, so it has no global address | UFW active for IPv6, default deny; the only IPv6 allow is DNS from `fc00::/7` | W4: no global address. W5: a LAN test to node-exporter over the CP's private address is refused |
| worker-node, worker-node-2, immich-vm | gain global addresses that are reachable if the eero fails | `UseAutonomousPrefix=no`: no SLAAC addresses at all | UFW as on the CP. `UseGateway=no` on all nodes: no IPv6 default route | W4: `ip -6 addr show scope global` is empty |
| NAS (no host firewall, not in Ansible) | gains a global address with SMB, web UI and SSH on it | the operator sets `ipv6.method link-local` | the eero inbound block | W4: no global address |
| Pods / CoreDNS | RA DNS reaches the node's resolv.conf, and CoreDNS forwards to an IPv6 server it cannot reach | `[IPv6AcceptRA] UseDNS=no` drop-in on all nodes | pods have no IPv6 route, so a connect fails at once (⚠️ inferred) | W2: node `resolv.conf` unchanged; CoreDNS answers |
| Other home devices (TVs, consoles, plugs, Apple) | reachable only if the eero firewall fails | the eero inbound block | none: they have no host control we manage | W2b covers the eero |
| Blocky fallback process | if its IPv6 address is missing at boot, the IPv4 listener dies too | `ports.freeBind: true` | systemd restarts it | spike T3b |
| Loss of the only IPv6 DNS server | if the CP is down, lookups over IPv6 time out | clients keep the IPv4 servers .129 and .127 from DHCP | alert `BlockyFallbackDown` | W8: stop the fallback, time a fresh lookup |
| Per-device logs | the fallback keeps none. Apple rotates its IPv6 addresses daily, so attribution is weak whichever Blocky answers | Task 4 option | — | — |
| Prefix change by the ISP or the eero | the eero field holds a dead address, so IPv6 lookups time out | use the eero's private range, which lasts about 30 days, not the ISP's prefix | alert `BlockyIPv6DNSBypass` | W9: re-check after an eero restart |

## Assumptions

| # | Assumption | Tier | Validate in |
|---|---|---|---|
| A1 | The eero drops unsolicited inbound IPv6 by default | ✅ eero support + staff post | W2b (must pass) |
| A2 | The private range with a ≈30-day lifetime belongs to the eero and appears only while IPv6 is on | 🟡 Task 0: all 4 nodes still hold it, its valid lifetime counting down from 30 days since 00:47, so no router has refreshed it with IPv6 off | W3: `ndp -pn` names the gateway's link-local address |
| A3 | The Thread hubs withdraw their range (1800 s lifetime) once another on-link prefix exists | 🟡 OpenThread source | W9 (after more than 30 min) |
| A4 | The eero accepts a private (fd…) address in the IPv6 DNS field | ⚠️ no source | W7 |
| A5 | If one IPv6 DNS field is filled, the eero adds no public server | ⚠️ no source | W7 |
| A6 | The `UseDNS=no` drop-in is live on all 4 nodes | ✅ Task 0: `resolvectl dns` lists only 1.1.1.1 and 9.9.9.9, no link has a server | — |
| A7 | UFW filters IPv6 on all 4 nodes (`IPV6=yes`, ip6 chains loaded) | ✅ Task 0: `IPV6=yes`; `ufw6-user-input` exists and is empty on all 4 | — |
| A8 | A UFW rule `from fc00::/7` creates an IPv6 rule only | ✅ ufw parser | Task 2 check |
| A9 | With `freeBind`, Blocky listens on a missing IPv6 address and IPv4 keeps answering | ✅ spike T3b; T6 with the rendered config and full lists. Without `freeBind` (T3) the whole process exits | — |
| A10 | `UseAutonomousPrefix=no` stops SLAAC addresses | ✅ man page | Task 1 check |
| A11 | Clients use their private source address to reach a private DNS address | ✅ RFC 6724 | W7 capture |
| A12 | Hyperoptic's /56 is static | 🟡 forum | not needed if A2 holds |
| A13 | Turning IPv6 off removes the Google DNS servers from clients | ✅ observed 2026-11-15 00:50 (Mac lists IPv4 only; NAS lists no IPv6 DNS) | revert checks |
| A14 | `PrefixAllowList=fc00::/7` matches every prefix inside fc00::/7, not only that exact prefix | ✅ systemd source, `address_is_filtered` uses `in_addr_prefix_covers` since v250; nodes run 262 | W4 |
| A15 | Routers answer the probe's Router Solicitation with IPv6 off | ✅ probe run as root on the CP: `ra_heard 1`, `state="none"` | — |
| A16 | The probe's RDNSS parser reads the eero's real RA | 🟡 it reads the 3 RAs captured from the Thread routers (no RDNSS option). No eero RA exists yet | W3: capture one and add it to `tests/ras.json`, masked |

## Tasks

### Task 0: Live baseline with IPv6 off (read only)
- [x] On each node, run `grep IPV6 /etc/default/ufw`. Expect `IPV6=yes`.
- [x] On each node, the operator runs `sudo ip6tables -S ufw6-user-input`. Expect it to exist, with no allow rule.
- [x] On each node, run `networkctl cat <primary>` and expect `UseDNS=no` under `[IPv6AcceptRA]`. Run `resolvectl dns` and expect only 1.1.1.1 and 9.9.9.9.
- [x] Record the `ss -tulnH` listeners on `[::]` on each node. Result: sshd and mDNS on `[::]`; 6443 (CP), 10250 and 9100 on `*`, which is IPv4 and IPv6.
- [x] On the NAS, record `nmcli -g ipv6.method connection show <conn>` (used for its revert) and its `[::]` listeners. Result: the connection on `enp90s0` is `Wired connection 2`, method `auto`. On IPv6 it listens on SSH, 80, 443, 111 (rpcbind), 5432 (Postgres) and more, with no host firewall. It holds addresses on both private prefixes and none on the ISP's.
- [x] Run the CP spike `v6spike.sh` (unprivileged, high ports). T3/T3b: a missing address without and with `freeBind`. T4: an unreachable Postgres log. T5: the console log line.
- Abort rule: if A6 or A7 fails, fix it in Task 1 or Task 2 before anything else.

### Task 1: Node IPv6 addressing (hardening role)
**Files:** `roles/hardening/templates/primary-ipv6.conf.j2` (new drop-in), `roles/hardening/tasks/main.yml`, `group_vars/all.yml`, `host_vars/gmk-k3s-control-plane.yml`.
- [ ] Every node renders `[IPv6AcceptRA] UseGateway=no`: no node needs an IPv6 default route.
- [ ] Default `ipv6_ra_accept_addresses: false` renders `[IPv6AcceptRA] UseAutonomousPrefix=no`.
- [ ] The CP sets `ipv6_ra_accept_addresses: true` and `ipv6_token: "static:::53"`. That renders `[IPv6AcceptRA] PrefixAllowList=fc00::/7` and `Token=static:::53`.
- [ ] Write the drop-in to `/etc/systemd/network/<primary_network_file>.d/50-ipv6.conf`. It has to be a drop-in, because W2 has no `static_ipv4` and the template does not write its file.
- [ ] Check: on the workers, `ip -6 addr show scope global` is empty. The CP holds `<prefix>::53` on each private prefix and no other global address.

### Task 2: UFW
- [ ] In `host_vars/gmk-k3s-control-plane.yml` `ufw_rules_host`, add `{comment: "Blocky fallback DNS over IPv6 from private ranges", rule: allow, from_ip: "fc00::/7", to_port: 53, proto: udp}` and the same rule for tcp.
- [ ] `roles/firewall` asserts `IPV6=yes` and fails if it is missing. It does not rewrite the value, because that needs `ufw disable` and `enable`.
- [ ] `roles/firewall` refuses an allow rule with no source in the input lists `ufw_rules_base`, `ufw_rules_group` and `ufw_rules_host`. It does not check `ufw_rules_absent`, whose no-source entries delete old rules. It does not check the route lists either, such as worker-node-2's `{rule: allow, to_ip: 10.42.0.0/16}`, which names an IPv4 destination and so creates no IPv6 rule.
- [ ] Check: `ufw show added` lists the two IPv6 rules, and no other IPv6 allow rule exists.

### Task 3: Blocky fallback over IPv6
- [ ] If Ansible finds an `fd…::53` address whose valid lifetime is at least `blocky_fallback_v6_min_lifetime` (default 86400 s), `ports.dns` is `node_ip:53` plus `[<that address>]:53`. Otherwise `ports.dns` is `node_ip:53` only. Set `ports.freeBind: true` in both cases.
- [ ] Do not configure a `[::]:53` wildcard listener. If the spike runs without root, it cannot test coexistence with systemd-resolved on port 53.
- [ ] Check before any IPv6-on window: the operator runs the config once with `-e blocky_fallback_v6_min_lifetime=0`, so the fallback binds the CP's `::53` address in the Thread range. Before the test, check that the CP holds `<thread prefix>::53` (from Task 1) and that the Mac holds a different address in the same range (`ifconfig en0`). From the Mac, `dig @<thread ULA>::53 doubleclick.net` gives `0.0.0.0`. This proves the IPv6 listener and the `fc00::/7` UFW rule. The next normal run removes that listener.
- [ ] `tests/test-render.yml`: one case with a live ULA, one without.
- [ ] The probe queries the IPv6 listener too. As root, it also sends a Router Solicitation and parses the RDNSS option into `blocky_fallback_ra_rdnss{state="fallback_only|other|none"}`.
- [ ] VMRules: `BlockyIPv6DNSBypass` fires if RDNSS holds any address other than the fallback's (`for: 10m`). `BlockyFallbackV6Down` fires if the IPv6 listener does not answer.

### Task 4: Logs for IPv6 lookups (the operator decides)
| Option | What | Cost |
|---|---|---|
| A | none, as today for .127 | IPv6 lookups are not logged |
| B | `queryLog: console` in its own journald namespace; Alloy reads it into Loki (7 days) | about 87k queries/day today. The namespace keeps node-maintenance logs from being pushed out. Alloy needs a new journal source |
| C | Postgres log into the cluster's database, with console as fallback if it is unreachable | DB credentials on the CP host, and a NetworkPolicy for host traffic |

Chosen: B (operator, 2026-11-15). A journald namespace has a per-machine directory name, and Alloy's journal source takes one fixed path, so the candidate design is a Blocky `csv` log under the service's `LogsDirectory` (`/var/log/private/blocky-fallback`, 7 days through `logRetentionDays`), read by an Alloy file source. The bot's account can read the journal but not `/var/log/private`. This is a separate PR after Tasks 1-3, because it rolls the Alloy DaemonSet.

### Task 5: NAS (the operator, by hand)
- [ ] Run `sudo nmcli connection modify "Wired connection 2" ipv6.method link-local && sudo nmcli connection up "Wired connection 2"`. The NAS connection goes down briefly, and so does immich-vm's connection through it, so run it in a quiet hour.
- [ ] Check: `ip -6 -br addr show dev enp90s0 scope global` is empty.
- Revert: `sudo nmcli connection modify "Wired connection 2" ipv6.method auto && sudo nmcli connection up "Wired connection 2"`.

### Task 6: The IPv6-on window (operator and agent)
| Step | Who | Action | Pass | If it fails |
|---|---|---|---|---|
| W0 | operator + agent | The agent checks SSH to every node and the NAS. The operator keeps 1Password unlocked for the whole window, because most steps need SSH. The agent prints the watcher, resume note and revert path, starts the watcher, and records the eero DNS and IPv6 settings | SSH works everywhere; all printed | do not start |
| W1 | operator | eero → Settings → Advanced networking → IPv6 → on; wait about 5 min | the watcher logs "back" | revert |
| W2 | agent | nodes Ready; CoreDNS answers; each node's `resolv.conf` unchanged | all hold | revert |
| W2b | operator + agent | Mac: `python3 -m http.server --bind :: 8099`. The iPhone on the home Wi-Fi loads `http://[<Mac global address>]:8099` (LAN control; the CP cannot, because it has no global address and no IPv6 default route). The phone on mobile data confirms IPv6 at test-ipv6.com. The operator adds a temporary eero IPv6 firewall rule for the Mac port 8099; the phone loads the page (positive control). The operator deletes the rule; the phone retries. **On every exit from W2b, pass or fail:** the operator deletes the temporary rule. The operator confirms the eero's IPv6 firewall rule list is empty. The agent stops the HTTP server | page loads with the rule, fails without it; the rule list is empty at the end | do the exit cleanup, then revert |
| W3 | agent | Mac `ndp -pn` and `route -n get -inet6 default`: which router announces each prefix | the ≈30-day range comes from the gateway's link-local | stop: no stable range, so revert (or redesign on the ISP prefix) |
| W3b | operator + agent | the operator runs `sudo systemctl start node-maintenance-config.service` on the CP; the agent checks that the fallback listens on `<eero ULA>::53`; from the Mac, `dig @<eero ULA>::53 example.com` and `doubleclick.net` | example.com resolves; doubleclick.net gives `0.0.0.0` | revert |
| W4 | agent | global addresses: workers and immich-vm none; NAS none; CP only `<private prefix>::53`, no address on the ISP prefix | all hold | revert |
| W5 | agent | from the Mac: `nc -6 -z -w3 <CP private ::53 address> 9100` (node-exporter listens on IPv6 too) | refused or timed out; the same from the CP itself to `[::1]:9100` succeeds | revert; fix UFW |
| W7 | operator + agent | operator types `<eero ULA>::53` into IPv6 DNS 1, field 2 empty. Mac `scutil --dns` lists only that IPv6 server. Operator runs `sudo tcpdump -ni en0 'port 53'` on the Mac while the agent looks up a fresh random allowed name and a fresh random blocked name | the capture shows queries to the fallback's address; the blocked name gives `0.0.0.0`; no query to a public server | if a public server appears: fill field 2 with the same address and repeat; if it stays, revert |
| W8 | operator + agent | This models a CP that is down, which answers no DNS at all and sends no reply. On the CP, the operator adds four temporary rules: `sudo iptables -I INPUT 1 -i <primary interface> -p udp --dport 53 -j DROP`, the same with `-p tcp`, and the same two with `ip6tables`. Each rule names the primary interface, so loopback DNS (systemd-resolved on 127.0.0.53) keeps working. The operator starts `sudo tcpdump -ni en0 'port 53'` on the Mac. The agent times a fresh random lookup through the Mac's normal resolver (`dscacheutil -q host -a name <random>.example.com`). After either outcome, the operator deletes all four: `sudo iptables -D INPUT -i <primary interface> -p udp --dport 53 -j DROP`, `sudo iptables -D INPUT -i <primary interface> -p tcp --dport 53 -j DROP`, `sudo ip6tables -D INPUT -i <primary interface> -p udp --dport 53 -j DROP`, `sudo ip6tables -D INPUT -i <primary interface> -p tcp --dport 53 -j DROP` | the lookup answers within 5 s; the capture shows the answer came from .129; `iptables -S INPUT` and `ip6tables -S INPUT` show no DROP rule for port 53 at the end | delete the rules, then revert |
| W9 | operator + agent | after more than 30 min, restart the eero network from the app; re-run W3 and W7's `scutil` check; probe metric `fallback_only` | the private range is unchanged | revert |
| W10 | operator | keep IPv6, or revert | — | — |

**Revert** (used at any failure): eero → IPv6 → off; about 5 min restart. Then check:
- Mac `scutil --dns` lists only the IPv4 servers;
- nodes Ready;
- CoreDNS answers;
- the eero IPv6 DNS fields are restored to the values recorded in W0.

The repo changes stay harmless with IPv6 off, because the eero does not announce the IPv6 DNS address.

### Task 7: Docs and review rows
- [ ] `networking.md`: the LAN and eero settings tables.
- [ ] HISTORY entry.
- [ ] Monthly review rows: the eero IPv6 firewall rule list is empty, and the private range is unchanged.

## Review Focus

| Case | Expected behaviour | Covered by |
|---|---|---|
| If a power cut brings the CP up before the eero announces any prefix | Blocky still answers on IPv4 | `freeBind`, spike T3b |
| If the eero restarts with a new private range | Ansible re-renders at the next drift-heal. The eero field goes stale and the alert fires. IPv4 DNS still works | `BlockyIPv6DNSBypass`, W9 |
| If someone adds a UFW rule without a source | the firewall role refuses it | Task 2 |
| If a device ignores DHCP and RA DNS (Chromecast uses 8.8.8.8) | it bypasses Blocky over IPv6 just as it does over IPv4 today | out of scope |
| If Android "Private DNS automatic" tries DNS-over-TLS on port 853 | the fallback has no 853 listener, so Android uses port 53 | ✅ Google docs |
