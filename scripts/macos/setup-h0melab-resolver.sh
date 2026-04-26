#!/usr/bin/env bash
# Configure macOS per-domain resolver so *.h0melab.work always resolves
# via LAN Blocky instances (W1 + W2), bypassing VPN-pushed public DNS.
#
# Symptom this fixes:
#   `dig grafana.h0melab.work` works (returns 192.168.1.129/126)
#   but browsers / `curl` / `getaddrinfo()` fail with NXDOMAIN.
#
# Root cause:
#   When a VPN client pushes a public DNS server (e.g. 1.1.1.1) as a
#   secondary nameserver, mDNSResponder load-balances queries across
#   resolvers. Internal-only domains (*.h0melab.work) get NXDOMAIN
#   from the public resolver, which mDNSResponder caches negatively.
#
# Fix:
#   /etc/resolver/h0melab.work tells macOS to send all *.h0melab.work
#   queries ONLY to LAN Blocky instances, regardless of VPN config.
#
# Usage:
#   ./setup-h0melab-resolver.sh        (auto-elevates with sudo)
#
# Idempotent: safe to re-run.

set -euo pipefail

DOMAIN="h0melab.work"
RESOLVER_FILE="/etc/resolver/${DOMAIN}"
DNS_PRIMARY="192.168.1.129"
DNS_SECONDARY="192.168.1.126"

if [[ $EUID -ne 0 ]]; then
  echo "Re-running with sudo..."
  exec sudo "$0" "$@"
fi

echo "==> Creating /etc/resolver directory"
mkdir -p /etc/resolver

echo "==> Writing ${RESOLVER_FILE}"
cat > "${RESOLVER_FILE}" <<EOF
nameserver ${DNS_PRIMARY}
nameserver ${DNS_SECONDARY}
EOF
chmod 0644 "${RESOLVER_FILE}"

echo "==> Restarting mDNSResponder"
if launchctl kickstart -k system/com.apple.mDNSResponder 2>/dev/null; then
  echo "    via launchctl kickstart"
elif PID=$(pgrep -x mDNSResponder | head -1) && [[ -n "${PID}" ]]; then
  kill -HUP "${PID}"
  echo "    via SIGHUP to PID ${PID}"
else
  echo "    WARNING: could not signal mDNSResponder; reboot may be needed"
fi

echo "==> Also signaling mDNSResponderHelper (if present)"
if HPID=$(pgrep -x mDNSResponderHelper | head -1) && [[ -n "${HPID}" ]]; then
  kill -HUP "${HPID}" 2>/dev/null && echo "    HUP sent to PID ${HPID}"
fi

echo "==> Flushing DNS cache"
dscacheutil -flushcache

echo
echo "==> Verifying resolution via libc (getaddrinfo)"
sleep 1
for HOST in grafana.${DOMAIN} home.${DOMAIN} authentik.${DOMAIN}; do
  printf "%-32s " "${HOST}"
  if RESULT=$(python3 -c "import socket; r=socket.getaddrinfo('${HOST}', 443, socket.AF_INET); print(','.join(sorted(set(x[4][0] for x in r))))" 2>/dev/null); then
    echo "OK -> ${RESULT}"
  else
    echo "FAIL"
  fi
done

echo
echo "Done. Hard-refresh your browser (Cmd+Shift+R) to bypass its own DNS cache."
