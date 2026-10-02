#!/usr/bin/env bash
# Whole-script equivalence harness for the node scripts that use node-script-lib.sh.
#   run-all.sh record [NAME...]   run scenarios and save their outputs as fixtures
#   run-all.sh check  [NAME...]   run scenarios and diff each output against its fixture
# NAME is a scenario file name without .sh; no NAME means every scenario.
# Each scenario runs in a fresh privileged archlinux container under the local Docker (Rancher
# Desktop). The output is the script's exit code, stdout, stderr, every .prom file, the state
# files the scenario names, a listing of files left behind, and the ordered log of stubbed calls.
# Exit: 0 all equal (check) or recorded; 1 a difference; 2 usage or Docker error.
set -euo pipefail

IMAGE="archlinux:base-20260927.0.600689"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
mode="${1:-}"
case "$mode" in record | check) shift ;; *)
	echo "usage: $0 record|check [NAME...]" >&2
	exit 2
	;;
esac
docker info >/dev/null 2>&1 || {
	echo "docker is not running (start Rancher Desktop)" >&2
	exit 2
}

if [ "$#" -eq 0 ]; then
	mapfile -t all < <(cd "$HERE/scenarios" && ls -- *.sh | sed 's/\.sh$//')
	set -- "${all[@]}"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
status=0
for name in "$@"; do
	out="$work/$name"
	mkdir -p "$out"
	if ! docker run --rm --privileged --platform linux/amd64 \
		-v "$REPO:/repo:ro" -v "$HERE:/harness-src:ro" -v "$out:/out" \
		"$IMAGE" bash /harness-src/in-container.sh "/harness-src/scenarios/$name.sh" </dev/null; then
		echo "ERROR $name: the container run failed" >&2
		status=2
		continue
	fi
	if [ "$mode" = record ]; then
		rm -rf "$HERE/fixtures/$name"
		mkdir -p "$HERE/fixtures"
		cp -R "$out" "$HERE/fixtures/$name"
		echo "RECORDED $name (rc=$(cat "$out/rc"))"
	elif diff -r "$HERE/fixtures/$name" "$out" >"$work/$name.diff"; then
		echo "SAME     $name"
	else
		echo "DIFFERS  $name"
		cat "$work/$name.diff"
		status=1
	fi
done
exit "$status"
