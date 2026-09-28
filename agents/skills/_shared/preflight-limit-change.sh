#!/usr/bin/env bash
# Would raising a container's memory limit still be admitted? Answer before editing.
#
# Usage:
#   preflight-limit-change.sh <namespace> <deployment> <new-memory-limit> [container]
#
#   preflight-limit-change.sh claude-telegram claude-telegram 5Gi
#
# Exit 0 admitted | 1 blocked | 2 could not establish an answer.
#
# Why this exists: raising claude-telegram from 3Gi to 5Gi on 2026-08-02 exceeded a
# namespace ResourceQuota of 4Gi, so the API server refused to create the pod at all.
# The deployment used strategy: Recreate, which had already deleted the old pod — a
# blocked rollout became a 15-minute outage. Two facts make that easy to walk into:
# the quota counts the WHOLE pod, not the one container being edited; and raising the
# quota afterwards does not retry, because the failed ReplicaSet has backed off
# (kubectl rollout restart).
#
# Everything this script cannot establish is exit 2, never "admitted": a quota it was
# not allowed to list, a quantity outside the Kubernetes grammar, a container whose
# effective limit is unknown, a selector it cannot resolve to owned pods.

set -uo pipefail

NS="${1:-}"
DEPLOY="${2:-}"
NEW="${3:-}"
CONTAINER="${4:-}"

if [ -z "$NS" ] || [ -z "$DEPLOY" ] || [ -z "$NEW" ]; then
  sed -n '2,10p' "$0" >&2
  exit 2
fi

for bin in kubectl jq python3; do
  command -v "$bin" >/dev/null || {
    echo "$bin required" >&2
    exit 2
  }
done

ERRLOG="$(mktemp "${TMPDIR:-/tmp}/preflight.XXXXXX")" || exit 2
trap 'rm -f "$ERRLOG"' EXIT INT TERM

# stderr is kept off stdout: kubectl prints deprecation and auth warnings there while
# still returning valid JSON, and merging the two corrupts the document. An empty list
# and a refused list are also different answers — "no quota" admits, "cannot read the
# quota" must not.
fetch() {
  local out
  if ! out="$(kubectl -n "$NS" get "$@" -o json 2>"$ERRLOG")"; then
    echo "cannot read $1 in $NS: $(tail -1 "$ERRLOG")" >&2
    exit 2
  fi
  printf '%s' "$out"
}

D="$(fetch deploy "$DEPLOY")" || exit 2
LR="$(fetch limitrange)" || exit 2
Q="$(fetch resourcequota)" || exit 2
RS="$(fetch replicaset)" || exit 2

# Quota credit comes from pods that actually exist, not from the replica count: a
# deployment sitting at zero ready pods is charged nothing, so crediting it would
# overstate headroom.
SEL="$(jq -r '[(.spec.selector.matchLabels // {}) | to_entries[] | "\(.key)=\(.value)"] | join(",")' <<<"$D")"
if [ -n "$SEL" ]; then
  PODS="$(fetch pods -l "$SEL")" || exit 2
else
  PODS='{"items":[]}'
fi

if ! PAYLOAD="$(jq -n --argjson d "$D" --argjson lr "$LR" --argjson q "$Q" --argjson pods "$PODS" \
  --argjson rs "$RS" --arg container "$CONTAINER" --arg new "$NEW" --arg deploy "$DEPLOY" \
  '{deploy:$d, limitranges:$lr, quotas:$q, pods:$pods, replicasets:$rs, container:$container, new:$new, name:$deploy}')"; then
  echo "could not assemble the cluster state for analysis" >&2
  exit 2
fi

REPORT="$(printf '%s' "$PAYLOAD" | python3 -c '
import json, math, os, re, sys, traceback
from decimal import Decimal, InvalidOperation

# An unhandled exception exits 1 by default, and in this contract exit 1 means "proven
# blocked". Anything unexpected has to land on 2 instead.
def _fatal(exc_type, exc, tb):
    traceback.print_exception(exc_type, exc, tb, file=sys.stderr)
    print("VERDICT: unknown — refusing to report admitted")
    sys.stdout.flush()
    os._exit(2)
sys.excepthook = _fatal

OUT, PROBLEMS = [], []

def die(msg):
    print("ERROR: " + msg)
    print("VERDICT: unknown — refusing to report admitted")
    sys.exit(2)

# The Kubernetes quantity grammar, not a permissive superset. "1e3Gi" and "-1Gi" are
# both rejected by the API server, and a parser that accepts them reports admitted for
# a value that will never be created.
MULT = {"Ki": Decimal(2**10), "Mi": Decimal(2**20), "Gi": Decimal(2**30),
        "Ti": Decimal(2**40), "Pi": Decimal(2**50), "Ei": Decimal(2**60),
        "n": Decimal(1) / 10**9, "u": Decimal(1) / 10**6, "m": Decimal(1) / 1000,
        "k": Decimal(10**3), "M": Decimal(10**6), "G": Decimal(10**9),
        "T": Decimal(10**12), "P": Decimal(10**15), "E": Decimal(10**18)}
NUM = r"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)"
EXP_RE = re.compile(r"^(%s)[eE][+-]?[0-9]+$" % NUM)
SUF_RE = re.compile(r"^(%s)(Ki|Mi|Gi|Ti|Pi|Ei|n|u|m|k|M|G|T|P|E)?$" % NUM)

def quantity(value, what, nonneg=True):
    """Exact Decimal value of a Kubernetes quantity. Anything else is fatal.
    Not trimmed: "1Gi " is not a quantity the API server accepts, and quietly
    repairing it here would report admitted for a value that cannot be created."""
    s = str(value)
    try:
        if EXP_RE.match(s):
            v = Decimal(s)
        else:
            m = SUF_RE.match(s)
            if not m:
                die("%s is not a valid Kubernetes quantity (%s)" % (value, what))
            v = Decimal(m.group(1)) * MULT.get(m.group(2) or "", Decimal(1))
    except (InvalidOperation, ArithmeticError):
        die("cannot parse %s as a quantity (%s)" % (value, what))
    if nonneg and v < 0:
        die("%s is negative (%s)" % (value, what))
    return v

def qbytes(value, what):
    # Rounded up: overstating the pod is the safe direction.
    return int(math.ceil(quantity(value, what)))

def human(b):
    return "%.0fMi" % (b / 1048576.0)

IN = json.load(sys.stdin)
d = IN["deploy"]
spec = d["spec"]["template"]["spec"]
containers = spec.get("containers") or []
inits = spec.get("initContainers") or []
names = [c["name"] for c in containers]

target = IN["container"] or (IN["name"] if IN["name"] in names else names[0] if names else "")
if target not in names:
    die("no container named %r in deploy/%s (have: %s)" % (target, IN["name"], ", ".join(names)))
new_b = qbytes(IN["new"], "requested limit")

# --- LimitRange: defaults fill in a missing limit at admission time, so a container
# with none is not a zero. Every LimitRange applies, not just the first. ---
lritems = IN["limitranges"].get("items") or []
def lr_rules(kind):
    for lr in lritems:
        for item in lr["spec"].get("limits") or []:
            if item.get("type") == kind:
                yield lr["metadata"]["name"], item

# Highest default wins: overstating the pod is the safe error.
default_lim = default_req = None
for _, item in lr_rules("Container"):
    v = (item.get("default") or {}).get("memory")
    if v is not None:
        b = qbytes(v, "LimitRange default")
        default_lim = b if default_lim is None else max(default_lim, b)
    v = (item.get("defaultRequest") or {}).get("memory")
    if v is not None:
        b = qbytes(v, "LimitRange defaultRequest")
        default_req = b if default_req is None else max(default_req, b)

def effective(c, override_name=None, override_bytes=None, where=""):
    if override_name is not None and c["name"] == override_name:
        return override_bytes
    v = (c.get("resources", {}).get("limits") or {}).get("memory")
    if v is not None:
        return qbytes(v, "%s limit on %s" % (where, c["name"]))
    if default_lim is not None:
        return default_lim
    die("container %r has no memory limit and no LimitRange default supplies one; a "
        "limits.memory quota rejects such a pod outright" % c["name"])

def effective_req(c, override_name=None, override_bytes=None, where=""):
    """Memory request as the API server admits the pod. The API server copies a set limit into a
    missing request on the Pod, never on the template, so raising the limit of a
    request-less container raises its requests.memory charge too."""
    v = (c.get("resources", {}).get("requests") or {}).get("memory")
    if v is not None:
        return qbytes(v, "%s request on %s" % (where, c["name"]))
    if override_name is not None and c["name"] == override_name:
        return override_bytes
    v = (c.get("resources", {}).get("limits") or {}).get("memory")
    if v is not None:
        return qbytes(v, "%s limit on %s" % (where, c["name"]))
    if default_req is not None:
        return default_req
    if default_lim is not None:
        return default_lim
    die("container %r has no memory request and no LimitRange default supplies one; a "
        "requests.memory quota rejects such a pod outright" % c["name"])

def pod_total(cs, ins, override_name=None, override_bytes=None, where="", fn=None):
    """Effective pod limit (or request, with fn=effective_req), as the API server computes
    it for quota: the higher of the sum over all non-init containers — app AND restartable
    sidecars, which keep running after startup — and the highest single init container value."""
    fn = fn or effective
    def eff(c):
        return fn(c, override_name, override_bytes, where)
    sidecars = sum(eff(c) for c in ins if c.get("restartPolicy") == "Always")
    steady = sum(eff(c) for c in cs) + sidecars
    init_effective = max([eff(c) for c in ins] or [0])
    return max(steady, init_effective)

before = pod_total(containers, inits, where="current")
after = pod_total(containers, inits, target, new_b, where="proposed")

strategy = d["spec"].get("strategy", {}).get("type") or "RollingUpdate"
replicas = d["spec"].get("replicas")
replicas = 1 if replicas is None else int(replicas)

OUT.append("deploy/%s in %s" % (IN["name"], d["metadata"]["namespace"]))
OUT.append("  container      : %s" % target)
OUT.append("  strategy       : %s   replicas: %d" % (strategy, replicas))
OUT.append("  pod limit total: %s -> %s   (containers + sidecars, or the init peak)"
           % (human(before), human(after)))

for name, item in lr_rules("Container"):
    mx = (item.get("max") or {}).get("memory")
    if mx is not None and new_b > qbytes(mx, "LimitRange max"):
        PROBLEMS.append("LimitRange %s: container max is %s, asked for %s" % (name, mx, IN["new"]))
    mn = (item.get("min") or {}).get("memory")
    if mn is not None and new_b < qbytes(mn, "LimitRange min"):
        PROBLEMS.append("LimitRange %s: container min is %s, asked for %s" % (name, mn, IN["new"]))
    ratio = (item.get("maxLimitRequestRatio") or {}).get("memory")
    if ratio is not None:
        c = next(c for c in containers if c["name"] == target)
        req = (c.get("resources", {}).get("requests") or {}).get("memory")
        req_b = qbytes(req, "request on %s" % target) if req is not None else default_req
        if req_b:
            # A ratio is itself a quantity: "1500m" is a legal way to write 1.5.
            allowed = quantity(ratio, "maxLimitRequestRatio")
            actual = Decimal(new_b) / Decimal(req_b)
            if actual > allowed:
                PROBLEMS.append("LimitRange %s: maxLimitRequestRatio is %s, this would be %.2f"
                                % (name, ratio, actual))
for name, item in lr_rules("Pod"):
    mx = (item.get("max") or {}).get("memory")
    if mx is not None and after > qbytes(mx, "LimitRange pod max"):
        PROBLEMS.append("LimitRange %s: pod max is %s, pod would be %s" % (name, mx, human(after)))
OUT.append("  LimitRange     : %s" % ("ok" if not PROBLEMS else "BLOCKED"))

blocked = list(PROBLEMS)
QUOTA_KEYS = (("limits.memory", effective), ("requests.memory", effective_req))
quotas = [q for q in (IN["quotas"].get("items") or [])
          if any(k in (q.get("status", {}).get("hard") or {}) for k, _ in QUOTA_KEYS)]

if replicas == 0:
    # Nothing is created, so no quota can reject anything. The LimitRange findings
    # above still stand: they bite the moment this is scaled back up.
    OUT.append("  admission      : scaled to 0, no pod is created — quota not evaluated")
elif not quotas:
    OUT.append("  ResourceQuota  : none constrains limits.memory or requests.memory")
else:
    # Credit only pods this Deployment owns, resolved by UID through its ReplicaSets.
    # A name prefix is not ownership: deployment "app-canary" produces ReplicaSets
    # called "app-canary-<hash>", which a prefix test on "app" would happily credit.
    # A selector carrying matchExpressions is not reproduced by the matchLabels-only
    # pod fetch either, so those pods are not credited at all.
    partial = bool(d["spec"].get("selector", {}).get("matchExpressions"))
    dep_uid = d["metadata"].get("uid")
    rs_uids = {rs["metadata"]["uid"] for rs in (IN["replicasets"].get("items") or [])
               if dep_uid and any(o.get("kind") == "Deployment" and o.get("uid") == dep_uid
                                  for o in (rs["metadata"].get("ownerReferences") or []))}
    live = []
    if not partial:
        for p in IN["pods"].get("items") or []:
            # A quota stops charging a pod once it reaches a terminal phase, so a
            # leftover Failed pod is not headroom waiting to be freed.
            if p.get("status", {}).get("phase") in ("Succeeded", "Failed"):
                continue
            owners = p.get("metadata", {}).get("ownerReferences") or []
            if any(o.get("kind") == "ReplicaSet" and o.get("uid") in rs_uids for o in owners):
                live.append(p)
    credit = sum(pod_total(p["spec"].get("containers") or [],
                           p["spec"].get("initContainers") or [], where="live pod")
                 for p in live)
    if partial:
        OUT.append("  live pods      : selector uses matchExpressions, crediting nothing")
    else:
        OUT.append("  live pods      : %d owned by this deployment, charged %s"
                   % (len(live), human(credit)))

    surge_raw = (d["spec"].get("strategy", {}).get("rollingUpdate") or {}).get("maxSurge", "25%")
    if strategy == "Recreate":
        surge = 0
    elif isinstance(surge_raw, str) and surge_raw.endswith("%"):
        surge = int(math.ceil(replicas * int(surge_raw[:-1]) / 100.0))
    else:
        surge = int(surge_raw)

    # Two moments can exceed the quota and either one blocks the rollout. Settled: every
    # replica is the new size and the old ones are gone. Transition: new pods fill every
    # slot up to replicas+surge while the old ones are still charged — counted against
    # the pods that exist, not against the replica count, because a deployment short of
    # its replicas refills those slots at the same time as it surges.
    vacant = max(0, replicas + surge - len(live))

    def need_new(fn):
        # Compute only the keys some quota constrains. If a quota constrains requests.memory,
        # effective_req rejects a container with no request, no limit and no LimitRange default.
        after_k = pod_total(containers, inits, target, new_b, where="proposed", fn=fn)
        credit_k = sum(pod_total(p["spec"].get("containers") or [],
                                 p["spec"].get("initContainers") or [], where="live pod", fn=fn)
                       for p in live)
        return max(after_k * replicas - credit_k, after_k * vacant, 0)
    if surge == 0:
        basis = ("Recreate: old pods freed first" if strategy == "Recreate"
                 else "%s, maxSurge 0: old pods freed first" % strategy)
    else:
        basis = ("%s: peak of %d new pod(s) alongside %d still charged, or %d replacement(s) settled"
                 % (strategy, vacant, len(live), replicas))

    for q in quotas:
        for key, fn in QUOTA_KEYS:
            if key not in q["status"]["hard"]:
                continue
            hard = qbytes(q["status"]["hard"][key], "quota hard")
            used = qbytes((q["status"].get("used") or {}).get(key, "0"), "quota used")
            need = used + need_new(fn)
            OUT.append("  quota %-9s: %s used %s of %s, would need %s"
                       % (q["metadata"]["name"], key, human(used), q["status"]["hard"][key],
                          human(need)))
            if need > hard:
                blocked.append("quota %s: %s needs %s, hard limit is %s — raise it in the "
                               "same commit" % (q["metadata"]["name"], key, human(need),
                                                q["status"]["hard"][key]))
    OUT.append("  basis          : %s" % basis)

print("\n".join(OUT))
if blocked:
    print("VERDICT: BLOCKED")
    for b in blocked:
        print("  - " + b)
    if strategy == "Recreate" and replicas:
        print("  strategy is Recreate: applying this anyway takes the app DOWN, it does not "
              "merely stall the rollout")
    sys.exit(1)
print("VERDICT: admitted")
sys.exit(0)
')"
rc=$?
printf '%s\n' "$REPORT"

# The verdict line, not the exit code, decides. A python that dies before it can install
# its own exception hook — a broken sitecustomize, a missing interpreter — exits 1, and
# exit 1 here means "proven blocked". No verdict printed is always exit 2.
case "$REPORT" in
*"VERDICT: admitted"*) exit 0 ;;
*"VERDICT: BLOCKED"*) exit 1 ;;
*)
  [ "$rc" = 2 ] || echo "analysis produced no verdict (exit $rc)" >&2
  exit 2
  ;;
esac
