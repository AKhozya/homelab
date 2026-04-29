#!/bin/bash
# ufw-diag-snapshot.sh
# Capture iptables/ip6tables/nft/lsmod/dmesg state to a timestamped file.
# Invoked from firewall role rescue block on UFW task failure, AND can be
# run on-demand: `sudo /usr/local/sbin/ufw-diag-snapshot.sh [reason]`
#
# Output: /var/log/node-maintenance/ufw-diag-<UTC-iso>.txt
# Retention: keeps the 20 most recent snapshots; older are removed.
set -uo pipefail

REASON="${1:-manual}"
OUT_DIR=/var/log/node-maintenance
TS=$(date -u +"%Y%m%dT%H%M%SZ")
OUT="${OUT_DIR}/ufw-diag-${TS}.txt"

install -d -m 0750 -o root -g adm "$OUT_DIR" 2>/dev/null || true

{
  printf '=== ufw-diag-snapshot %s reason=%s host=%s ===\n' "$TS" "$REASON" "$(hostname)"
  printf '\n--- ufw status verbose ---\n'
  /usr/sbin/ufw status verbose 2>&1 || true
  printf '\n--- iptables-save -c ---\n'
  /usr/sbin/iptables-save -c 2>&1 | head -200 || true
  printf '\n--- ip6tables-save -c ---\n'
  /usr/sbin/ip6tables-save -c 2>&1 | head -200 || true
  printf '\n--- nft list ruleset (head) ---\n'
  /usr/sbin/nft list ruleset 2>&1 | head -200 || true
  printf '\n--- lsmod (netfilter) ---\n'
  lsmod 2>/dev/null | grep -E 'ip6?_tables|ip6?table|nf_|nft|x_tables|conntrack' || true
  printf '\n--- /run/xtables.lock ---\n'
  ls -la /run/xtables.lock 2>&1 || true
  fuser -v /run/xtables.lock 2>&1 || true
  printf '\n--- ss listening ---\n'
  ss -tlnp 2>/dev/null | head -30 || true
  printf '\n--- recent kernel netfilter messages ---\n'
  dmesg 2>/dev/null | grep -iE 'iptables|ip6tables|nf_|nft|conntrack|xtables' | tail -40 || true
  printf '\n--- last 20 lines journal ufw-heal ---\n'
  journalctl -t ufw-heal -t firewall-preflight -n 20 --no-pager 2>/dev/null || true
} > "$OUT" 2>&1

# Retain 20 most recent
ls -1t "${OUT_DIR}"/ufw-diag-*.txt 2>/dev/null | tail -n +21 | xargs -r rm -f --

logger -t ufw-diag-snapshot -- "captured ${OUT} reason=${REASON}"
echo "$OUT"
