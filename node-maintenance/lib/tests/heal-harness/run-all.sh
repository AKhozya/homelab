#!/usr/bin/env bash
# Whole-script equivalence harness for the node scripts that use node-script-lib.sh.
#   run-all.sh record [NAME...]   run scenarios and save their outputs as fixtures
#   run-all.sh check  [NAME...]   run scenarios and diff each output against its fixture
# Both modes then list every call of a shared helper (write_state, emit_metric, ufw_chains_hash,
# state_write, textfile_write) that no scenario of that script executed.
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
	mkdir -p "$out" "$work/trace/$name"
	if ! docker run --rm --privileged --platform linux/amd64 \
		-v "$REPO:/repo:ro" -v "$HERE:/harness-src:ro" -v "$out:/out" -v "$work/trace/$name:/trace" \
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
# Call-site coverage: a helper call line counts as covered if any scenario of its script traced it.
scripts=()
for name in "$@"; do scripts+=("$(sed -n 's/^SCRIPT=//p' "$HERE/scenarios/$name.sh")"); done
mapfile -t scripts < <(printf '%s\n' "${scripts[@]}" | sort -u)
for s in "${scripts[@]}"; do
	base="${s##*/}"
	cat "$work"/trace/*/xtrace 2>/dev/null | sed -n "s/^+*${base}:\([0-9]*\): .*/\1/p" | sort -u >"$work/covered"
	{ grep -nE '(write_state|emit_metric|ufw_chains_hash|state_write|textfile_write)\b' "$REPO/$s" || true; } |
		{ grep -vE '^[0-9]+:[[:space:]]*(#|(write_state|emit_metric|ufw_chains_hash)\(\))' || true; } | cut -d: -f1 |
		while read -r line; do
			grep -qx "$line" "$work/covered" || echo "UNCOVERED $s:$line: $(sed -n "${line}p" "$REPO/$s" | sed 's/^[[:space:]]*//')"
		done
done | tee "$work/uncovered"
[ -s "$work/uncovered" ] && [ "$status" -eq 0 ] && status=1
exit "$status"
