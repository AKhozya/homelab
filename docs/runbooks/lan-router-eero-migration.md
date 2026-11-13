# LAN router: replace the ISP router with an eero gateway

**Status (2026-11-13):** stage 0 done; every check passed. Next step: stages 1 and 2, after the operator's approval. Nothing on the live network has changed.

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

| Item | After the swap |
|---|---|
| Office and Living Room eeros | stay in their own network, `z3us`, in Bridge mode (operator's decision, 2026-11-12) |
| Wi-Fi name and password | unchanged, so no device rejoins |
| Rollback | needs no app change |
| eero app | shows two networks. Merging them is a separate, later change |
| ZTE Wi-Fi | off today, so no device loses Wi-Fi |

## Facts read from the ZTE (2026-11-10, read only)

| Item | Value | Effect |
|---|---|---|
| WAN | DHCP (`WAN-DHCP-CONNECTION`, type IP), IPv4 lease 1 h. The page shows no VLAN or login field | expected: the eero connects with no ISP settings. Confirm at the swap |
| IPv6 | DHCPv6 prefix delegation, /56 | the eero can request this prefix. With IPv6 off it does not |
| Port forwards, DMZ | none, off | nothing to move |
| WAN status page | shows **Renew** and **Release** buttons for the IPv4 lease | before the swap, press Release. Not verified: whether the ISP ties the lease to the ZTE's MAC |
| DHCP bindings | 7: the CP (.127), worker-node (.129), worker-node-2 (.126), the NAS (.136), immich-vm (.231), and two for the operator's Mac | the five homelab hosts become eero reservations by MAC. The plan leaves out the Mac's two: neither the repo nor Home Assistant uses the Mac's address. If something needs it, add a reservation later. The operator's memory note holds the MAC list; this public repo does not |
| LAN DHCP pool | .100 to .254 (the operator read it 2026-11-12) | the eero's pool sits below it, at .20 to .99 |
| Lease length for the bound hosts | never expires: DHCP option 51 is `ffffffff` on the CP, worker-node and immich-vm (`networkctl status --json=short`), and `dhcp_lease_time = 4294967295` on the NAS (read 2026-11-12) | the hosts keep their addresses without renewing. The eero reservation first matters at a reboot or a manual renew |

| Node | Address source (host config read 2026-11-10) | Needs |
|---|---|---|
| CP, worker-node, immich-vm | `DHCP=yes` in systemd-networkd | an eero reservation before the node renews |
| worker-node-2 | static on the host (`20-wired-static.network`: 192.168.1.126, gateway 192.168.1.1, DNS .129 and 1.1.1.1) | the eero at 192.168.1.1, and .126 kept out of the eero's pool |
| NAS (.136) | DHCP via NetworkManager (read 2026-11-12). Its ZTE lease never expires (`dhcp_lease_time = 4294967295`) | an eero reservation. It keeps .136 and does not renew |

## Rehearsal results (2026-11-12)

| Setting | Value |
|---|---|
| Network | `test-eero`, separate from `z3us` |
| Uplink | a cable to the Office eero. That eero is in Bridge mode, so this is the ZTE's LAN |
| DNS | custom: .129 and .126 |
| IPv6 | off |
| eero Secure | off |

| Question | Result |
|---|---|
| Does the eero hand out Blocky, or itself as a DNS proxy? | Blocky: DHCP gave the Mac 192.168.1.129 and .126. No IPv6 DNS server appeared |
| Do lookups reach Blocky? | 5 of 5 unique lookups through the Mac's system resolver appeared in Blocky's log (0 of 5 through the ZTE) |
| Blocking and the internal domain | `doubleclick.net` and `eu-acr1.alphonso.tv` returned 0.0.0.0 through the system resolver; `h0melab.work` returned .129 and .126 |
| Does Manual DHCP accept 192.168.1.0/24? | the fields accepted subnet 192.168.1.0, mask 255.255.255.0, range .20 to .254. Not saved |
| Does a reservation save? | yes, for a connected device. Not tested: a reservation for a MAC that never connected, and whether it survives an app restart. The form has a free-text MAC field. Stage 0 tests both |
| Does the app work while the eero has no internet? | the app opens the network and saves a change. In the stage 0 test (2026-11-13), a Manual IP change saved offline takes effect only once the eero is online. No check covers the rehearsal's small offline change on the eero itself |

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
7. (Partly done: a reservation for a connected device saved. The rest moves to swap stage 0.) Keep the default range. Save a reservation for a MAC that has never connected to `test-eero`. Check that it stays in the list after the app restarts. Then delete it.
8. Unplug the test eero from the ZTE. Keep the phone on `test-eero`, and try to change one setting in the app. Plug it back in afterwards.

## Swap plan

Three stages. Each stage needs the operator's go. If stage 1 passes, stage 2 can follow at once, so the household sees one outage. Stage 0 needs no switch and causes no outage, so it can run first, on its own day.

### Assumptions

| Assumption | Tier | Checked by |
|---|---|---|
| The eero hands out Blocky directly, with no IPv6 DNS | verified (rehearsal) | — |
| The eero runs 192.168.1.0/24 with itself at .1 | verified (stage 0): a phone got 192.168.1.20 with router 192.168.1.1 | — |
| A reservation for a MAC that never connected saves and survives an app restart | verified (stage 0) for all five node reservations | — |
| The eero hands out a reservation outside the DHCP pool | verified (stage 0): a phone reserved at .200 got .200 | — |
| The ZTE's DHCP pool starts at .100 or higher | verified: the ZTE shows .100 to .254 | — |
| In the stage 0 test, the eero does not apply the Manual IP change that the app saves offline | verified (one test) | — |
| A DNS change saved while the eero is online takes effect | assumption: stage 0 step 2 saves one, and no check covers what the eero then hands out | stage 2 check: `ipconfig getpacket` shows .129 and .126 |
| The line needs no VLAN tag and no ZTE MAC address | sources conflict | stage 1 |
| The eero's Online status needs working DNS | a guess; the plan sets DNS to Automatic for stage 1 to avoid the question | — |
| A renewed node keeps its address through its reservation | not tested | the renew section after stage 2 |
| The repo and Home Assistant reach no home device by address | checked: the repo names no other LAN address; Home Assistant's config entries hold no local-device integration (read 2026-11-12) | — |
| No other app or device reaches a home device by address, so moving unreserved devices to .20–.99 breaks nothing | assumption | after stage 2: if a device or app stops working, reserve that device at its old address |

| Stage | What changes | Internet outage |
|---|---|---|
| 0. Prep | the spare eero only, disconnected from the home LAN | none |
| 1. Line test | the ONT cable moves from the ZTE to the spare eero | 5 to 10 minutes |
| 2. Cut-over | the room cables and the Eufy base station move to the switch | continues from stage 1, about 10 minutes more |

The node and Mac MAC addresses are in the operator's memory note, not in this public repo.

### Stage 0: prep (no outage)

**Done 2026-11-13; every check passed.** The steps stay here for a rerun, for example after a factory reset of the spare eero.

| Constraint | Effect on the plan |
|---|---|
| If the spare eero's range is 192.168.1.0/24 and its LAN side connects to the home LAN, two DHCP servers share one network | after step 5, do not connect the spare eero's LAN side to the home LAN |
| If the spare eero's internet side gets a 192.168.1.x address, both of its sides use the same range | in steps 4 to 9 its internet comes from the Mac's Internet Sharing, on 192.168.2.0/24 |
| Stage 0 test, 2026-11-13: a Manual IP change saved while the eero has no internet stays unapplied through two restarts. The app reports that it "cannot restart your network from the app when the internet is down" | keep the eero online for steps 5 to 9 |
| Devices keep their ZTE addresses after the swap | if the eero hands out an address that a device still holds, two devices share it |
| The NAS's ZTE lease never expires (`dhcp_lease_time = 4294967295`) | the NAS keeps .136 |
| Other devices' ZTE lease lengths remain unknown | assume they hold their addresses for a day or more |
| The ZTE's pool is .100 to .254 | the eero's pool is .20 to .99. The reservations sit above it |

1. ZTE admin → Local Network → LAN → IPv4: write down the DHCP start and end addresses. If the start is below .100, stop: the eero range must change.
2. Do this step before step 3, so the eero is online: `test-eero` → DNS → **ISP DNS (Default)** (the app's name for Automatic). In stage 1 the eero cannot reach Blocky. If its DNS stays custom, the eero might fail its own lookups and show Offline even if the line works.
3. Unplug the spare eero's cable from the Office eero. Leave the spare eero powered.
4. Give the spare eero internet through the Mac:

   | Step | Why |
   |---|---|
   | Join the Mac's Wi-Fi to `z3us` | the Mac shares this connection |
   | Unplug the home cable from the Mac's Ethernet adapter (`AX88179B`), and cable the adapter to the spare eero | if sharing is on, the Mac runs a DHCP server on that adapter. If the home LAN is on that adapter, the Mac hands out 192.168.2.x addresses to the house |
   | System Settings → General → Sharing → **Internet Sharing**: share from Wi-Fi, to `AX88179B` only. Turn it on | — |
   | Pass: `arp -an -i bridge100` lists the eero at a 192.168.2.x address, and the app shows `test-eero` online | — |

5. DHCP & NAT → Manual IP: subnet IP 192.168.1.0, mask 255.255.255.0, start .20, end .99. Save.
6. Join the phone to `test-eero` and open its Wi-Fi details. Pass: router 192.168.1.1, phone address in .20 to .99. W2's static gateway and the `node-isolation-heal` gateway ping both need the eero at 192.168.1.1.
7. Reservations & port forwarding → add one reservation per node, by typed MAC:

   | Device | Address | Why |
   |---|---|---|
   | CP | .127 | DHCP on the host |
   | worker-node | .129 | DHCP on the host; Blocky's LAN address |
   | worker-node-2 | .126 | static on the host. The reservation stops the eero giving .126 to another device |
   | NAS | .136 | DHCP on the host (NetworkManager) |
   | immich-vm | .231 | DHCP in the VM |

   If the app refuses an address outside the pool (.20 to .99), stop: the plan needs a new address layout. The list shows no MAC addresses, so open each reservation's **Edit** form, compare the MAC with the memory note, and close the form with ✕.
8. Quit the app (Cmd-Q on the Mac, or swipe it away on the phone). Reopen it. Pass: all five reservations are listed.
9. Devices → the phone → reserve .200, outside the pool. Turn the phone's Wi-Fi off and on. Pass: the phone gets .200. Delete that reservation. Then forget `test-eero` on the phone and join it again. Pass: the phone's address is back in .20 to .99, so it cannot clash with a ZTE client later.
10. Turn Internet Sharing off. Unplug the spare eero, and plug the home cable back into the Mac's adapter.

    | Check | Pass |
    |---|---|
    | `ifconfig bridge100` | prints "interface bridge100 does not exist" |
    | `route -n get default` | gateway 192.168.1.1 on the adapter |

Leave the spare eero powered and unplugged until stage 1.

**Results (2026-11-13):**

| Step | Result |
|---|---|
| 2 | the app saves ISP DNS (Default) while the eero is online |
| 4 | the eero's internet side: 192.168.2.2. The app: `test-eero` online |
| 5, 6 | the phone: 192.168.1.20, router 192.168.1.1 |
| 7 | all five reservations above the pool, each with the right MAC in its Edit form |
| 8 | the app lists all five after its restart |
| 9 | the phone: .200 with its reservation, .20 without it |
| 10 | no sharing bridge; the Mac on Ethernet with router 192.168.1.1; all 4 nodes Ready |
| side effect | the rehearsal's reservation for the Mac (192.168.4.20) is gone since the range change |

### Stage 1: line test

The home LAN loses internet here. The Mac moves to `test-eero` Wi-Fi, so this Claude session comes back as soon as the eero is online. In the stage 0 test, a Manual IP change saved offline does not take effect. So make every settings change in stages 1 and 2 while the eero is online.

Sources disagree on two points. Only this test settles them:

| Unknown | Evidence |
|---|---|
| Does the line need a VLAN tag? | the ZTE's WAN page shows DHCP and no VLAN field. A forum user reports Hyperoptic saying "no VLAN required" on an ONT line |
| Is the line tied to the ZTE's MAC address? | forum reports conflict: one third-party router failed even with a copied MAC address; the same router worked on another Hyperoptic line |

1. Note the time.
2. ZTE admin page → WAN status → **Release** the IPv4 lease.
3. Move the cable from the ZTE's WAN port to a port on the spare eero. Nothing else connects to the spare eero.
4. Unplug the home cable from the Mac's Ethernet adapter, and join the Mac's Wi-Fi to `test-eero`. If the cable stays in, macOS keeps sending traffic to the ZTE, which now has no internet.
5. Keep the phone on `test-eero`, and turn off its mobile data. Every check then goes through the eero.
6. If this session answers, Claude checks the Mac. The cluster stays out of reach from the Mac until stage 2.

   | Check | Pass |
   |---|---|
   | `route -n get default` | gateway 192.168.1.1 on Wi-Fi |
   | the Wi-Fi address | in .20 to .99 |
   | a website | loads |

| Within 10 minutes | Then |
|---|---|
| the eero app opens `test-eero` and shows **Online**, and a website opens on the phone | pass. Go to stage 2, or roll back to stop for today |
| still offline | roll back. Next, ask Hyperoptic for the WAN settings, or try a VLAN tag (the app has VLAN tagging under Advanced networking) |

**Rollback:**

1. Move the ONT cable back to the ZTE's WAN port. Plug the home cable back into the Mac's adapter.
2. On the ZTE WAN page, press **Renew**.
3. If the Mac has no internet after 5 minutes, power the ONT and the ZTE off and on.
4. If it still has no internet after 15 minutes, the ISP may still hold the eero's lease. The ZTE's WAN lease was 1 hour. Wait up to 1 hour; this wait is a guess, not a known limit. If stage 1 passed, the eero has a working line: instead of waiting, carry out stage 2 in full, so the home LAN moves to the eero with it. If stage 1 failed, wait, then call Hyperoptic.

### Stage 2: cut-over

1. Power the switch.
2. Cable the spare eero's free port to the switch.
3. In the app, `test-eero` → DNS → Custom: .129 and .126. Do it before step 5, so every new lease names Blocky. The eero reaches Blocky after step 5.
4. Power off the ZTE. Keep it, with its cables, for rollback. Do it before the cables move: if the cable path between the two `z3us` eeros breaks, they fall back to their wireless link, and that link would join the ZTE's network to the eero's. Two routers would then answer at 192.168.1.1.
5. Move the three wall cables and the Eufy base station from the ZTE's LAN ports to the switch.
6. Plug the home cable back into the Mac's adapter, and join the Mac's Wi-Fi to `z3us` again. Ethernet sits above Wi-Fi in the service order, so the Mac's traffic moves to the cable.
7. Wait 2 minutes. This Claude session reconnects over the Mac's Ethernet.

| Check | Who | Pass |
|---|---|---|
| the Mac has internet | operator | a website loads |
| this session answers | operator | a reply within 5 minutes |
| `route -n get default` on the Mac | Claude | gateway 192.168.1.1 |
| `ipconfig getpacket` on the Mac's Ethernet | Claude | DNS servers .129 and .126 only |
| `scutil --dns` on the Mac | Claude | no `fe80::1`. If it is listed, turn the Ethernet off and on again: a router advertisement keeps its DNS entry until its lifetime ends |
| 5 unique lookups through the Mac's system resolver | Claude | all 5 in Blocky's query log, from the Mac's own address |
| Blocky's query log | Claude | new lookups from several device addresses, not one |
| `kubectl get nodes` | Claude | 4 Ready |
| a ping to 192.168.1.1 from each node | Claude | replies |
| a ping and SSH to the NAS (.136) | Claude | replies; SSH logs in |
| the Cloudflare tunnel and external URLs | Claude | tunnel connected; the public apps answer |

**Rollback triggers:**

| Failure | Then |
|---|---|
| the Mac has no internet 10 minutes after step 5 | roll back |
| a node stays NotReady for 10 minutes | roll back |
| the system-resolver lookups do not reach Blocky, and setting custom DNS again does not fix it within 10 minutes | roll back |
| the tunnel or a public app stays down for 15 minutes | roll back |

**Rollback:**

1. Unplug the spare eero from the ONT and the switch.
2. Move the three wall cables and the Eufy back to the ZTE's LAN ports.
3. Power on the ZTE, and move the ONT cable to its WAN port. If it gets no internet, follow the stage 1 rollback from step 2. If the ZTE still has no internet after 15 minutes, undo steps 1 to 3: the eero setup had a working line, so the home stays online on it while the operator investigates.

The `z3us` eeros need no change. The ZTE still holds every DHCP binding. Devices that took an eero lease hold an address in .20 to .99, below the ZTE's pool, so they do not clash with it.

### After the cut-over: test each node's reservation, one at a time

The DHCP nodes hold ZTE leases that never expire, so they keep their addresses without the eero. Their reservations first matter at a reboot. A manual renew tests each reservation now, while the operator watches, instead of at an unplanned reboot.

If the eero refuses a renew, the node can lose its address until the eero gives it one. A short link loss has caused database trouble before (the CP link flap, 2026-09-12). So the order in the table starts with the least critical node.

| Node | Command (the operator runs it; it needs sudo) |
|---|---|
| immich-vm | `ssh -t -p 65300 akhozya@immich-vm sudo networkctl renew enp2s0` |
| CP | `ssh -t -p 65300 akhozya@gmk-k3s-control-plane sudo networkctl renew enp3s0` |
| worker-node | `ssh -t -p 65300 akhozya@worker-node sudo networkctl renew enp4s0` |

| Check (Claude, no sudo) | Pass |
|---|---|
| before the renew: `networkctl status --json=short <interface>`, field `DHCPv4Client.Lease.LeaseTimestampUSec` | record the value |
| after the renew: the same field | the value differs from the recorded value. The ZTE is off, so only the eero can have sent the new lease. Record option 51 (lease length) too; nobody knows yet what the eero sends |
| the address | unchanged |
| `kubectl get nodes` | the node is Ready |

| Failure, 3 minutes after the renew | Recovery |
|---|---|
| SSH to the node's usual address fails | find the node in the eero app's device list. If it shows a new address, SSH there, fix the reservation in the app, and run the renew again |
| the node has a new address | stop. Fix its reservation in the app, then run the renew again |
| the node stays NotReady, or nothing above recovers it within 10 minutes | roll back with the stage 2 rollback. The ZTE still holds the node's binding |

`networkctl renew` exists in systemd 262 on the nodes. Nobody has run it against the eero yet, so Claude checks each result before the next node.

| Host | Why no renew |
|---|---|
| worker-node-2 | static address |
| NAS | not a cluster node. Its ZTE lease never expires, so it keeps .136. Its reservation covers a later reboot |

### After a day

| Item | Action |
|---|---|
| IPv6 | stays off on `test-eero`. The nodes lose their public IPv6 addresses; nothing in the repo uses them |
| docs | update `docs/subsystems/networking.md` and `docs/HOMELAB_HISTORY.md`: the eero is the router |
| parked fallback branch | revisit it (next section) |
| optional | rename `test-eero`; merge the eeros into one network as a separate change |

## Parked related work

Branch `wt-blocky-fallback` (local commit `8c0ab7f3`, not pushed) holds a Blocky DNS fallback role for the CP. Its design assumes the ZTE's two-DNS limit. Revisit it after the router decision.
