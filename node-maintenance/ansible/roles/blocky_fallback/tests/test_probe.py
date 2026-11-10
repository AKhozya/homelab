"""Unit tests for files/blocky-fallback-probe.py.

replies.json holds raw replies recorded from Blocky v0.36.0 serving the derived fallback config
(2026-11-10). Run: python3 -I tests/test_probe.py
"""

import importlib.util
import json
import pathlib
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


if __name__ == "__main__":
    unittest.main()
