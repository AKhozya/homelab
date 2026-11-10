#!/usr/bin/env python3
"""Functional probe of the Blocky fallback. Writes one gauge per check to a node-exporter textfile.

Standard library only: the CP has no dig, and the probe must not depend on what it probes.
Checks, each blocky_fallback_check{check=...} 1 or 0:
  listener  any well-formed reply to healthcheck.blocky (Blocky answers it itself)
  internal  the customDNS name answers with one of its configured addresses
  blocking  doubleclick.net answers 0.0.0.0 (Pro++ lists it; blockType zeroIp)
  public    example.com answers a non-zero address (needs the WAN and an upstream)
"""

import argparse
import os
import random
import socket
import struct
import tempfile

TIMEOUT_S = 3


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
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(TIMEOUT_S)
        s.sendto(build_query(qid, name), (server, 53))
        msg, _ = s.recvfrom(4096)
    return parse_reply(msg, qid)


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
        "public": check("example.com", lambda rcode, addrs: rcode == 0 and any(a != "0.0.0.0" for a in addrs)),
    }


def write_metrics(path, results):
    lines = [
        "# HELP blocky_fallback_check 1 if the CP's Blocky fallback passed this functional DNS check.",
        "# TYPE blocky_fallback_check gauge",
    ]
    lines += [f'blocky_fallback_check{{check="{k}"}} {v}' for k, v in sorted(results.items())]
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
    a = p.parse_args()
    results = run_checks(lambda n: query(a.server, n), a.internal_name, set(a.internal_ips.split(",")))
    write_metrics(a.out, results)


if __name__ == "__main__":
    main()
