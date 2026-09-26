#!/usr/bin/env bash
# Offline unit check for k3s-wait-ready.sh's per-phase deadline split. Sources the script as a
# library (K3S_WAIT_READY_LIB=1) so main() never runs — no root, no k3s, no sentinel written.
# Run: bash tests/test-wait-ready.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
K3S_WAIT_READY_LIB=1
export K3S_WAIT_READY_LIB
# shellcheck source=../files/k3s-wait-ready.sh
. "$HERE/../files/k3s-wait-ready.sh"

pass=0 fail=0
chk() { if [ "$2" = "$3" ]; then
	echo "PASS: $1"
	pass=$((pass + 1))
else
	echo "FAIL: $1 (want=$2 got=$3)"
	fail=$((fail + 1))
fi; }

now() { date +%s; }

# Budget fits inside the global window -> phase gets its full budget.
GLOBAL_DEADLINE=$(($(now) + 300))
chk "budget under global: gets own budget" 1 \
	"$(d=$(phase_deadline 90); awk -v d="$d" -v n="$(now)" 'BEGIN{print (d-n>=89 && d-n<=91)?1:0}')"

# Budget would overrun the global window -> clamped to the global deadline.
GLOBAL_DEADLINE=$(($(now) + 30))
chk "budget over global: clamped" "$GLOBAL_DEADLINE" "$(phase_deadline 120)"

# THE REGRESSION GUARD. An earlier phase burned the whole window; the next phase must still get
# its own budget capped at the global deadline, not a deadline that is already in the past.
# Before the split every phase shared one deadline, so the ufw settle wait took zero samples.
GLOBAL_DEADLINE=$(($(now) + 120))
chk "starved predecessor: settle still gets a window" 1 \
	"$(d=$(phase_deadline 120); awk -v d="$d" -v n="$(now)" 'BEGIN{print (d>n)?1:0}')"

# Global window already elapsed -> phase deadline is in the past, so its loop exits at once
# instead of extending the boot.
GLOBAL_DEADLINE=$(($(now) - 5))
chk "global elapsed: no extension" 1 \
	"$(d=$(phase_deadline 120); awk -v d="$d" -v n="$(now)" 'BEGIN{print (d<n)?1:0}')"

# Defaults must leave the settle phase a window even when both CP phases time out in full.
chk "default budgets fit the total" 1 \
	"$(awk -v a="$API_TIMEOUT_SEC" -v p="$PODS_TIMEOUT_SEC" -v s="$SETTLE_TIMEOUT_SEC" \
		-v t="$TIMEOUT_SEC" 'BEGIN{print (a+p+s<=t)?1:0}')"

# kube-router runs inside the k3s process on K3s, so a pod selector for it can only time out.
chk "phase-2 selectors" "k8s-app=kube-dns" "$(printf '%s\n' "${CRITICAL_POD_LABELS[@]}" | paste -sd, -)"

echo "---- $pass passed, $fail failed ----"
[ "$fail" -eq 0 ]
