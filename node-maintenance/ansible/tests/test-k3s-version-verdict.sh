#!/usr/bin/env bash
# Offline check of tasks/k3s-version-verdict.yml against k3s-version-verdict-cases.yml.
# Needs only ansible-playbook; no inventory, no cluster.
# Run: bash node-maintenance/ansible/tests/test-k3s-version-verdict.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp)"
trap 'rm -f "$out"' EXIT

# If a template error stops the run before any FAIL line, the playbook's exit code still fails
# this test.
rc=0
ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False ANSIBLE_NOCOLOR=1 \
	ansible-playbook -i localhost, "$HERE/k3s-version-verdict-test.yml" >"$out" 2>&1 || rc=$?

pass="$(grep -c '"msg": "PASS: ' "$out" || true)"
fail="$(grep -c '"msg": "FAIL: ' "$out" || true)"
want="$(grep -c '^  - name: ' "$HERE/k3s-version-verdict-cases.yml")"

grep -o '"msg": "FAIL: [^"]*' "$out" | sed 's/^"msg": "//' || true
if [ "$rc" -ne 0 ]; then
	tail -n 30 "$out"
	echo "ansible-playbook exited $rc"
	exit 1
fi
echo "$pass passed, $fail failed, $want cases"
[ "$fail" -eq 0 ] && [ "$pass" -eq "$want" ]
