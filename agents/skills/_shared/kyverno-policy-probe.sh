#!/usr/bin/env bash
# Prove a Kyverno ValidatingPolicy change admits what it should and denies what it should,
# BEFORE and AFTER shipping it. Read-only: every probe is `kubectl create --dry-run=server`.
#
# WHY: B6-2 (2026-07-26) narrowed disallow-host-path from 5 whole-namespace excludes to 9
# label-keyed workload identities — a Deny policy where a wrong selector denies a backup Job
# at 03:00 with nobody watching. The plan called for an Audit soak spanning a full backup
# cycle; these probes replaced it with a deterministic before/after check that also covers
# CronJobs, whose pods do not exist between runs and so are invisible to any live pod scan.
#
# Three traps this encodes, each of which produced a wrong answer first:
#
#  1. A SYNTHETIC probe pod is useless. All 12 VPs are Deny-enforcing and the webhook names
#     only the FIRST failing policy, so a hand-written pod is rejected for missing resource
#     limits and tells you nothing about the policy under test. Build the probe from a REAL
#     running pod, which already satisfies the other 11.
#  2. Overriding a LABEL on a workload that mounts the thing under test also breaks the
#     label-keyed exemptions OTHER policies grant it (node-exporter's hostNetwork/hostPID/
#     hostPort, alloy's privilege escalation). For the deny direction, inject the violating
#     field into an INNOCENT pod instead — that is what `inject` mode does.
#  3. PSA runs BEFORE Kyverno. In a `restricted`/`baseline` namespace PodSecurity rejects the
#     probe and Kyverno never sees it, so "denied" proves nothing. This script distinguishes
#     a Kyverno denial (message match) from any other rejection and reports SETUP-FAIL.
#
# Do NOT hand-reproduce autogen rules to test controllers offline. Autogen rewrites
# `object.metadata` to the pod-template path in matchConditions AND validations
# (`object.spec.template.metadata...`, `object.spec.jobTemplate.spec.template.metadata...`);
# only `request.namespace` is left alone. A yq-built clone that rewrites just the validation
# tests your model of the generator, not the generator — it "proved" a false conclusion on
# 2026-07-26. Read the real thing:  kubectl get vpol <name> -o json | jq .status.autogen
#
# Usage:
#   kyverno-policy-probe.sh clone  <ns> <kind/name> <labels-json|-> <allow|deny> <deny-message>
#       Rebuild a pod from a real workload's template (kind = deploy/daemonset/statefulset/
#       cronjob/pod). '-' keeps its real labels; a JSON object replaces them.
#   kyverno-policy-probe.sh inject <ns> <pod> <patch-json> <allow|deny> <deny-message>
#       Copy an innocent RUNNING pod and merge patch-json into .spec, e.g.
#       '{"volumes":[{"name":"p","hostPath":{"path":"/tmp","type":"Directory"}}]}'
#
# <deny-message> is a substring of the policy's own message ("hostPath volumes are not
# allowed"). It is what separates "denied by the policy under test" from "denied by something
# else", so it is required, not optional. A denial must ALSO name an admission webhook, or the
# run is a SETUP-FAIL — a schema error, quota rejection or PSA denial exits non-zero too and
# none of them tested the policy.
#
# ALWAYS RUN THE PAIR. An `allow` on its own cannot tell "correctly exempted" from "the policy
# never evaluated this object at all"; only a matching `deny` control proves the policy is live
# on that path. Same reason a Kyverno CLI `skip` is not evidence.
#
# Exit: 0 = matched expectation; 1 = mismatch; 2 = probe invalid (SETUP-FAIL).
# Read-only — uses `kubectl create --dry-run=server`, nothing is persisted. Needs: kubectl, jq.

set -uo pipefail

usage() {
  sed -n '2,51p' "$0" >&2
  exit 2
}
[ $# -ge 5 ] || usage

MODE="$1"
NS="$2"
SRC="$3"
ARG="$4"
EXPECT="$5"
MSG="${6:-}"
[ -n "$MSG" ] || {
  echo "missing <deny-message> — without it a denial cannot be attributed" >&2
  exit 2
}
case "$EXPECT" in allow | deny) ;; *)
  echo "expect must be allow|deny" >&2
  exit 2
  ;;
esac

case "$MODE" in
clone)
  case "${SRC%%/*}" in
  cronjob) TPL='.spec.jobTemplate.spec.template' ;;
  pod) TPL='.' ;;
  *) TPL='.spec.template' ;;
  esac
  RAW=$(kubectl get "$SRC" -n "$NS" -o json 2>/dev/null) || RAW=""
  [ -n "$RAW" ] || {
    echo "SETUP-FAIL  $NS  $SRC  (not found)"
    exit 2
  }
  POD=$(printf '%s' "$RAW" | jq --arg ns "$NS" \
    --argjson lbl "$([ "$ARG" = "-" ] && echo null || echo "$ARG")" "
        ${TPL} as \$t |
        { apiVersion:\"v1\", kind:\"Pod\",
          metadata:{ name:\"PROBE_NAME\", namespace:\$ns,
                     labels:(if \$lbl == null then (\$t.metadata.labels // {}) else \$lbl end) },
          spec:(\$t.spec + {restartPolicy:\"Never\"}) }")
  ;;
inject)
  RAW=$(kubectl get pod "$SRC" -n "$NS" -o json 2>/dev/null) || RAW=""
  [ -n "$RAW" ] || {
    echo "SETUP-FAIL  $NS/$SRC  (no such pod)"
    exit 2
  }
  # Arrays are CONCATENATED and objects merged RECURSIVELY. jq's `*` replaces arrays, which
  # silently drops the pod's own volumes and leaves every volumeMount dangling — the API server
  # then rejects the probe for an unrelated reason and the run reports SETUP-FAIL instead of
  # testing anything. A shallow merge has the same effect one level down.
  POD=$(printf '%s' "$RAW" | jq --argjson patch "$ARG" '
      def deepmerge($a; $b):
        if ($a | type) == "object" and ($b | type) == "object" then
          reduce ($b | keys_unsorted[]) as $k
            ($a; .[$k] = (if ($a | has($k)) then deepmerge($a[$k]; $b[$k]) else $b[$k] end))
        elif ($a | type) == "array" and ($b | type) == "array" then $a + $b
        else $b end;
      { apiVersion:"v1", kind:"Pod",
        metadata:{name:"PROBE_NAME", namespace:.metadata.namespace, labels:.metadata.labels},
        spec:(deepmerge(.spec; $patch) + {restartPolicy:"Never"})}')
  ;;
*) usage ;;
esac

[ -n "$POD" ] && [ "$POD" != "null" ] || {
  echo "SETUP-FAIL  $NS  $SRC  (could not build probe)"
  exit 2
}

# Unique name, and `create` not `apply`: a fixed name that already exists turns the request
# into an UPDATE, which silently skips any CREATE-only rule and can fail on immutable fields.
PROBE="kyverno-probe-$$"
POD=${POD//PROBE_NAME/$PROBE}

if OUT=$(printf '%s' "$POD" | kubectl create --dry-run=server -f - 2>&1); then GOT=allow; else GOT=deny; fi

# Neither verdict is trusted on exit status alone — that is the false-clean this script exists
# to prevent, and it cuts both ways:
#   allow  — must carry the server's dry-run success marker. A kubectl that failed to reach the
#            cluster, or printed nothing, is not evidence the policy evaluated and permitted.
#   deny   — must name an admission webhook AND carry the policy's own message. A schema error,
#            a quota rejection, PSA, or another Deny policy all exit non-zero too, and none of
#            them tested the policy under test.
if [ "$GOT" = allow ]; then
  if ! printf '%s' "$OUT" | grep -qE '\(server dry run\)'; then
    echo "SETUP-FAIL  $NS  $SRC  (no dry-run confirmation — request may never have been admitted)"
    printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-240
    echo
    exit 2
  fi
else
  if ! printf '%s' "$OUT" | grep -q 'admission webhook' || ! printf '%s' "$OUT" | grep -qF "$MSG"; then
    echo "SETUP-FAIL  $NS  $SRC  (rejected, but not by the policy under test)"
    printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-240
    echo
    exit 2
  fi
fi

if [ "$GOT" = "$EXPECT" ]; then
  # An `allow` is only meaningful next to a `deny` control on the same policy — on its own it
  # cannot distinguish "exempted" from "policy not evaluating at all". Always run the pair.
  echo "PASS  expect=$EXPECT got=$GOT  $NS  $SRC"
  exit 0
fi
echo "FAIL  expect=$EXPECT got=$GOT  $NS  $SRC"
printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-240
echo
exit 1
