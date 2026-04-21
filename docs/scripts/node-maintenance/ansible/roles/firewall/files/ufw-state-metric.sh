#!/bin/bash
# ufw-state-metric.sh
# Emits UFW health metrics for node-exporter textfile collector.
# Runs via ufw-state-metric.timer every 60s.

set -euo pipefail

OUTDIR="/var/lib/node_exporter/textfile"
OUTFILE="${OUTDIR}/ufw_state.prom"
TMPFILE="${OUTFILE}.tmp"
NODE="$(cat /etc/hostname)"

mkdir -p "$OUTDIR"

# Config enabled flag
if grep -q "^ENABLED=yes" /etc/ufw/ufw.conf 2>/dev/null; then
    ENABLED=1
else
    ENABLED=0
fi

# Systemd service active
if systemctl is-active --quiet ufw.service 2>/dev/null; then
    ACTIVE=1
else
    ACTIVE=0
fi

# Probe critical chains (v4 + v6). CHAINS=1 only if ALL present.
CHAINS=1
for chain in ufw-logging-deny ufw-user-input; do
    /usr/sbin/iptables -L "$chain" -n >/dev/null 2>&1 || CHAINS=0
done
for chain in ufw6-logging-deny ufw6-user-input; do
    /usr/sbin/ip6tables -L "$chain" -n >/dev/null 2>&1 || CHAINS=0
done

cat > "${TMPFILE}" <<EOF
# HELP ufw_enabled UFW enabled in /etc/ufw/ufw.conf (1=yes, 0=no)
# TYPE ufw_enabled gauge
ufw_enabled{node="${NODE}"} ${ENABLED}
# HELP ufw_service_active UFW systemd service is active (1=yes, 0=no)
# TYPE ufw_service_active gauge
ufw_service_active{node="${NODE}"} ${ACTIVE}
# HELP ufw_chains_healthy All probe-set UFW chains present in kernel (1=yes, 0=no)
# TYPE ufw_chains_healthy gauge
ufw_chains_healthy{node="${NODE}"} ${CHAINS}
EOF

mv "${TMPFILE}" "${OUTFILE}"
