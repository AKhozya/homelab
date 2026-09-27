#!/usr/bin/env bash
# oidc-verify.sh — verify a homelab app's Authentik OIDC wiring without a browser.
#
# Two checks, both read-only HTTP probes:
#   1. Discovery endpoint returns 200 + a valid issuer  → the Authentik application/slug exists.
#   2. authorize-endpoint redirect_uri allowlist probe   → the provider accepts the app's REAL
#      callback host (302/login) vs rejects it (400 / "invalid redirect uri").
#
# Catches the F-43 footgun (2026-05-31): OIDC_SETUP.md documented the wrong HA host
# (homeassistant.h0melab.work) while the real ingress host is ha.h0melab.work — a mismatched
# redirect_uri makes login fail at the callback even though discovery succeeds.
#
# Assumes client_id == application slug (homelab convention). Self-signed/internal certs → -k.
#
# Exit: 0 = OK, 1 = misconfigured, 2 = usage / probe inconclusive (network failure).
#
# Usage:  oidc-verify.sh <app-slug> <callback-url> [authentik-host]
#   e.g.  oidc-verify.sh home-assistant https://ha.h0melab.work/auth/oidc/callback
set -euo pipefail

usage() {
  echo "usage: oidc-verify.sh <app-slug> <callback-url> [authentik-host]" >&2
  exit 2
}

slug="${1:-}"
callback="${2:-}"
authentik_host="${3:-authentik.h0melab.work}"
[[ -n "$slug" && -n "$callback" ]] || usage

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

discovery="https://${authentik_host}/application/o/${slug}/.well-known/openid-configuration"
authorize="https://${authentik_host}/application/o/authorize/"
fail=0

# 1. Discovery
code="$(curl -sk -o "$tmp/disc.json" -w '%{http_code}' --max-time 12 "$discovery" || true)"
if [[ "$code" == "200" ]] && jq -e .issuer "$tmp/disc.json" >/dev/null 2>&1; then
  echo "✅ discovery 200 + issuer present: $discovery"
elif [[ "$code" == "000" || "$code" == 5* ]]; then
  # 000 = never connected; 5xx = server-side trouble. Neither proves the slug is wrong.
  echo "⚠️ discovery probe failed (HTTP $code) — cannot conclude: $discovery"
  fail=2
else
  echo "❌ discovery HTTP $code — Authentik application slug '$slug' missing? $discovery"
  fail=1
fi

# 2. redirect_uri allowlist probe (Authentik returns 400 / error page when not allowlisted)
qs="client_id=${slug}&response_type=code&scope=openid&state=verify&redirect_uri=${callback}"
code="$(curl -sk -o "$tmp/az.html" -w '%{http_code}' --max-time 12 "${authorize}?${qs}" || true)"
if [[ "$code" == "400" ]] || grep -qiE 'redirect.uri|invalid.redirect|not.allowed|configuration error' "$tmp/az.html" 2>/dev/null; then
  echo "❌ redirect_uri NOT allowlisted (HTTP $code) — add it as a Strict redirect URI on the provider: $callback"
  fail=1
elif [[ "$code" == "200" || "$code" == "302" || "$code" == "303" ]]; then
  echo "✅ redirect_uri allowlisted (HTTP $code): $callback"
else
  # 000 = curl never connected; 5xx/etc = server-side trouble. Neither proves the allowlist.
  echo "⚠️ probe failed (HTTP $code) — cannot conclude allowlist state: $callback"
  [[ "$fail" -eq 1 ]] || fail=2
fi

if [[ "$fail" -eq 0 ]]; then
  echo "OIDC wiring OK for '$slug'"
elif [[ "$fail" -eq 2 ]]; then
  echo "OIDC wiring INCONCLUSIVE for '$slug' (probe failed)"
else
  echo "OIDC wiring has issues for '$slug'"
fi
exit "$fail"
