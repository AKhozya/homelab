"""Offline tests for sync.py. Run: python3 -m unittest discover -s <this dir> -v"""

import contextlib
import copy
import http.server
import io
import json
import os
import socket
import sys
import tempfile
import threading
import time
import unittest
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import sync

ACCOUNT = "0123456789abcdef0123456789abcdef"
TUNNEL = "01234567-89ab-cdef-0123-456789abcdef"
TOKEN = "dummyTokenValue_0123456789abcdef"


def load(name):
    with open(os.path.join(HERE, name), encoding="utf-8") as f:
        return json.load(f)


DESIRED = load("desired.json")
GET_REPLY = load("get-reply.json")  # shape of the GET example in Cloudflare's API reference


def reply_with(cfg):
    r = copy.deepcopy(GET_REPLY)
    r["result"]["config"] = cfg
    return r


class FakeApi:
    """Stands in for http_request. Each GET returns the next stored config."""

    def __init__(self, stored, put=(200, {"success": True}), after=None, get_error=None):
        self.stored, self.put, self.after, self.get_error = stored, put, after, get_error
        self.calls, self.bodies = [], []

    def __call__(self, method, url, token, body=None):
        self.calls.append(method)
        if body is not None:
            self.bodies.append(body)
        if method == "PUT":
            if isinstance(self.put, Exception):
                raise self.put
            return self.put
        n = self.calls.count("GET")
        if n > 1 and self.get_error:
            raise self.get_error
        cfg = self.stored if n == 1 or self.after is None else self.after
        return 200, reply_with(cfg)


def run(desired, api, write=True):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        try:
            sync.run(desired, TOKEN, ACCOUNT, TUNNEL, write, api)
            rc = 0
        except sync.Failure as e:
            sync.log(str(e))
            rc = 1
    return rc, out.getvalue()


class Compare(unittest.TestCase):
    def test_equal_is_in_sync(self):
        api = FakeApi(copy.deepcopy(DESIRED))
        self.assertEqual(run(DESIRED, api), (0, "in sync\n"))
        self.assertEqual(api.calls, ["GET"])

    def test_listed_default_in_stored(self):
        stored = copy.deepcopy(DESIRED)
        stored["ingress"][0]["originRequest"] = {}
        with _defaults([(("ingress", "*", "originRequest"), {}, "test")]):
            self.assertEqual(run(DESIRED, FakeApi(stored)), (0, "in sync\n"))

    def test_listed_default_stated_in_desired(self):
        desired = copy.deepcopy(DESIRED)
        desired["ingress"][0]["originRequest"] = {}
        with _defaults([(("ingress", "*", "originRequest"), {}, "test")]):
            self.assertEqual(run(desired, FakeApi(copy.deepcopy(DESIRED))), (0, "in sync\n"))

    def test_non_default_value_at_default_path(self):
        stored = copy.deepcopy(DESIRED)
        stored["ingress"][0]["originRequest"] = {"noTLSVerify": True}
        api = FakeApi(stored, after=copy.deepcopy(DESIRED))
        with _defaults([(("ingress", "*", "originRequest"), {}, "test")]):
            rc, out = run(DESIRED, api)
        self.assertEqual(rc, 0)
        self.assertIn("differs: ingress[0].originRequest", out)
        self.assertEqual(api.calls, ["GET", "PUT", "GET"])

    def test_unknown_hostname_key_is_counted_not_named(self):
        stored = copy.deepcopy(DESIRED)
        stored["ingress"][1]["secret-app.example.org"] = {"x": 1}
        api = FakeApi(stored, after=copy.deepcopy(DESIRED))
        rc, out = run(DESIRED, api)
        self.assertEqual(rc, 0)
        self.assertIn("differs: ingress[1]: 1 unknown key(s)", out)
        self.assertNotIn("secret-app", out)
        self.assertIn("PUT", api.calls)

    def test_rule_order_matters(self):
        stored = copy.deepcopy(DESIRED)
        stored["ingress"][0], stored["ingress"][1] = stored["ingress"][1], stored["ingress"][0]
        api = FakeApi(stored, after=copy.deepcopy(DESIRED))
        rc, out = run(DESIRED, api)
        self.assertEqual((rc, out.splitlines()[-1]), (0, "updated"))
        self.assertIn("PUT", api.calls)

    def test_dry_run_never_writes(self):
        stored = copy.deepcopy(DESIRED)
        stored["ingress"].pop(0)
        api = FakeApi(stored)
        rc, out = run(DESIRED, api, write=False)
        self.assertEqual((rc, out.splitlines()[-1]), (0, "would update"))
        self.assertEqual(api.calls, ["GET"])

    def test_stored_without_warp_routing_is_not_in_sync(self):
        stored = copy.deepcopy(DESIRED)
        del stored["warp-routing"]
        rc, out = run(DESIRED, FakeApi(stored), write=False)
        self.assertEqual(rc, 0)
        self.assertIn("differs: warp-routing", out)
        self.assertNotIn("in sync", out)

    def test_warp_routing_is_never_removed_as_a_default(self):
        stored = copy.deepcopy(DESIRED)
        del stored["warp-routing"]
        with _defaults([(("warp-routing",), {"enabled": True}, "listed by mistake")]):
            rc, out = run(DESIRED, FakeApi(stored), write=False)
        self.assertEqual((rc, out.splitlines()[-1]), (0, "would update"))

    def test_true_and_1_are_different(self):
        stored = copy.deepcopy(DESIRED)
        stored["warp-routing"]["enabled"] = 1
        rc, out = run(DESIRED, FakeApi(stored), write=False)
        self.assertEqual(rc, 0)
        self.assertIn("differs: warp-routing.enabled", out)

    def test_numbers_compare_by_value(self):
        self.assertTrue(sync.same({"a": [1]}, {"a": [1.0]}))
        self.assertTrue(sync.same(1e23, 10**23))
        self.assertFalse(sync.same(1e23, 99999999999999991611392))
        self.assertFalse(sync.same(10**28, 10**28 + 1))
        self.assertTrue(sync.same(-0.0, 0))
        self.assertFalse(sync.same({"\u0000number": "1"}, 1))
        self.assertFalse(sync.same({"a": True}, {"a": 1}))
        self.assertFalse(sync.same({"a": 1}, {"a": 1.5}))

    def test_wildcard_matches_list_index_only(self):
        self.assertTrue(sync._matches(("ingress", "*"), ("ingress", 0)))
        self.assertFalse(sync._matches(("ingress", "*"), ("ingress", "key")))
        self.assertFalse(sync._matches(("ingress", "*"), ("ingress", "*")))

    def test_warp_routing_subtree_is_never_removed(self):
        stored = copy.deepcopy(DESIRED)
        stored["warp-routing"] = {}
        with _defaults([(("warp-routing", "enabled"), True, "listed by mistake")]):
            rc, out = run(DESIRED, FakeApi(stored), write=False)
        self.assertEqual((rc, out.splitlines()[-1]), (0, "would update"))

    def test_changed_hostname_is_named_by_path_only(self):
        stored = copy.deepcopy(DESIRED)
        stored["ingress"][0]["hostname"] = "renamed-app.example.org"
        rc, out = run(DESIRED, FakeApi(stored), write=False)
        self.assertEqual(rc, 0)
        self.assertIn("differs: ingress[0].hostname", out)
        self.assertNotIn("renamed-app", out)
        self.assertNotIn(DESIRED["ingress"][0]["hostname"], out)

    def test_logs_hold_no_hostname_or_service(self):
        stored = copy.deepcopy(DESIRED)
        stored["ingress"][0]["service"] = "http://other.svc:9"
        rc, out = run(DESIRED, FakeApi(stored), write=False)
        self.assertEqual(rc, 0)
        for rule in DESIRED["ingress"]:
            for v in rule.values():
                self.assertNotIn(v, out)
        self.assertNotIn("other.svc", out)


class Validate(unittest.TestCase):
    def assert_rejected(self, desired):
        api = FakeApi(copy.deepcopy(DESIRED))
        rc, _ = run(desired, api)
        self.assertEqual(rc, 1)
        self.assertEqual(api.calls, [], "no request may be made")

    def test_warp_routing_false_or_missing(self):
        for value in ({"enabled": False}, None):
            d = copy.deepcopy(DESIRED)
            if value is None:
                del d["warp-routing"]
            else:
                d["warp-routing"] = value
            self.assert_rejected(d)

    def test_last_rule_with_hostname_or_path(self):
        for extra in ({"hostname": "a.example.org"}, {"path": "/x"}):
            d = copy.deepcopy(DESIRED)
            d["ingress"][-1].update(extra)
            self.assert_rejected(d)

    def test_last_rule_service_missing_null_or_empty(self):
        for svc in ("<missing>", None, ""):
            d = copy.deepcopy(DESIRED)
            if svc == "<missing>":
                del d["ingress"][-1]["service"]
            else:
                d["ingress"][-1]["service"] = svc
            self.assert_rejected(d)

    def test_ingress_missing_or_empty(self):
        for value in ("<missing>", []):
            d = copy.deepcopy(DESIRED)
            if value == "<missing>":
                del d["ingress"]
            else:
                d["ingress"] = value
            self.assert_rejected(d)


class Inputs(unittest.TestCase):
    def test_malformed_ids_make_no_request(self):
        for account, tunnel in (("abc/../x", TUNNEL), (ACCOUNT, "not-a-uuid"), (TUNNEL, ACCOUNT),
                                ("-" * 32, TUNNEL)):
            api = FakeApi(copy.deepcopy(DESIRED))
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(sync.Failure):
                sync.run(DESIRED, TOKEN, account, tunnel, False, api)
            self.assertEqual(api.calls, [])


class Write(unittest.TestCase):
    def differing(self):
        stored = copy.deepcopy(DESIRED)
        stored["ingress"].pop(0)
        return stored

    def test_put_rejected_is_write_failed(self):
        api = FakeApi(self.differing(), put=(400, {"success": False}), after=copy.deepcopy(DESIRED))
        rc, out = run(DESIRED, api)
        self.assertEqual((rc, out.splitlines()[-1]), (1, "write failed (HTTP 400)"))
        self.assertEqual(api.calls, ["GET", "PUT"])

    def test_put_ok_then_get_differs(self):
        api = FakeApi(self.differing(), after=self.differing())
        rc, out = run(DESIRED, api)
        self.assertEqual((rc, out.splitlines()[-1]), (1, "write unconfirmed (verification GET differs)"))

    def test_put_ok_then_get_times_out(self):
        api = FakeApi(self.differing(), get_error=sync.Unconfirmed())
        rc, out = run(DESIRED, api)
        self.assertEqual((rc, out.splitlines()[-1]), (1, "write unconfirmed (verification GET failed)"))

    def test_put_no_reply(self):
        api = FakeApi(self.differing(), put=sync.Unconfirmed())
        rc, out = run(DESIRED, api)
        self.assertEqual((rc, out.splitlines()[-1]), (1, "write unconfirmed"))

    def test_put_504_with_success_false_is_unconfirmed(self):
        api = FakeApi(self.differing(), put=(504, {"success": False}))
        rc, out = run(DESIRED, api)
        self.assertEqual((rc, out.splitlines()[-1]), (1, "write unconfirmed (HTTP 504)"))

    def test_updated_only_after_confirmed_write(self):
        api = FakeApi(self.differing(), after=copy.deepcopy(DESIRED))
        rc, out = run(DESIRED, api)
        self.assertEqual((rc, out.splitlines()[-1]), (0, "updated"))
        self.assertEqual(api.bodies, [{"config": DESIRED}])

    def test_put_redirect_is_unconfirmed(self):
        api = FakeApi(self.differing(), put=(303, None))
        rc, out = run(DESIRED, api)
        self.assertEqual((rc, out.splitlines()[-1]), (1, "write unconfirmed (HTTP 303)"))
        self.assertEqual(api.calls, ["GET", "PUT"])

    def test_put_200_with_success_false_is_write_failed(self):
        api = FakeApi(self.differing(), put=(200, {"success": False}), after=copy.deepcopy(DESIRED))
        rc, out = run(DESIRED, api)
        self.assertEqual((rc, out.splitlines()[-1]), (1, "write failed (HTTP 200)"))
        self.assertEqual(api.calls, ["GET", "PUT"])

    def test_put_2xx_without_usable_body_is_decided_by_get(self):
        api = FakeApi(self.differing(), put=(200, None), after=copy.deepcopy(DESIRED))
        self.assertEqual(run(DESIRED, api)[1].splitlines()[-1], "updated")
        api = FakeApi(self.differing(), put=(200, None), after=self.differing())
        rc, out = run(DESIRED, api)
        self.assertEqual((rc, out.splitlines()[-1]), (1, "write unconfirmed (verification GET differs)"))


class Transport(unittest.TestCase):
    def test_redirect_to_another_host_is_refused(self):
        hits = {"target": 0}

        class Target(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                hits["target"] += 1
                self.send_response(200)
                self.end_headers()

            def log_message(self, *a):
                pass

        target = http.server.HTTPServer(("127.0.0.1", 0), Target)

        class Redirector(Target):
            def do_GET(self):
                self.send_response(302)
                self.send_header("Location", f"http://localhost:{target.server_port}/steal")
                self.end_headers()

        redirector = http.server.HTTPServer(("127.0.0.1", 0), Redirector)
        for s in (target, redirector):
            threading.Thread(target=s.handle_request, daemon=True).start()
        status, _ = sync.http_request("GET", f"http://127.0.0.1:{redirector.server_port}/", TOKEN)
        target.server_close()
        redirector.server_close()
        self.assertEqual(status, 302)
        self.assertEqual(hits["target"], 0)
        with self.assertRaises(sync.Failure) as caught:
            sync.get_config(lambda *a, **k: (status, None), "u", TOKEN)
        self.assertEqual(str(caught.exception), "GET failed (HTTP 302)")

    def test_error_status_survives_a_body_that_fails_to_read(self):
        class Body(io.BytesIO):
            def read(self, *a):
                raise TimeoutError()

        class Opener:
            def open(self, req, timeout):
                raise urllib.error.HTTPError(req.full_url, 504, "Gateway Timeout", {}, Body())

        orig = sync._opener
        sync._opener = Opener
        try:
            self.assertEqual(sync.http_request("PUT", "https://x/", TOKEN, {}), (504, None))
        finally:
            sync._opener = orig

    def test_body_failing_after_headers_keeps_the_status(self):
        class Resp:
            status = 200

            def read1(self, *a):
                raise TimeoutError()

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        class Opener:
            def open(self, req, timeout):
                return Resp()

        orig = sync._opener
        sync._opener = Opener
        try:
            self.assertEqual(sync.http_request("PUT", "https://x/", TOKEN, {}), (200, None))
        finally:
            sync._opener = orig

    def test_trickling_reply_stops_at_the_budget(self):
        reads = []

        class Resp:
            status = 200

            def read1(self, *a):
                reads.append(1)
                if len(reads) > 200:  # the alarm should have stopped the read long before
                    raise AssertionError("no budget stopped the read")
                time.sleep(0.02)
                return b" "

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        class Opener:
            def open(self, req, timeout):
                return Resp()

        with _patched(_opener=Opener, BUDGET=0.2):
            started = time.monotonic()
            self.assertEqual(sync.http_request("PUT", "https://x/", TOKEN, {}), (200, None))
            self.assertLess(time.monotonic() - started, 1)

    def test_deadline_during_connect_tries_no_second_address(self):
        attempts = []
        two = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("192.0.2.1", 80)),
               (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("192.0.2.2", 80))]

        test = self

        def slow_connect(sock, addr):
            attempts.append(addr)
            time.sleep(1)  # the alarm fires during this first attempt
            test.fail("connect outlasted the budget")

        orig_gai, orig_connect = socket.getaddrinfo, socket.socket.connect
        socket.getaddrinfo, socket.socket.connect = (lambda *a, **k: two), slow_connect
        try:
            with _patched(BUDGET=0.2), self.assertRaises(sync.Unconfirmed):
                sync.http_request("GET", "http://two-addresses.invalid/", TOKEN)
        finally:
            socket.getaddrinfo, socket.socket.connect = orig_gai, orig_connect
        self.assertEqual(attempts, [("192.0.2.1", 80)])

    def serve_once(self, handler_body):
        class H(http.server.BaseHTTPRequestHandler):
            def do_PUT(self):
                handler_body(self)

            do_GET = do_PUT

            def log_message(self, *a):
                pass

        srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=srv.handle_request, daemon=True).start()
        return srv

    def test_malformed_redirect_on_put_is_unconfirmed(self):
        def reply(h):
            h.send_response(302)
            h.send_header("Location", "http://[::1")
            h.send_header("Content-Length", "0")
            h.end_headers()

        srv = self.serve_once(reply)
        try:
            status, body = sync.http_request("PUT", f"http://127.0.0.1:{srv.server_port}/", TOKEN, {})
        finally:
            srv.server_close()
        self.assertEqual((status, body), (302, None))
        with self.assertRaises(sync.Failure) as caught:
            sync.put_config(lambda *a, **k: (status, body), "u", TOKEN, DESIRED)
        self.assertEqual(str(caught.exception), "write unconfirmed (HTTP 302)")

    def test_reply_shorter_than_its_length_is_unusable(self):
        def reply(h):
            body = json.dumps(reply_with(DESIRED)).encode()
            h.send_response(200)
            h.send_header("Content-Length", str(len(body) + 500))
            h.end_headers()
            h.wfile.write(body)  # the server closes before the rest arrives

        srv = self.serve_once(reply)
        try:
            self.assertEqual(sync.http_request("GET", f"http://127.0.0.1:{srv.server_port}/", TOKEN), (200, None))
        finally:
            srv.server_close()

    def test_reply_with_nan_is_unusable(self):
        class Opener:
            def open(self, req, timeout):
                r = io.BytesIO(b'{"success": true, "result": {"config": {"x": NaN}}}')
                r.status = 200
                return r

        calls = []

        class Counting(Opener):
            def open(self, req, timeout):
                calls.append(req)
                return super().open(req, timeout)

        with _patched(_opener=Counting):
            self.assertEqual(sync.http_request("GET", "https://x/", TOKEN), (200, None))
            with self.assertRaises(ValueError):
                sync.http_request("PUT", "https://x/", TOKEN, {"x": float("nan")})
        self.assertEqual(len(calls), 1, "the NaN PUT must not reach the opener")

    def test_reply_with_duplicate_key_is_unusable(self):
        class Opener:
            def open(self, req, timeout):
                r = io.BytesIO(b'{"success": true, "result": {"config": {"ingress": [], "ingress": []}}}')
                r.status = 200
                return r

        with _patched(_opener=Opener):
            self.assertEqual(sync.http_request("GET", "https://x/", TOKEN), (200, None))

    def test_slow_headers_stop_at_the_budget(self):
        class Opener:
            def open(self, req, timeout):
                time.sleep(2)  # headers never arrive within the budget

        with _patched(_opener=Opener, BUDGET=0.2):
            started = time.monotonic()
            with self.assertRaises(sync.Unconfirmed):
                sync.http_request("PUT", "https://x/", TOKEN, {})
            self.assertLess(time.monotonic() - started, 1)

    def test_deeply_nested_reply_is_unusable(self):
        class Opener:
            def open(self, req, timeout):
                r = io.BytesIO(b"[" * 200_000)
                r.status = 200
                return r

        orig = sync._opener
        sync._opener = Opener
        try:
            self.assertEqual(sync.http_request("PUT", "https://x/", TOKEN, {}), (200, None))
        finally:
            sync._opener = orig

    def test_put_request_carries_method_type_and_body(self):
        seen = []

        class Opener:
            def open(self, req, timeout):
                seen.append(req)
                r = io.BytesIO(b'{"success": true}')
                r.status = 200
                return r

        orig = sync._opener
        sync._opener = Opener
        try:
            sync.http_request("PUT", "https://x/", TOKEN, {"config": DESIRED})
        finally:
            sync._opener = orig
        self.assertEqual(seen[0].get_method(), "PUT")
        self.assertEqual(seen[0].get_header("Content-type"), "application/json")
        self.assertEqual(json.loads(seen[0].data), {"config": DESIRED})

    def test_request_url_and_header(self):
        seen = []

        class Resp(io.BytesIO):
            status = 200

        class Opener:
            def open(self, req, timeout):
                seen.append(req)
                return Resp(json.dumps(reply_with(DESIRED)).encode())

        out, err = io.StringIO(), io.StringIO()
        with _patched(_opener=Opener), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            sync.run(DESIRED, TOKEN, ACCOUNT, TUNNEL, False, sync.http_request)
        self.assertEqual((out.getvalue(), err.getvalue()), ("in sync\n", ""))
        self.assertEqual(seen[0].full_url, f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/cfd_tunnel/{TUNNEL}/configurations")
        self.assertEqual(seen[0].get_header("Authorization"), "Bearer " + TOKEN)
        self.assertEqual(seen[0].get_method(), "GET")

    def test_padded_reply_over_the_limit_is_unusable(self):
        class Padded(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = json.dumps(reply_with(DESIRED)).encode() + b" " * sync.MAX_REPLY
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        srv = http.server.HTTPServer(("127.0.0.1", 0), Padded)
        threading.Thread(target=srv.handle_request, daemon=True).start()
        try:
            self.assertEqual(sync.http_request("GET", f"http://127.0.0.1:{srv.server_port}/", TOKEN), (200, None))
        finally:
            srv.server_close()

    def test_oversized_reply_is_unusable(self):
        class Big(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = b"[" + b"0," * (sync.MAX_REPLY // 2) + b"0]"
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        srv = http.server.HTTPServer(("127.0.0.1", 0), Big)
        threading.Thread(target=srv.handle_request, daemon=True).start()
        try:
            self.assertEqual(sync.http_request("GET", f"http://127.0.0.1:{srv.server_port}/", TOKEN), (200, None))
        finally:
            srv.server_close()

    def test_no_reply_is_unconfirmed(self):
        class Opener:
            def open(self, req, timeout):
                raise ConnectionRefusedError()

        with _patched(_opener=Opener), self.assertRaises(sync.Unconfirmed):
            sync.http_request("GET", "https://x/", TOKEN)

    def test_inexact_numbers_are_rejected(self):
        for text in ("9007199254740993e0", "1e400", "1e-9999999999999999999"):
            with self.assertRaises(ValueError, msg=text):
                sync._exact_float(text)
        for text in ("0.1", "1.5e3", "30.0"):
            self.assertEqual(sync._exact_float(text), float(text))

        class Opener:
            def open(self, req, timeout):
                r = io.BytesIO(b'{"success": true, "result": {"config": {"x": 1e400}}}')
                r.status = 200
                return r

        with _patched(_opener=Opener):
            self.assertEqual(sync.http_request("GET", "https://x/", TOKEN), (200, None))


class Main(unittest.TestCase):
    def run_main(self, env_write):
        stored = copy.deepcopy(DESIRED)
        stored["ingress"].pop(0)
        api = FakeApi(stored, after=copy.deepcopy(DESIRED))
        with tempfile.TemporaryDirectory() as d:
            for name, value in (("api-token", TOKEN), ("CF_ACCOUNT_ID", ACCOUNT), ("CF_TUNNEL_UUID", TUNNEL)):
                with open(os.path.join(d, name), "w") as f:
                    f.write(value + "\n")
            desired = os.path.join(d, "tunnel-config.json")
            with open(desired, "w") as f:
                json.dump(DESIRED, f)
            env = {"DESIRED_FILE": desired, "SECRETS_DIR": d}
            saved = os.environ.pop("SYNC_WRITE", None)
            if env_write is not None:
                env["SYNC_WRITE"] = env_write
            orig = sync.http_request
            sync.http_request = api
            try:
                with _env(env), contextlib.redirect_stdout(io.StringIO()):
                    rc = sync.main()
            finally:
                sync.http_request = orig
                os.environ.pop("SYNC_WRITE", None)
                if saved is not None:
                    os.environ["SYNC_WRITE"] = saved
        return rc, api.calls

    def test_duplicate_key_in_desired_file_stops_before_any_request(self):
        with tempfile.TemporaryDirectory() as d:
            for name, value in (("api-token", TOKEN), ("CF_ACCOUNT_ID", ACCOUNT), ("CF_TUNNEL_UUID", TUNNEL)):
                with open(os.path.join(d, name), "w") as f:
                    f.write(value)
            desired = os.path.join(d, "tunnel-config.json")
            with open(desired, "w") as f:
                first = json.dumps(DESIRED["ingress"])
                f.write('{"ingress": ' + first + ', "ingress": [{"service": "http_status:404"}], '
                        '"warp-routing": {"enabled": true}}')
            calls, out = [], io.StringIO()
            with _patched(http_request=lambda *a, **k: calls.append(a) or (200, None)), \
                    _env({"DESIRED_FILE": desired, "SECRETS_DIR": d, "SYNC_WRITE": "true"}), \
                    contextlib.redirect_stdout(out):
                rc = sync.main()
        self.assertEqual((rc, calls), (1, []))
        self.assertEqual(out.getvalue(), "desired config has a duplicate key\n")

    def test_nan_in_desired_file_stops_before_any_request(self):
        with tempfile.TemporaryDirectory() as d:
            for name, value in (("api-token", TOKEN), ("CF_ACCOUNT_ID", ACCOUNT), ("CF_TUNNEL_UUID", TUNNEL)):
                with open(os.path.join(d, name), "w") as f:
                    f.write(value)
            desired = os.path.join(d, "tunnel-config.json")
            with open(desired, "w") as f:
                f.write(json.dumps(DESIRED)[:-1] + ', "x": NaN}')
            calls, out = [], io.StringIO()
            with _patched(http_request=lambda *a, **k: calls.append(a) or (200, None)), \
                    _env({"DESIRED_FILE": desired, "SECRETS_DIR": d}), contextlib.redirect_stdout(out):
                rc = sync.main()
        self.assertEqual((rc, calls, out.getvalue()), (1, [], "desired config is not valid JSON\n"))

    def test_inexact_number_in_desired_file_stops_before_any_request(self):
        with tempfile.TemporaryDirectory() as d:
            for name, value in (("api-token", TOKEN), ("CF_ACCOUNT_ID", ACCOUNT), ("CF_TUNNEL_UUID", TUNNEL)):
                with open(os.path.join(d, name), "w") as f:
                    f.write(value)
            desired = os.path.join(d, "tunnel-config.json")
            with open(desired, "w") as f:
                f.write(json.dumps(DESIRED)[:-1] + ', "x": 9007199254740993e0}')
            calls, out = [], io.StringIO()
            with _patched(http_request=lambda *a, **k: calls.append(a) or (200, None)), \
                    _env({"DESIRED_FILE": desired, "SECRETS_DIR": d}), contextlib.redirect_stdout(out):
                rc = sync.main()
        self.assertEqual((rc, calls, out.getvalue()), (1, [], "desired config is not valid JSON\n"))

    def test_writes_only_when_sync_write_is_exactly_true(self):
        for value in (None, "false", "TRUE", "1", ""):
            self.assertEqual(self.run_main(value), (0, ["GET"]), value)
        self.assertEqual(self.run_main("true"), (0, ["GET", "PUT", "GET"]))

    def test_token_with_newline_is_never_printed(self):
        with tempfile.TemporaryDirectory() as d:
            for name, value in (("api-token", "leakyPart1\nleakyPart2_0123456789"),
                                ("CF_ACCOUNT_ID", ACCOUNT), ("CF_TUNNEL_UUID", TUNNEL)):
                with open(os.path.join(d, name), "w") as f:
                    f.write(value)
            desired = os.path.join(d, "tunnel-config.json")
            with open(desired, "w") as f:
                json.dump(DESIRED, f)
            out, err = io.StringIO(), io.StringIO()
            env = {"DESIRED_FILE": desired, "SECRETS_DIR": d}
            calls = []
            orig = sync.http_request
            sync.http_request = lambda *a, **k: calls.append(a) or (200, None)
            try:
                with _env(env), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    rc = sync.main()
            finally:
                sync.http_request = orig
        self.assertEqual(rc, 1)
        self.assertEqual(calls, [])
        for stream in (out.getvalue(), err.getvalue()):
            self.assertNotIn("leakyPart", stream)


@contextlib.contextmanager
def _patched(**attrs):
    saved = {k: getattr(sync, k) for k in attrs}
    for k, v in attrs.items():
        setattr(sync, k, v)
    try:
        yield
    finally:
        for k, v in saved.items():
            setattr(sync, k, v)


@contextlib.contextmanager
def _defaults(entries):
    saved = sync.DEFAULTS
    sync.DEFAULTS = entries
    try:
        yield
    finally:
        sync.DEFAULTS = saved


@contextlib.contextmanager
def _env(values):
    saved = {k: os.environ.get(k) for k in values}
    os.environ.update(values)
    try:
        yield
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


if __name__ == "__main__":
    unittest.main()
