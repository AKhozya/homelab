# macOS Client Helpers

Scripts that configure a macOS client to work cleanly with the homelab.

## `setup-h0melab-resolver.sh`

**Run on:** Any Mac that connects to the homelab LAN.

**What:** Creates `/etc/resolver/h0melab.work` so all `*.h0melab.work` queries
go directly to the LAN Blocky instances (`192.168.1.129` primary,
`192.168.1.126` secondary), bypassing any VPN-pushed public DNS.

**Why:** When a VPN client adds a public DNS server (e.g. `1.1.1.1`) as a
secondary nameserver, macOS `mDNSResponder` load-balances queries across
all configured resolvers. Internal-only domains like `*.h0melab.work`
return `NXDOMAIN` from the public resolver, and `mDNSResponder` caches
that negative result. Result: `dig grafana.h0melab.work` works (because
`dig` queries a specific server), but browsers, `curl`, and any
`getaddrinfo()` caller fail.

A per-domain resolver overrides this — for `*.h0melab.work` only,
macOS sends queries exclusively to the listed nameservers.

**Run:**
```bash
./setup-h0melab-resolver.sh
# (auto-elevates with sudo)
```

Idempotent. Safe to re-run after VPN reconnects, OS updates, or whenever
internal DNS appears broken from the Mac.

**Verify manually:**
```bash
python3 -c "import socket; print(socket.getaddrinfo('grafana.h0melab.work', 443, socket.AF_INET))"
# Should return 192.168.1.129 + 192.168.1.126
```
