# LAN router: replace the ISP router with an eero gateway

**Status (2026-11-10):** researched, not started. Next step: the rehearsal below. Nothing on the live network has changed.

## Why

The ISP router (ZTE H3600, Hyperoptic firmware `V9.0.24P14_HOP`) hands out Blocky (.129, .126) as the IPv4 DNS servers. It also announces itself (`fe80::1`) as the IPv6 DNS server. That server does not filter: it returned real addresses for `doubleclick.net` and `alphonso.tv`, which Blocky blocks. The firmware hides every IPv6 setting, even from the `admin` login.

| Measurement (2026-11-10) | Result |
|---|---|
| macOS resolver order (`scutil --dns`) | `fe80::1` first, then .129 and .126 |
| 5 unique lookups through the Mac's system resolver | 0 reached Blocky; a control `dig @192.168.1.129` did |
| Blocky lookups in 24 h | the NAS 21,113; three other always-on devices 6,000–9,500 each; the Mac 562; an Android phone 27; an iPad 0 |

The Mac bypass is proven. The phone and iPad counts suggest the same, but their resolver paths are not tested. Rejected fixes:

| Option | Why not |
|---|---|
| Ask the ISP to turn IPv6 off | operator: support is poor |
| Manual DNS on each device, or a DNS profile per device | operator: no per-device setup |
| eero in router mode behind the ZTE | eero requires the switch after the gateway eero; both wall cables meet only at the ZTE |

## Target layout

```
ISP socket ──► spare eero Pro 6E (gateway) ──► unmanaged gigabit switch ──► cable to the operator's room ──► eero ──► homelab
                                                                       ├──► cable to the living room ──► eero
                                                                       └──► the device now on ZTE port 3
```

eero support: a switch between the modem and the gateway eero "will cause a gateway conflict and network instability". The switch goes after the gateway.

## Facts read from the ZTE (2026-11-10, read only)

| Item | Value | Effect |
|---|---|---|
| WAN | DHCP (`WAN-DHCP-CONNECTION`, type IP), IPv4 lease 1 h. The page shows no VLAN or login field | expected: the eero connects with no ISP settings. Confirm at the swap |
| IPv6 | DHCPv6 prefix delegation, /56 | the eero can request this prefix. With IPv6 off it does not |
| Port forwards, DMZ | none, off | nothing to move |
| WAN status page | shows **Renew** and **Release** buttons for the IPv4 lease | before the swap, press Release. Not verified: whether the ISP ties the lease to the ZTE's MAC |
| DHCP bindings | 7: the CP (.127), worker-node (.129), worker-node-2 (.126), the NAS (.136), immich-vm (.231), and two for the operator's Mac | each becomes an eero reservation by MAC. The operator's memory note holds the MAC list; this public repo does not |

| Node | Address source (host config read 2026-11-10) | Needs |
|---|---|---|
| CP, worker-node, immich-vm | `DHCP=yes` in systemd-networkd | an eero reservation before the node renews |
| worker-node-2 | static on the host (`20-wired-static.network`: 192.168.1.126, gateway 192.168.1.1, DNS .129 and 1.1.1.1) | the eero at 192.168.1.1, and .126 kept out of the eero's pool |
| NAS (.136) | not checked | check before the swap |

## Questions for the rehearsal

| Question | Why it matters |
|---|---|
| Does the eero hand out the custom DNS servers, or its own address as a DNS proxy? Sources conflict; "Local DNS Caching" may decide it | with a proxy, Blocky's query log shows every device as the eero |
| Does `h0melab.work` still resolve to 192.168.1.129/126 through the eero? | some router DNS proxies drop private-address answers |
| Does Manual DHCP accept 192.168.1.0/24 with the eero at .1? | if not, every cluster address changes |
| Does a reservation by MAC save for a device that has not connected yet? | the nodes must keep their addresses at the first renewal |
| Can the eero app change a setting while the eero has no internet? | the operator runs the swap alone, and the network is down for part of it |

## Rehearsal (live network untouched)

1. Plug the spare eero into a free ZTE LAN port.
2. In the eero app, create a **new, separate network** with its own SSID, for example `test-eero`.
3. On that network:
   - confirm eero Plus (eero Secure) is off. It overrides custom DNS;
   - set Custom DNS to 192.168.1.129 and 192.168.1.126;
   - turn IPv6 off;
   - if a Local DNS Caching setting exists, turn it off.
4. Join the Mac to `test-eero` over Wi-Fi. Then check:

   | Check | Expect |
   |---|---|
   | `ipconfig getpacket <wifi interface>` | the DNS servers the eero hands out: Blocky's, or the eero's own address |
   | `scutil --dns` | no IPv6 DNS server |
   | 5 unique names through `dscacheutil -q host -a name <name>` | all 5 in Blocky's query log, from the test eero's address on the ZTE LAN |
   | `dig h0melab.work` | 192.168.1.129, 192.168.1.126 |
   | `dig doubleclick.net` | 0.0.0.0 |

5. Open DHCP & NAT → Manual and check whether it offers a 192.168.1.x range with the gateway at .1. Do not save it: the test eero's WAN side is already on the ZTE's 192.168.1.0/24, so the two sides would overlap. The swap plan confirms the range on the real gateway, where no ZTE network exists.
6. Keep the default range. Save a reservation for a MAC that has never connected to `test-eero`. Check that it stays in the list after the app restarts. Then delete it.
7. Unplug the test eero from the ZTE. Keep the phone on `test-eero`, and try to change one setting in the app. Plug it back in afterwards.

## After the rehearsal

If it passes, write the swap plan: reservation entry, order of steps, the operator's offline checklist, and the rollback (ZTE back in, eeros back to Bridge). Then review it with the advisor and Codex, and get the operator's go before anything changes. Any question the rehearsal leaves open goes into that plan.

## Parked related work

Branch `wt-blocky-fallback` (local commit `8c0ab7f3`, not pushed) holds a Blocky DNS fallback role for the CP. Its design assumes the ZTE's two-DNS limit. Revisit it after the router decision.
