#!/usr/bin/env python3
"""Functional probe of the Blocky fallback. Writes one gauge per check to a node-exporter textfile.

Standard library only: the CP has no dig, and the probe must not depend on what it probes.
Checks, each blocky_fallback_check{check=...} 1 or 0:
  listener  any well-formed reply to healthcheck.blocky (Blocky answers it itself)
  internal  the customDNS name answers with one of its configured addresses
  blocking  doubleclick.net answers 0.0.0.0 (Pro++ lists it; blockType zeroIp)
  public    example.com answers a non-zero address (needs the WAN and an upstream)
  listener6 as listener, over the IPv6 listener; only if --server6 is set

With --ra-iface, it also sends a Router Solicitation and reads the DNS servers (RDNSS, RFC 8106) that
the routers announce, because a client that takes any other server skips Blocky over IPv6:
  blocky_fallback_ra_heard 1 if any router advertisement arrived in this run.
  blocky_fallback_ra_rdnss{state=...} 1 for the current state, 0 for the others:
    none           no announced DNS server is still valid
    fallback_only  every valid announced server is --server6
    other          a valid announced server is not --server6
A client keeps an announced server until its lifetime ends, even if one later RA leaves it out. So
the probe keeps each server in --state until its lifetime ends or a router withdraws it (lifetime 0),
and one missed reply does not hide a bypass.
"""

import argparse
import json
import os
import random
import socket
import struct
import tempfile
import time

TIMEOUT_S = 3
RA_WAIT_S = 3
ICMPV6_RS, ICMPV6_RA, ND_OPT_RDNSS = 133, 134, 25


def build_query(qid, name):
    header = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    qname = b"".join(bytes([len(p)]) + p.encode() for p in name.rstrip(".").split(".")) + b"\0"
    return header + qname + struct.pack(">HH", 1, 1)


def _skip_name(msg, i):
    while True:
        length = msg[i]
        if length & 0xC0 == 0xC0:
            return i + 2
        if length == 0:
            return i + 1
        i += length + 1


def parse_reply(msg, qid):
    """Return (rcode, [A addresses]). Raise ValueError if the reply is not for this query."""
    if len(msg) < 12:
        raise ValueError("short reply")
    rid, flags, qdcount, ancount = struct.unpack(">HHHH", msg[:8])
    if rid != qid or not flags & 0x8000:
        raise ValueError("not a reply to this query")
    i = 12
    for _ in range(qdcount):
        i = _skip_name(msg, i) + 4
    addrs = []
    for _ in range(ancount):
        i = _skip_name(msg, i)
        rtype, _cls, _ttl, rdlen = struct.unpack(">HHIH", msg[i:i + 10])
        i += 10
        if rtype == 1 and rdlen == 4:
            addrs.append(socket.inet_ntoa(msg[i:i + 4]))
        i += rdlen
    return flags & 0x000F, addrs


def query(server, name):
    qid = random.randint(0, 0xFFFF)
    family = socket.AF_INET6 if ":" in server else socket.AF_INET
    with socket.socket(family, socket.SOCK_DGRAM) as s:
        s.settimeout(TIMEOUT_S)
        s.sendto(build_query(qid, name), (server, 53))
        msg, _ = s.recvfrom(4096)
    return parse_reply(msg, qid)


def parse_ra_rdnss(msg):
    """Return [(address, lifetime)] for every RDNSS address in a router advertisement.

    msg is the ICMPv6 message as a raw socket returns it. Raise ValueError if it is not a well-formed RA.
    """
    if len(msg) < 16 or msg[0] != ICMPV6_RA:
        raise ValueError("not a router advertisement")
    addrs, i = [], 16
    while i < len(msg):
        if i + 2 > len(msg) or msg[i + 1] == 0:
            raise ValueError("bad option length")
        otype, olen = msg[i], msg[i + 1] * 8
        if i + olen > len(msg):
            raise ValueError("option runs past the end")
        # A zero lifetime tells the host to stop using these servers.
        if otype == ND_OPT_RDNSS and olen >= 24:
            lifetime = struct.unpack(">I", msg[i + 4:i + 8])[0]
            for j in range(i + 8, i + olen - 15, 16):
                addrs.append((socket.inet_ntop(socket.AF_INET6, msg[j:j + 16]), lifetime))
        i += olen
    return addrs


def solicit_rdnss(iface):
    """Send a Router Solicitation on iface and collect RAs for RA_WAIT_S. Return (heard, [(addr, lifetime)])."""
    ifindex = socket.if_nametoindex(iface)
    heard, rdnss = False, []
    with socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6) as s:
        # RFC 4861 hosts and routers drop ND packets whose hop limit is not 255.
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 255)
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, ifindex)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, iface.encode())
        # The kernel fills in the ICMPv6 checksum on a raw ICMPv6 socket.
        s.sendto(struct.pack(">BBHI", ICMPV6_RS, 0, 0, 0), ("ff02::2", 0, 0, ifindex))
        deadline = time.monotonic() + RA_WAIT_S
        while (left := deadline - time.monotonic()) > 0:
            s.settimeout(left)
            try:
                msg = s.recv(65535)
            except TimeoutError:
                break
            if msg[:1] != bytes([ICMPV6_RA]):
                continue
            try:
                rdnss.extend(parse_ra_rdnss(msg))
                heard = True
            except ValueError:
                continue
    return heard, rdnss


def merge_rdnss(known, seen, now):
    """known maps address -> expiry time. Apply the (address, lifetime) pairs in seen and drop
    what has expired. 0xFFFFFFFF means no expiry (RFC 8106)."""
    known = dict(known)
    for addr, lifetime in seen:
        known[addr] = float("inf") if lifetime == 0xFFFFFFFF else now + lifetime
    # A withdrawal (lifetime 0) expires at once here.
    return {a: e for a, e in known.items() if e > now}


def load_state(path):
    try:
        with open(path) as f:
            return {a: float(e) for a, e in json.load(f).items()}
    except (OSError, ValueError, AttributeError):
        return {}


def save_state(path, known):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".rdnss.")
    with os.fdopen(fd, "w") as f:
        json.dump({a: (e if e != float("inf") else 1e18) for a, e in known.items()}, f)
    os.replace(tmp, path)


def rdnss_state(rdnss, fallback6):
    if not rdnss:
        return "none"
    return "fallback_only" if fallback6 and rdnss == {fallback6} else "other"


def run_checks(ask, internal_name, internal_ips):
    """ask(name) -> (rcode, addrs); any exception counts as a failed check."""
    def check(name, ok):
        try:
            return 1 if ok(*ask(name)) else 0
        except (OSError, ValueError, struct.error, IndexError):
            return 0

    return {
        "listener": check("healthcheck.blocky", lambda rcode, addrs: True),
        "internal": check(internal_name, lambda rcode, addrs: rcode == 0 and bool(set(addrs) & internal_ips)),
        "blocking": check("doubleclick.net", lambda rcode, addrs: rcode == 0 and addrs == ["0.0.0.0"]),
        # Blocky can answer example.com from its cache, so if the upstreams fail, this check still
        # passes until the cached answer expires. Cached answers can delay BlockyFallbackNoUpstream.
        "public": check("example.com", lambda rcode, addrs: rcode == 0 and any(a != "0.0.0.0" for a in addrs)),
    }


def write_metrics(path, results, ra=None):
    """ra is None (no RA check) or (heard, state)."""
    lines = [
        "# HELP blocky_fallback_check 1 if the CP's Blocky fallback passed this functional DNS check.",
        "# TYPE blocky_fallback_check gauge",
    ]
    lines += [f'blocky_fallback_check{{check="{k}"}} {v}' for k, v in sorted(results.items())]
    if ra is not None:
        heard, state = ra
        lines += [
            "# HELP blocky_fallback_ra_heard 1 if a router advertisement answered the probe's solicitation.",
            "# TYPE blocky_fallback_ra_heard gauge",
            f"blocky_fallback_ra_heard {int(heard)}",
            "# HELP blocky_fallback_ra_rdnss 1 for the state of the DNS servers that routers announce.",
            "# TYPE blocky_fallback_ra_rdnss gauge",
        ]
        # If the probe hears no RA and stores no valid server, the state is unknown: all three are 0.
        known = heard or state != "none"
        lines += [f'blocky_fallback_ra_rdnss{{state="{s}"}} {int(known and s == state)}'
                  for s in ("fallback_only", "none", "other")]
    # node-exporter must never read a half-written file.
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".blocky_fallback.")
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--server", required=True)
    p.add_argument("--internal-name", required=True)
    p.add_argument("--internal-ips", required=True, help="comma-separated")
    p.add_argument("--out", required=True)
    p.add_argument("--server6", default="", help="the IPv6 listener; empty if there is none")
    p.add_argument("--ra-iface", default="", help="send a Router Solicitation on this NIC")
    p.add_argument("--state", default="", help="JSON file that keeps announced DNS servers between runs")
    a = p.parse_args()
    results = run_checks(lambda n: query(a.server, n), a.internal_name, set(a.internal_ips.split(",")))
    if a.server6:
        try:
            query(a.server6, "healthcheck.blocky")
            results["listener6"] = 1
        except (OSError, ValueError, struct.error, IndexError):
            results["listener6"] = 0
    ra = None
    if a.ra_iface:
        try:
            heard, seen = solicit_rdnss(a.ra_iface)
        except OSError:
            heard, seen = False, []
        now = time.time()
        known = merge_rdnss(load_state(a.state) if a.state else {}, seen, now)
        if a.state:
            save_state(a.state, known)
        ra = (heard, rdnss_state(set(known), a.server6))
    write_metrics(a.out, results, ra)


if __name__ == "__main__":
    main()
