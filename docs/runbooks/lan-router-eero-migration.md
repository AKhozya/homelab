# LAN router: replace the ISP router with an eero gateway

**Status (2026-11-12):** rehearsal done; the DNS path passed. Next step: stage 0 of the swap plan, after the operator's go. Nothing on the live network has changed.

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
Hyperoptic ONT ──► spare eero Pro 6E (gateway, network `test-eero`) ──► unmanaged gigabit switch ──► wall cable, operator's room ──► Office eero ──► homelab
                                                                                              ├──► wall cable, living room ──► Living Room eero
                                                                                              ├──► wall cable, third room
                                                                                              └──► Eufy base station (now on a ZTE LAN port)
```

eero support: a switch between the modem and the gateway eero "will cause a gateway conflict and network instability". The switch goes after the gateway.

The Office and Living Room eeros stay in their own network, `z3us`, in Bridge mode (operator's decision, 2026-11-12). Devices keep their Wi-Fi name and password, and rollback needs no app change. The app then shows two networks. Merging them into one network is a separate, later change.

The ZTE's own Wi-Fi is off, so no device uses it.

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

## Rehearsal results (2026-11-12)

The spare eero ran as a separate network, `test-eero`, cabled to the Office eero (Bridge mode, so the same LAN as the ZTE ports). Settings: custom DNS .129 and .126, IPv6 off, eero Secure off.

| Question | Result |
|---|---|
| Does the eero hand out Blocky, or itself as a DNS proxy? | Blocky: DHCP gave the Mac 192.168.1.129 and .126. No IPv6 DNS server appeared |
| Do lookups reach Blocky? | 5 of 5 unique lookups through the Mac's system resolver appeared in Blocky's log (0 of 5 through the ZTE) |
| Blocking and the internal domain | `doubleclick.net` and `eu-acr1.alphonso.tv` returned 0.0.0.0 through the system resolver; `h0melab.work` returned .129 and .126 |
| Does Manual DHCP accept 192.168.1.0/24? | the fields accepted subnet 192.168.1.0, mask 255.255.255.0, range .20 to .254. Not saved |
| Does a reservation save? | yes, for a connected device. Not tested: a reservation for a MAC that never connected, and whether it survives an app restart. The form has a free-text MAC field. Stage 0 tests both |
| Does the app work while the eero has no internet? | yes: the operator changed a small setting from a phone on `test-eero`. Not tested: a DHCP-mode change while offline. Stage 0 tests it |

## Rehearsal steps (done 2026-11-12, live network untouched)

1. Plug the spare eero into a free ZTE LAN port.
2. In the eero app, create a **new, separate network** with its own SSID, for example `test-eero`.
3. On that network:
   - confirm eero Plus (eero Secure) is off. It overrides custom DNS;
   - set Custom DNS to 192.168.1.129 and 192.168.1.126;
   - turn IPv6 off;
   - if a Local DNS Caching setting exists, turn it off.
4. Prepare the Mac, so that every lookup takes the test path:

   | Step | Why |
   |---|---|
   | Unplug the USB Ethernet adapter (network service `AX88179B` or `USB 10/100/1000 LAN`), or turn it off in System Settings → Network | both services sit above Wi-Fi in the service order. If an Ethernet connection is active, macOS sends lookups over it and the ZTE path |
   | Disconnect ProtonVPN | a VPN configures its own DNS servers |
   | Join `test-eero` over Wi-Fi. Run `route -n get default` | expect the gateway to be the test eero, not 192.168.1.1 |

   `/etc/resolver/h0melab.work` makes the macOS system resolver send `h0melab.work` lookups to .129 and .126, whatever DNS the network provides. So test that name with `dig @<eero-provided DNS server>`, which ignores that file.

5. Check:

   | Check | Expect |
   |---|---|
   | `ipconfig getpacket en0` | the DNS servers the eero provides: Blocky's, or the eero's own address |
   | `scutil --dns` | no IPv6 DNS server |
   | 5 unique names through `dscacheutil -q host -a name <name>` | all 5 in Blocky's query log, from the test eero's address on the ZTE LAN |
   | `dig @<eero-provided DNS server> h0melab.work` | 192.168.1.129, 192.168.1.126 |
   | `dig @<eero-provided DNS server> doubleclick.net` | 0.0.0.0 |

   Afterwards, plug the adapter back in, or turn it back on.

6. Open DHCP & NAT → Manual and check whether it offers a 192.168.1.x range with the gateway at .1. Do not save it: the test eero's WAN side is already on the ZTE's 192.168.1.0/24, so the two sides would overlap. The swap plan confirms the range on the real gateway, where no ZTE network exists.
7. Keep the default range. Save a reservation for a MAC that has never connected to `test-eero`. Check that it stays in the list after the app restarts. Then delete it.
8. Unplug the test eero from the ZTE. Keep the phone on `test-eero`, and try to change one setting in the app. Plug it back in afterwards.

## Swap plan

Three stages. Each stage needs the operator's go. If stage 1 passes, stage 2 can follow at once, so the household sees one outage.

| Stage | What changes | Internet outage |
|---|---|---|
| 0. Prep | the spare eero only, disconnected from the home LAN | none |
| 1. Line test | the ONT cable moves from the ZTE to the spare eero | 5 to 10 minutes |
| 2. Cut-over | the room cables and the Eufy base station move to the switch | continues from stage 1, about 10 minutes more |

The node and Mac MAC addresses are in the operator's memory note, not in this public repo.

### Stage 0: prep (no outage)

The spare eero must not touch the home LAN once its range is 192.168.1.0/24. The ZTE also serves DHCP at 192.168.1.1 there, so two DHCP servers would share one network.

1. Unplug the spare eero's cable from the Office eero. Leave the spare eero powered.
2. Join the phone to `test-eero`.
3. DHCP & NAT → Manual IP: subnet IP 192.168.1.0, mask 255.255.255.0, start .20, end .254. Save. If the app refuses the save offline, cancel, and do steps 3 to 6 in stage 1 while the eero is online.
4. Check on the phone: Wi-Fi details for `test-eero` show router 192.168.1.1 and an address in .20 to .254. W2's static gateway and the `node-isolation-heal` gateway ping both need the eero at 192.168.1.1.
5. Reservations & port forwarding → add one reservation per node, by typed MAC:

   | Device | Address | Why |
   |---|---|---|
   | CP | .127 | DHCP on the host |
   | worker-node | .129 | DHCP on the host; Blocky's LAN address |
   | worker-node-2 | .126 | static on the host. The reservation keeps .126 out of the pool; Blocky's LAN address |
   | NAS | .136 | DHCP on the host (NetworkManager) |
   | immich-vm | .231 | DHCP in the VM |

6. Quit the app (Cmd-Q on the Mac, or swipe it away on the phone), reopen it, and check all five reservations are listed.
7. Add one reservation for the phone at an unused address. Rejoin `test-eero` on the phone and check it gets that address. Delete that reservation.

**Pass:** steps 4, 6 and 7. Leave the spare eero powered and unplugged until stage 1.

### Stage 1: line test (offline; the operator works alone)

This Claude session loses internet here, so every check uses the eero app over mobile data. Do not test by website name: the eero hands out Blocky, and Blocky is on the home LAN, not on `test-eero`.

Sources disagree on two points, and only this test settles them:

| Unknown | Evidence |
|---|---|
| Does the line need a VLAN tag? | the ZTE's WAN page shows DHCP and no VLAN field. A forum user reports Hyperoptic saying "no VLAN required" on an ONT line |
| Is the line tied to the ZTE's MAC address? | forum reports conflict: one third-party router failed even with a copied MAC address, the same router worked on another Hyperoptic line |

1. Note the time.
2. ZTE admin page → WAN status → **Release** the IPv4 lease.
3. Move the cable from the ZTE's WAN port to a port on the spare eero. Nothing else connects to the spare eero.
4. Turn off Wi-Fi on the phone. In the eero app, open `test-eero`.

| Within 10 minutes | Then |
|---|---|
| `test-eero` shows **Online** | pass. Go to stage 2, or roll back to stop for today |
| still offline | roll back. The next step is to ask Hyperoptic for the WAN settings, or to try a VLAN; the app has VLAN tagging under Advanced networking |

**Rollback:** move the ONT cable back to the ZTE's WAN port. On the ZTE WAN page, press **Renew**. Check that the Mac has internet. Nothing else changed.

### Stage 2: cut-over

1. Power the switch.
2. Cable the spare eero's free port to the switch.
3. Move the three wall cables and the Eufy base station from the ZTE's LAN ports to the switch.
4. Power off the ZTE. Keep it, with its cables, for rollback.
5. Wait 2 minutes. This Claude session should come back over the Mac's Ethernet.

| Check | Who | Pass |
|---|---|---|
| the Mac has internet | operator | a website loads |
| this session answers | operator | a reply within 5 minutes |
| `route -n get default` on the Mac | Claude | gateway 192.168.1.1 |
| `scutil --dns` on the Mac | Claude | no `fe80::1`. If it is still listed, turn the Mac's Ethernet off and on, because a router advertisement keeps its DNS entry until its lifetime ends |
| `kubectl get nodes` | Claude | 4 Ready |
| a ping to 192.168.1.1 from each node | Claude | replies |
| Blocky's query log | Claude | new lookups from several device addresses, not one |
| `dig @192.168.1.129 doubleclick.net` and `h0melab.work` | Claude | 0.0.0.0; .129 and .126 |
| the Cloudflare tunnel and external URLs | Claude | tunnel connected, the public apps answer |

**Rollback trigger:** no internet on the Mac 10 minutes after step 4, or a node stays NotReady. **Rollback:** unplug the spare eero from the ONT and the switch. Move the three wall cables and the Eufy back to the ZTE's LAN ports. Power on the ZTE, and move the ONT cable to its WAN port. The `z3us` eeros need no change. The ZTE still holds every DHCP binding.

### After the cut-over: move the nodes to eero leases, one at a time

Each node on DHCP still holds a lease from the ZTE. When it renews, it asks 192.168.1.1, which is now the eero. With the reservation, the node should keep its address. Renew each one while the operator watches, not at an unknown hour: CP, then worker-node, then immich-vm. Before the next node, Claude checks that the address stayed the same and the node is Ready.

| Node | Command (the operator runs it; it needs sudo) |
|---|---|
| CP | `ssh -t -p 65300 akhozya@gmk-k3s-control-plane sudo networkctl renew enp3s0` |
| worker-node | `ssh -t -p 65300 akhozya@worker-node sudo networkctl renew enp4s0` |
| immich-vm | `ssh -t -p 65300 akhozya@immich-vm sudo networkctl renew enp2s0` |

worker-node-2 keeps its static address and needs no renew. The NAS (NetworkManager) is not a cluster node, so it renews on its own; Claude checks its address the next day. `networkctl renew` is the systemd-networkd command for a DHCP renew (present in systemd 262 on the nodes); it has not been run against an eero yet, so Claude checks each result before the next node.

Other devices also hold ZTE leases, for up to 24 hours. The eero's pool (.20 to .254) overlaps the ZTE's. The eero could offer an address that a device still holds from the ZTE, and two devices would then share it. If a device loses its connection in the first day, turn its Wi-Fi off and on.

### After a day

| Item | Action |
|---|---|
| IPv6 | stays off on `test-eero`. The nodes lose their public IPv6 addresses; nothing in the repo uses them |
| docs | update `docs/subsystems/networking.md` and `docs/HOMELAB_HISTORY.md`: the eero is the router |
| parked fallback branch | revisit it (next section) |
| optional | rename `test-eero`; merge the eeros into one network as a separate change |

## Parked related work

Branch `wt-blocky-fallback` (local commit `8c0ab7f3`, not pushed) holds a Blocky DNS fallback role for the CP. Its design assumes the ZTE's two-DNS limit. Revisit it after the router decision.
