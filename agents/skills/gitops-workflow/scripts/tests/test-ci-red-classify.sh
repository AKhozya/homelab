#!/usr/bin/env bash
# Tests for _shared/ci-red-classify.sh against real Validate runs captured from GitHub
# (fixtures/ci-red-classify/<scenario>/{runs,jobs}.json). A fake gh on PATH serves them.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${1:-$HERE/../../../_shared/ci-red-classify.sh}"
FIXTURES="$HERE/fixtures/ci-red-classify"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# `run list` prints runs.json. `run view --json jobs --jq <expr>` applies <expr> to {jobs: jobs.json}.
cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
"run list") cat "$FIX/runs.json" ;;
"run view")
  expr=.
  while [ "$#" -gt 0 ]; do
    [ "$1" = --jq ] && expr="$2"
    shift
  done
  jq -c '{jobs: .}' "$FIX/jobs.json" | jq "$expr"
  ;;
*) exit 1 ;;
esac
STUB
chmod +x "$T/bin/gh"

pass=0
fail=0
expect() { # scenario expected_exit expected_verdict_word
  local out rc=0 sha
  sha="$(jq -r '.[0].headSha' "$FIXTURES/$1/runs.json")"
  out="$(FIX="$FIXTURES/$1" PATH="$T/bin:$PATH" bash "$SUT" some-branch "$sha" 2>&1)" || rc=$?
  if [ "$rc" = "$2" ] && grep -q "$3" <<<"$out"; then
    pass=$((pass + 1))
    echo "PASS $1: exit $rc"
  else
    fail=$((fail + 1))
    echo "FAIL $1: exit $rc (want $2, $3): $out"
  fi
}

expect green 0 GREEN
expect content-red 10 CONTENT-RED
expect outage-cancelled 11 INFRA-RED
expect billing-fail-to-start 11 INFRA-RED
expect concurrency-cancelled 12 CANCELLED
# Composed from two real job records (see its README): a real failure beside cancelled jobs.
expect composed-real-failure-plus-cancelled 10 CONTENT-RED
# Composed (see its README): a job cancelled after running steps, beside never-started jobs.
expect composed-timeout-plus-cancelled 10 CONTENT-RED

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
