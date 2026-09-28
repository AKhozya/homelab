#!/usr/bin/env bash
# Parse check for pin.sh's primary index, on orchestrator-client topology output captured live
# on 2026-09-28 (primary main-mysql-mysql-1). Run: bash pin-parse.test.sh
set -euo pipefail
PIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pin.sh"
topology='main-mysql-mysql-1.main-mysql-mysql.databases:3306 (main-mysql-mysql-1)   [0s,ok,8.4.11-11,rw,ROW,>>,GTID]
+ main-mysql-mysql-0.main-mysql-mysql.databases:3306 (main-mysql-mysql-0) [0s,ok,8.4.11-11,ro,ROW,>>,GTID]'
got="$(PIN_PARSE_ONLY=1 bash "$PIN" percona databases/main-mysql unused <<<"$topology")"
if [ "$got" = 1 ]; then
  echo "PASS: primary index 1"
else
  echo "FAIL: expected 1, got '$got'" >&2
  exit 1
fi
