"""Keep the Cloudflare Tunnel's stored routes equal to tunnel-config.json from git.

Run hourly by CronJob cloudflared-route-sync. Writes only if SYNC_WRITE is "true".
Logs never hold the token, a header, a hostname, a service or a reply body: only
fixed messages, HTTP status codes and redacted field paths.
"""

import decimal
import http.client
import json
import math
import os
import re
import signal
import ssl
import sys
import urllib.error
import urllib.request

API_HOST = "api.cloudflare.com"
# TIMEOUT limits each socket operation. BUDGET sets a wall-clock alarm over one exchange:
# connect, headers and body. Python runs the alarm handler only between bytecode steps, so a
# blocking system DNS lookup can overrun BUDGET; the Job's activeDeadlineSeconds (120) is the
# outer limit.
TIMEOUT = 10
BUDGET = 15
# Tunnel configs take a few kilobytes. If a reply exceeds MAX_REPLY, the script discards its body.
MAX_REPLY = 1_000_000

# Cloudflare may add values to the stored config that git does not state. Each entry is
# (path pattern, value, source); "*" matches any list index. A difference seen in a dry
# run is not a source: only a Cloudflare document that states the default is.
# warp-routing must never appear here: a GET without it has to compare unequal.
DEFAULTS = []

# Schema keys that may appear in a log line. Any other key could be a hostname, so the
# log names only its nearest known parent and a count.
KNOWN_KEYS = {
    "ingress", "warp-routing", "originRequest", "enabled", "hostname", "service", "path",
    "access", "caPool", "connectTimeout", "disableChunkedEncoding", "http2Origin",
    "httpHostHeader", "keepAliveConnections", "keepAliveTimeout", "noHappyEyeballs",
    "noTLSVerify", "originServerName", "proxyType", "tcpKeepAlive", "tlsTimeout",
    "matchSNItoHost", "required", "teamName", "audTag",
}

TOKEN_RE = re.compile(r"^[A-Za-z0-9_\-.~+/=]{20,200}$")
ACCOUNT_RE = re.compile(r"^[0-9a-f]{32}$", re.IGNORECASE)
TUNNEL_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.IGNORECASE)


class Failure(Exception):
    """A run that must exit 1. The message is fixed text, safe to log."""


class Unconfirmed(Exception):
    """The request may or may not have reached Cloudflare."""


class Deadline(Exception):
    """BUDGET ran out. Not an OSError: socket.create_connection catches OSError and tries the
    next address, which would start a new attempt after the deadline."""


def log(msg):
    print(msg, flush=True)


def validate_desired(cfg):
    if not isinstance(cfg, dict):
        raise Failure("desired config is not a JSON object")
    warp = cfg.get("warp-routing")
    if not isinstance(warp, dict) or warp.get("enabled") is not True:
        raise Failure("desired warp-routing.enabled is not true")
    ingress = cfg.get("ingress")
    if not isinstance(ingress, list) or not ingress:
        raise Failure("desired ingress is missing or empty")
    last = ingress[-1]
    if not isinstance(last, dict) or "hostname" in last or "path" in last:
        raise Failure("last ingress rule must match every request")
    svc = last.get("service")
    if not isinstance(svc, str) or not svc:
        raise Failure("last ingress rule has no service")


def _canon(x):
    # JSON numbers compare by exact decimal value: 1 equals 1.0 and -0.0, and 1e23 equals the
    # integer 10**23 (int(1e23) would not). Decimal equality never rounds. Booleans stay apart
    # from numbers, and the tuple tag cannot collide with any value JSON produces.
    if isinstance(x, dict):
        return {k: _canon(v) for k, v in x.items()}
    if isinstance(x, list):
        return [_canon(v) for v in x]
    if isinstance(x, bool) or not isinstance(x, (int, float)):
        return x
    return ("number", decimal.Decimal(repr(x)) if isinstance(x, float) else decimal.Decimal(x))


def same(a, b):
    """JSON equality. Python's == treats True as 1, so `enabled: 1` would pass for `true`."""
    return _canon(a) == _canon(b)


def _matches(pattern, path):
    return len(pattern) == len(path) and all(
        isinstance(q, int) if p == "*" else p == q for p, q in zip(pattern, path)
    )


def normalise(obj, path=()):
    """Copy obj without the listed defaults (exact path, exact value)."""
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            sub = path + (k,)
            if "warp-routing" not in sub and any(_matches(p, sub) and same(v, val) for p, val, _ in DEFAULTS):
                continue
            out[k] = normalise(v, sub)
        return out
    if isinstance(obj, list):
        return [normalise(v, path + (i,)) for i, v in enumerate(obj)]
    return obj


def _fmt(path):
    s = ""
    for p in path:
        s += f"[{p}]" if isinstance(p, int) else (f".{p}" if s else p)
    return s or "config"


def diff_paths(a, b, path=()):
    """Redacted paths where a and b differ. Unknown keys are counted, never named."""
    if isinstance(a, dict) and isinstance(b, dict):
        out, unknown = [], 0
        for k in sorted(set(a) | set(b), key=str):
            if k in a and k in b and same(a[k], b[k]):
                continue
            if k in KNOWN_KEYS:
                if k in a and k in b:
                    out += diff_paths(a[k], b[k], path + (k,))
                else:
                    out.append(_fmt(path + (k,)))
            else:
                unknown += 1
        if unknown:
            out.append(f"{_fmt(path)}: {unknown} unknown key(s)")
        return out
    if isinstance(a, list) and isinstance(b, list):
        out = []
        for i in range(max(len(a), len(b))):
            if i >= len(a) or i >= len(b):
                out.append(_fmt(path + (i,)))
            elif not same(a[i], b[i]):
                out += diff_paths(a[i], b[i], path + (i,))
        return out
    return [_fmt(path)]


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    # Returning None makes urllib raise HTTPError for the 3xx instead of following it, so the
    # bearer token never goes to another host. These run before urllib parses Location, which
    # raises ValueError on a malformed value.
    def _refuse(self, req, fp, code, msg, headers):
        return None

    http_error_301 = http_error_302 = http_error_303 = http_error_307 = http_error_308 = _refuse


def _opener():
    return urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=ssl.create_default_context()), _NoRedirect()
    )


def _expire(signum, frame):
    raise Deadline()


def _no_constant(name):
    # Python's JSON parser accepts NaN and Infinity, which JSON does not allow.
    raise ValueError("non-finite number")


def _exact_float(text):
    # float() rounds 9007199254740993e0 and turns 1e400 into infinity; either would compare or
    # send a value different from the text. Accept a number only if the float's shortest form
    # (what json.dumps writes back) has the same value as the text, as 0.1 does.
    value = float(text)
    try:
        exact = decimal.Decimal(text)
    except decimal.InvalidOperation:  # an exponent beyond Decimal's range
        raise ValueError("number out of range")
    if not math.isfinite(value) or decimal.Decimal(repr(value)) != exact:
        raise ValueError("number not exactly representable")
    return value


def _reply_pairs(pairs):
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError("duplicate key")  # an ambiguous reply is unusable
    return dict(pairs)


def http_request(method, url, token, body=None):
    """Return (status, parsed JSON or None). Raise Unconfirmed if no reply arrived."""
    data = json.dumps(body, allow_nan=False).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json")
    previous = signal.signal(signal.SIGALRM, _expire)
    signal.setitimer(signal.ITIMER_REAL, BUDGET)
    try:
        with _opener().open(req, timeout=TIMEOUT) as resp:
            # Headers arrived, so Cloudflare answered. If the body then fails, keep the status.
            status, raw = resp.status, b""
            try:
                while len(raw) <= MAX_REPLY:
                    chunk = resp.read1(65536)
                    if not chunk:
                        break
                    raw += chunk
                # read1 returns b"" instead of raising if the connection closes early.
                if getattr(resp, "length", None):
                    return status, None
            except (OSError, http.client.HTTPException, Deadline):
                return status, None
    except urllib.error.HTTPError as e:
        # The status is all the script uses from an error reply. Reading its body could
        # itself time out and lose the status.
        e.close()
        return e.code, None
    except (OSError, http.client.HTTPException, Deadline):  # timeout, reset, closed, TLS
        raise Unconfirmed()
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
    if len(raw) > MAX_REPLY:
        return status, None
    try:
        return status, json.loads(raw, object_pairs_hook=_reply_pairs, parse_constant=_no_constant, parse_float=_exact_float)
    except (ValueError, RecursionError):
        return status, None


def get_config(request, url, token):
    try:
        status, reply = request("GET", url, token)
    except Unconfirmed:
        raise Failure("GET got no reply")
    if not 200 <= status < 300:
        raise Failure(f"GET failed (HTTP {status})")
    if not isinstance(reply, dict) or reply.get("success") is not True:
        raise Failure(f"GET reply not a success (HTTP {status})")
    result = reply.get("result")
    cfg = result.get("config") if isinstance(result, dict) else None
    if not isinstance(cfg, dict):
        raise Failure("GET reply has no config object")
    return cfg


def put_config(request, url, token, desired):
    try:
        status, reply = request("PUT", url, token, {"config": desired})
    except Unconfirmed:
        raise Failure("write unconfirmed")
    # 5xx and 3xx first: Cloudflare may have applied the PUT before a gateway error or a
    # redirect, and a 5xx body can still say success:false. The redirect is never followed.
    if status >= 500 or 300 <= status < 400:
        raise Failure(f"write unconfirmed (HTTP {status})")
    if not 200 <= status < 300 or (isinstance(reply, dict) and reply.get("success") is False):
        raise Failure(f"write failed (HTTP {status})")
    # A 2xx without a usable success flag leaves the outcome open; the verification GET decides.


def run(desired, token, account, tunnel, write, request):
    validate_desired(desired)
    if not TOKEN_RE.match(token):
        raise Failure("API token has characters not allowed in a header")
    if not ACCOUNT_RE.match(account) or not TUNNEL_RE.match(tunnel):
        raise Failure("account or tunnel ID is malformed")
    url = f"https://{API_HOST}/client/v4/accounts/{account}/cfd_tunnel/{tunnel}/configurations"

    stored = get_config(request, url, token)
    want = normalise(desired)
    if same(normalise(stored), want):
        log("in sync")
        return
    for p in diff_paths(want, normalise(stored)):
        log(f"differs: {p}")
    if not write:
        log("would update")
        return
    put_config(request, url, token, desired)
    try:
        after = get_config(request, url, token)
    except Failure:
        raise Failure("write unconfirmed (verification GET failed)")
    if not same(normalise(after), want):
        raise Failure("write unconfirmed (verification GET differs)")
    log("updated")


def _no_duplicate_keys(pairs):
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        # json.loads would keep only the last copy, so a second "ingress" could replace every route.
        raise Failure("desired config has a duplicate key")
    return dict(pairs)


def _read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def main():
    step = "read inputs"
    try:
        try:
            desired = json.loads(
                _read(os.environ.get("DESIRED_FILE", "/config/tunnel-config.json")),
                object_pairs_hook=_no_duplicate_keys,
                parse_constant=_no_constant,
                parse_float=_exact_float,
            )
        except ValueError:
            raise Failure("desired config is not valid JSON")
        secrets = os.environ.get("SECRETS_DIR", "/secrets")
        token = _read(os.path.join(secrets, "api-token")).strip()
        account = _read(os.path.join(secrets, "CF_ACCOUNT_ID")).strip()
        tunnel = _read(os.path.join(secrets, "CF_TUNNEL_UUID")).strip()
        write = os.environ.get("SYNC_WRITE") == "true"
        step = "sync"
        run(desired, token, account, tunnel, write, http_request)
        return 0
    except Failure as e:
        log(str(e))
    except Exception:  # noqa: BLE001 -- never print exception text: it can hold a header or a hostname
        log(f"unexpected error during {step}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
