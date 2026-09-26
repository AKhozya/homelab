#!/usr/bin/env bash
# security-scan.sh — Monthly lynis + rkhunter scan.
# Runs as root via systemd timer (node-maintenance-security-scan.timer).
# Writes a compact month-indexed summary to /var/log/node-maintenance/;
# full per-tool logs live at /var/log/{lynis.log,lynis-report.dat,rkhunter.log}
# (rotated by logrotate/security-tools, 6 months retention).
set -uo pipefail

LOG_DIR=/var/log/node-maintenance
install -d -m 0750 -o root -g adm "$LOG_DIR"

MONTH=$(date -u +%Y-%m)
SUMMARY="$LOG_DIR/security-scan-${MONTH}.log"
HOST=$(hostname)
START_TS=$(date -u +'%Y-%m-%d %H:%M:%S %Z')

RKHUNTER_TMP=$(mktemp -t rkhunter-scan.XXXXXX)
trap 'rm -f "$RKHUNTER_TMP"' EXIT

# Missing scan tool = hard failure (unit's ExecStopPost notifies). Tool WARNING exits
# stay benign (deliberate || true on invocations — lynis/rkhunter exit nonzero on
# normal monthly warnings).
FAIL=0

{
  echo "====================================================="
  echo "Host:      $HOST"
  echo "Started:   $START_TS"
  echo "Month tag: $MONTH"
  echo "====================================================="
  echo
  echo "── LYNIS ──"
  if command -v lynis >/dev/null 2>&1; then
    lynis audit system --quick --quiet --no-colors >/dev/null 2>&1 || true

    echo "# Version:"
    lynis --version 2>/dev/null | head -1 || true
    echo

    REPORT=/var/log/lynis-report.dat
    if [ -r "$REPORT" ]; then
      echo "# Hardening index:"
      grep -E '^hardening_index=' "$REPORT" | tail -1 || echo "(n/a)"
      echo

      echo "# Warnings:"
      WARN_COUNT=$(grep -cE '^warning\[\]=' "$REPORT" || true)
      echo "count=$WARN_COUNT"
      grep -E '^warning\[\]=' "$REPORT" || true
      echo

      echo "# Suggestions:"
      SUG_COUNT=$(grep -cE '^suggestion\[\]=' "$REPORT" || true)
      echo "count=$SUG_COUNT"
      grep -E '^suggestion\[\]=' "$REPORT" || true
    else
      echo "(lynis report $REPORT not found after scan)"
    fi
  else
    echo "lynis not installed — FAIL"
    FAIL=1
  fi

  echo
  echo "── RKHUNTER ──"
  if command -v rkhunter >/dev/null 2>&1; then
    echo "# Version:"
    rkhunter --version 2>/dev/null | head -1 || true
    echo

    # Refresh data files (mirrors/md5sums). Ignore failure — offline mirrors must not block scan.
    rkhunter --update --quiet >/dev/null 2>&1 || true

    # --sk: skip keypress. --rwo: report warnings only (skip OK lines).
    # Filter "egrep: warning: egrep is obsolescent" noise — rkhunter still spawns egrep
    # internally and Arch's grep emits a deprecation banner per call. Harmless but drowns
    # out real warnings.
    rkhunter --check --sk --rwo --nocolors 2>&1 | grep -v '^egrep: warning: egrep is obsolescent' >"$RKHUNTER_TMP" || true
    echo "# Warnings:"
    if [ -s "$RKHUNTER_TMP" ]; then
      cat "$RKHUNTER_TMP"
    else
      echo "(none — clean scan)"
    fi
    echo

    if [ -r /var/log/rkhunter.log ]; then
      echo "# Summary from /var/log/rkhunter.log:"
      grep -E 'Suspect files|Possible rootkits|Info:.*Warnings found|checks\.\.\..*clean' /var/log/rkhunter.log \
        | tail -10 || echo "(no summary lines)"
    fi
  else
    echo "rkhunter not installed — FAIL"
    FAIL=1
  fi

  echo
  echo "====================================================="
  echo "Finished:  $(date -u +'%Y-%m-%d %H:%M:%S %Z')"
  echo "====================================================="
} >>"$SUMMARY" 2>&1

chown root:adm "$SUMMARY" 2>/dev/null || true
chmod 0640 "$SUMMARY" 2>/dev/null || true

exit "$FAIL"
