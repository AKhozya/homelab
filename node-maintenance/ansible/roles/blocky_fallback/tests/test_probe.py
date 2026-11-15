"""Unit tests for files/blocky-fallback-probe.py.

replies.json holds raw replies recorded from Blocky v0.36.0 serving the derived fallback config
(2026-11-10). Run: python3 -I tests/test_probe.py
"""

import importlib.util
import json
import pathlib
import socket
import struct
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("probe", HERE.parent / "files" / "blocky-fallback-probe.py")
probe = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(probe)

REPLIES = {r["name"]: r for r in json.loads((HERE / "replies.json").read_text())}
INTERNAL_IPS = {"192.168.1.129", "192.168.1.126"}


def recorded(overrides=None):
    """ask() that serves recorded replies; overrides maps a queried name to another recorded name."""
    overrides = overrides or {}

    def ask(name):
        r = REPLIES[overrides.get(name, name)]
        return probe.parse_reply(bytes.fromhex(r["reply_hex"]), r["qid"])

    return ask


class ParseReply(unittest.TestCase):
    def test_a_records(self):
        r = REPLIES["h0melab.work"]
        self.assertEqual(probe.parse_reply(bytes.fromhex(r["reply_hex"]), r["qid"]),
                         (0, ["192.168.1.129", "192.168.1.126"]))

    def test_nxdomain(self):
        r = REPLIES["no-such-name-xyz.invalid"]
        self.assertEqual(probe.parse_reply(bytes.fromhex(r["reply_hex"]), r["qid"]), (3, []))

    def test_wrong_id_is_rejected(self):
        r = REPLIES["example.com"]
        with self.assertRaises(ValueError):
            probe.parse_reply(bytes.fromhex(r["reply_hex"]), r["qid"] + 1)

    def test_query_is_echoed_by_reply(self):
        r = REPLIES["example.com"]
        query = probe.build_query(r["qid"], "example.com")
        # Blocky echoes the question section, so the reply starts with the query's ID and question.
        self.assertEqual(bytes.fromhex(r["reply_hex"])[12:len(query)], query[12:])


class RunChecks(unittest.TestCase):
    def test_all_pass_on_recorded_replies(self):
        self.assertEqual(probe.run_checks(recorded(), "h0melab.work", INTERNAL_IPS),
                         {"listener": 1, "internal": 1, "blocking": 1, "public": 1})

    def test_internal_fails_on_wrong_address(self):
        res = probe.run_checks(recorded(), "h0melab.work", {"10.0.0.1"})
        self.assertEqual(res["internal"], 0)

    def test_internal_fails_on_nxdomain(self):
        res = probe.run_checks(recorded({"h0melab.work": "no-such-name-xyz.invalid"}), "h0melab.work", INTERNAL_IPS)
        self.assertEqual(res["internal"], 0)

    def test_blocking_fails_when_tracker_resolves(self):
        res = probe.run_checks(recorded({"doubleclick.net": "example.com"}), "h0melab.work", INTERNAL_IPS)
        self.assertEqual(res["blocking"], 0)

    def test_public_fails_on_zero_ip(self):
        res = probe.run_checks(recorded({"example.com": "doubleclick.net"}), "h0melab.work", INTERNAL_IPS)
        self.assertEqual(res["public"], 0)

    def test_timeout_fails_every_check(self):
        def ask(name):
            raise TimeoutError("no reply")

        self.assertEqual(set(probe.run_checks(ask, "h0melab.work", INTERNAL_IPS).values()), {0})


class WriteMetrics(unittest.TestCase):
    def test_writes_one_gauge_per_check(self):
        with tempfile.TemporaryDirectory() as d:
            out = pathlib.Path(d) / "blocky_fallback.prom"
            probe.write_metrics(str(out), {"listener": 1, "public": 0})
            text = out.read_text()
            self.assertIn('blocky_fallback_check{check="listener"} 1\n', text)
            self.assertIn('blocky_fallback_check{check="public"} 0\n', text)
            self.assertEqual(sorted(p.name for p in pathlib.Path(d).iterdir()), ["blocky_fallback.prom"])


def ra(*options):
    """An RA as a raw ICMPv6 socket returns it: 16-byte header, then the options."""
    return bytes([134, 0, 0, 0, 64, 0, 0, 0]) + bytes(8) + b"".join(options)


def rdnss_opt(lifetime, *addrs):
    body = struct.pack(">HI", 0, lifetime) + b"".join(socket.inet_pton(socket.AF_INET6, a) for a in addrs)
    return bytes([25, (len(body) + 2) // 8]) + body


# Prefix Information option for fd00:db8:2::/64, as the eero sends it (type 3, length 4).
PIO = bytes([3, 4, 64, 0xC0]) + struct.pack(">II", 2592000, 604800) + bytes(4) + \
    socket.inet_pton(socket.AF_INET6, "fd00:db8:2::")


class ParseRA(unittest.TestCase):
    # Hand-built bytes. Replace with an RA captured from the eero once IPv6 is on (plan W3).
    def test_rdnss_after_a_prefix_option(self):
        self.assertEqual(probe.parse_ra_rdnss(ra(PIO, rdnss_opt(300, "fd00:db8:2::53", "2001:4860:4860::8888"))),
                         [("fd00:db8:2::53", 300), ("2001:4860:4860::8888", 300)])

    def test_no_rdnss(self):
        self.assertEqual(probe.parse_ra_rdnss(ra(PIO)), [])

    def test_zero_lifetime_is_kept_as_a_withdrawal(self):
        self.assertEqual(probe.parse_ra_rdnss(ra(rdnss_opt(0, "2001:4860:4860::8888"))),
                         [("2001:4860:4860::8888", 0)])

    def test_zero_length_option_is_rejected(self):
        with self.assertRaises(ValueError):
            probe.parse_ra_rdnss(ra(bytes([1, 0, 0, 0, 0, 0, 0, 0])))

    def test_option_past_the_end_is_rejected(self):
        with self.assertRaises(ValueError):
            probe.parse_ra_rdnss(ra(rdnss_opt(300, "fd00:db8:2::53"))[:-4])

    def test_not_an_ra(self):
        with self.assertRaises(ValueError):
            probe.parse_ra_rdnss(bytes([133, 0, 0, 0]) + bytes(12))


class CapturedRA(unittest.TestCase):
    # ras.json holds RAs the Mac captured on 2026-11-15. Entries 0-2 are Thread border router RAs from
    # while the eero's IPv6 was off: a prefix and a route option, router lifetime 0, no RDNSS. Entry 3
    # is the eero's own RA with IPv6 on: two prefixes, RDNSS and a source link-layer option.
    # Documentation values stand in for the prefixes, the addresses and the MAC. The checksum is 0.
    def test_thread_border_router_ras_have_no_rdnss(self):
        ras = json.loads((HERE / "ras.json").read_text())[:3]
        self.assertEqual(len(ras), 3)
        for r in ras:
            self.assertEqual(probe.parse_ra_rdnss(bytes.fromhex(r["ra_hex"])), [])

    def test_eero_ra_announces_only_the_fallback(self):
        ra = bytes.fromhex(json.loads((HERE / "ras.json").read_text())[3]["ra_hex"])
        self.assertEqual(len(ra), 112)
        seen = probe.parse_ra_rdnss(ra)
        self.assertEqual(seen, [("fd00:db8:1::53", 1800)])
        self.assertEqual(probe.rdnss_state({a for a, _ in seen}, "fd00:db8:1::53"), "fallback_only")

    def test_captured_ra_with_rdnss_appended(self):
        ra = bytes.fromhex(json.loads((HERE / "ras.json").read_text())[0]["ra_hex"])
        self.assertEqual(probe.parse_ra_rdnss(ra + rdnss_opt(300, "fd00:db8:2::53")), [("fd00:db8:2::53", 300)])


class MergeRdnss(unittest.TestCase):
    G = "2001:4860:4860::8888"

    def test_a_later_reply_without_the_server_keeps_it(self):
        known = probe.merge_rdnss({}, [(self.G, 600)], now=1000)
        # The next run hears only the Thread routers, which announce no RDNSS.
        known = probe.merge_rdnss(known, [], now=1060)
        self.assertEqual(probe.rdnss_state(set(known), "fd00:db8:2::53"), "other")

    def test_the_server_expires_at_its_lifetime(self):
        known = probe.merge_rdnss({}, [(self.G, 600)], now=1000)
        self.assertIn(self.G, probe.merge_rdnss(known, [], now=1599))
        self.assertEqual(probe.merge_rdnss(known, [], now=1600), {})

    def test_zero_lifetime_withdraws_it(self):
        known = probe.merge_rdnss({}, [(self.G, 600)], now=1000)
        self.assertEqual(probe.merge_rdnss(known, [(self.G, 0)], now=1060), {})

    def test_all_ones_never_expires(self):
        known = probe.merge_rdnss({}, [(self.G, 0xFFFFFFFF)], now=1000)
        self.assertIn(self.G, probe.merge_rdnss(known, [], now=10**12))

    def test_state_file_round_trip_and_bad_file(self):
        with tempfile.TemporaryDirectory() as d:
            path = str(pathlib.Path(d) / "rdnss.json")
            self.assertEqual(probe.load_state(path), {})
            probe.save_state(path, {self.G: float("inf"), "fd00:db8:2::53": 2000.0})
            back = probe.load_state(path)
            self.assertEqual(back["fd00:db8:2::53"], 2000.0)
            self.assertIn(self.G, probe.merge_rdnss(back, [], now=10**12))
            pathlib.Path(path).write_text("[1, 2]")
            self.assertEqual(probe.load_state(path), {})


class RdnssState(unittest.TestCase):
    def test_states(self):
        f = "fd00:db8:2::53"
        self.assertEqual(probe.rdnss_state(set(), f), "none")
        self.assertEqual(probe.rdnss_state({f}, f), "fallback_only")
        self.assertEqual(probe.rdnss_state({f, "2001:4860:4860::8888"}, f), "other")
        # No IPv6 listener: any announced server bypasses Blocky.
        self.assertEqual(probe.rdnss_state({f}, ""), "other")


class WriteRAMetrics(unittest.TestCase):
    def metrics(self, ra_result):
        with tempfile.TemporaryDirectory() as d:
            out = pathlib.Path(d) / "blocky_fallback.prom"
            probe.write_metrics(str(out), {"listener": 1}, ra_result)
            return out.read_text()

    def test_one_hot_state(self):
        text = self.metrics((True, "other"))
        self.assertIn("blocky_fallback_ra_heard 1\n", text)
        self.assertIn('blocky_fallback_ra_rdnss{state="other"} 1\n', text)
        self.assertIn('blocky_fallback_ra_rdnss{state="none"} 0\n', text)

    def test_a_stored_bypass_shows_while_nothing_is_heard(self):
        text = self.metrics((False, "other"))
        self.assertIn("blocky_fallback_ra_heard 0\n", text)
        self.assertIn('blocky_fallback_ra_rdnss{state="other"} 1\n', text)

    def test_nothing_heard_sets_no_state(self):
        text = self.metrics((False, "none"))
        self.assertIn("blocky_fallback_ra_heard 0\n", text)
        self.assertNotIn("} 1\n", text.replace('check="listener"} 1', ""))

    def test_no_ra_check_writes_no_ra_series(self):
        self.assertNotIn("blocky_fallback_ra", self.metrics(None))


if __name__ == "__main__":
    unittest.main()
