#!/usr/bin/env bash
# cluster-roll.sh — ordered, tier-by-tier pod-recycle orchestrator for the 4-node K3s cluster.
#
# Use instead of "kubectl rollout restart -A", which caused the 2026-05-24 cascade.
# Recycles workloads in dependency order (DNS → operators → platform → DNS-cache clients → apps),
# gating each tier on `rollout status` + a ClusterIP health re-probe on all 4 nodes.
#
# NO sudo. kubectl-only (+ SSH for the read-only ClusterIP probe). GitOps-safe: only `rollout restart`
# and (Flux-stale fallback) `kubectl delete pod` — never edit/patch/replace of git-managed specs.
#
# Flags (tier by NAME, not index):
#   --dry-run              print the full ordered plan (every workload → tier or SKIP), run NOTHING.
#   --tier <name>          roll only one tier (dns|operators|platform|dnscache|apps).
#   --from-tier <name>     roll from this tier through apps (tier 5).
#   --user-facing          roll just the app tier (alias for `--tier apps`) — the user-facing fleet.
#                          NOTE tier 5 also carries 2 non-UI backends (immich-machine-learning,
#                          claude-telegram); authentik (tier 3) + grafana (tier 4)
#                          are user-facing but roll with their dep-ordered tiers, NOT here.
#   (no args)              full roll tiers 1→5 after preflight.
#
# Exit: 0 ok / 1 preflight or roll failure / 2 bad args.
set -euo pipefail
# declare -n (namerefs) needs bash >=4.3 — /bin/bash on macOS is 3.2; run via `bash` (brew).
[ "${BASH_VERSINFO[0]}" -ge 4 ] || {
  echo "ABORT: needs bash >=4 (namerefs); invoke as 'bash cluster-roll.sh', not /bin/bash" >&2
  exit 2
}

# Resolve sibling helper scripts relative to THIS script's location, NOT a hardcoded path: $HOME
# differs between the Mac and the claude-telegram container, so an absolute /Users path fails the
# [ -x ] preflight in the container.
SKILLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" # scripts → cluster-roll → skills
VERIFY_CLUSTERIP="$SKILLS_DIR/cluster-reboot/scripts/verify-clusterip.sh"
POD_HEALTH="$SKILLS_DIR/_shared/pod-health.sh"
# immich-vm included since 2026-07-16: tier 5 rolls immich-server, which is pinned to it —
# a wedged immich-vm kube-proxy would otherwise go unprobed.
NODES=(gmk-k3s-control-plane worker-node worker-node-2 immich-vm)
SETTLE_SECS=20
ROLLOUT_TIMEOUT=180s

# ── Tier map (built against the LIVE cluster 2026-05-25; every deploy/sts/ds has a home) ─────────
# Format per entry: "<namespace>:<kind>/<name>". kind ∈ deploy|sts|ds.
# Within a tier, entries roll in listed order (matters for tier 2 flux-last + tier 3 serial chain).

# Tier arrays are referenced indirectly via `declare -n` (tier_array_name) — shellcheck can't
# trace nameref access, so the SC2034 "appears unused" warnings on them are false positives.
# shellcheck disable=SC2034

# Tier 1 — DNS. Roll coredns-ha IN PLACE. Flux-managed DaemonSet (1 pod/node) since 2026-06-05;
# the k3s addon `deploy/coredns` is GONE (--disable=coredns, 2026-06-04). NEVER scale.
TIER_DNS=(
  "kube-system:ds/coredns-ha"
)

# Tier 2 — Operators / edge infra controllers. No data pods. Flux controllers roll LAST (self-disrupt).
# shellcheck disable=SC2034
TIER_OPERATORS=(
  "databases:deploy/cnpg-operator-cloudnative-pg"
  "databases:deploy/redis-operator"
  "percona-mysql:deploy/ps-operator"
  "kube-system:deploy/metrics-server"
  "kube-system:deploy/local-path-provisioner"
  "kyverno:deploy/kyverno-background-controller"
  "kyverno:deploy/kyverno-cleanup-controller"
  "kyverno:deploy/kyverno-reports-controller"
  "monitoring:deploy/victoria-metrics-operator"
  "monitoring:deploy/kube-prometheus-stack-operator"
  "flux-system:deploy/source-controller"
  "flux-system:deploy/kustomize-controller"
  "flux-system:deploy/helm-controller"
  "flux-system:deploy/notification-controller"
)

# Tier 3 — Platform / edge. ORDERED serial chain; PDBs allow=1 so slower.
# cert-manager → traefik → cloudflared → kyverno admission → authentik (svr+wkr) → blocky.
# Authentik depends on the PG pooler (tier 4) + DNS (tier 1): kept after DNS, before its pooler reroll.
# shellcheck disable=SC2034
TIER_PLATFORM=(
  "cert-manager:deploy/cert-manager"
  "cert-manager:deploy/cert-manager-cainjector"
  "cert-manager:deploy/cert-manager-webhook"
  "traefik:deploy/traefik"
  "cloudflare-tunnel:deploy/cloudflared"
  "kyverno:deploy/kyverno-admission-controller"
  "authentik:deploy/authentik-server"
  "authentik:deploy/authentik-worker"
  "blocky:deploy/blocky"
)

# Tier 4 — DNS-cache clients. Reroll AFTER DNS confirmed healthy to clear Go-resolver / PgBouncer
# cached DNS failures. The PG pooler (PgBouncer) belongs ONLY here.
# shellcheck disable=SC2034
TIER_DNSCACHE=(
  "databases:deploy/main-postgres-rw-pooler"
  "databases:deploy/mysql-exporter"
  "databases:deploy/mysql-replica-exporter"
  "monitoring:deploy/vmagent-vmagent"
  "monitoring:deploy/vmalert-vmalert"
  "monitoring:deploy/vmsingle-vmsingle"
  "monitoring:deploy/kube-prometheus-stack-grafana"
  "monitoring:deploy/kube-prometheus-stack-kube-state-metrics"
  "monitoring:sts/alertmanager-kube-prometheus-stack-alertmanager"
  "loki:deploy/loki-gateway"
  "loki:ds/alloy"
  "loki:ds/loki-canary"
)

# Tier 5 — Apps. Stateless app deployments (explicit list).
# shellcheck disable=SC2034
TIER_APPS=(
  "immich:deploy/immich-server"
  "immich:deploy/immich-machine-learning"
  "paperless-ngx:deploy/paperless-ngx"
  "n8n:deploy/n8n"
  "mealie:deploy/mealie"
  "homepage:deploy/homepage"
  "homehub:deploy/homehub"
  "audiobookshelf:deploy/audiobookshelf"
  "uptime-kuma:deploy/uptime-kuma"
  "pricebuddy:deploy/pricebuddy"
  "stirling-pdf:deploy/stirling-pdf"
  "linkwarden:deploy/linkwarden"
  "claude-telegram:deploy/claude-telegram"
  "home-assistant:deploy/home-assistant"
  "rustdesk:deploy/rustdesk"
  "rustdesk:deploy/warp-beacon"
)

# SKIP — never blanket-roll. Data-bearing STS recycle via operator/CRD; DaemonSets are node infra.
# Format: "<namespace>:<kind>/<name>  # why".
SKIP=(
  "databases:sts/main-mysql-mysql            # Percona MySQL data (percona-operator); recycle via PerconaServerMySQL CR"
  "databases:sts/main-mysql-haproxy          # Percona MySQL router (percona-operator); recycle via CR"
  "databases:sts/main-mysql-orc              # Percona MySQL orchestrator (percona-operator); recycle via CR"
  "databases:sts/redis-replication           # Redis data (redis-operator); restart one pod at a time via _shared/redis-restart.sh"
  "databases:sts/redis-sentinel-sentinel     # Redis sentinel (redis-operator); sentinel PDB min=2; _shared/redis-restart.sh"
  "databases:sts/couchdb-couchdb             # CouchDB (Helm, 2 replicas); recycle via Helm/rollout w/ quorum care"
  "linkwarden:sts/meilisearch                # Meilisearch (single replica, no PDB); recycle by hand if needed"
  "loki:sts/loki                             # Loki (Helm STS); recycle via Helm/rollout w/ care"
  "kube-system:ds/svclb-traefik-7834697c     # k3s svclb DaemonSet (node infra); managed by k3s"
  "kube-system:ds/svclb-blocky-dns-440d309d  # k3s svclb DaemonSet (node infra); managed by k3s"
  "kube-system:ds/svclb-rustdesk-710ac486    # k3s svclb DaemonSet (node infra); managed by k3s"
  "kube-system:ds/svclb-warp-beacon-4e398a2a # k3s svclb DaemonSet (node infra); managed by k3s"
  "kube-system:ds/intel-gpu-plugin           # GPU device plugin DaemonSet (node infra)"
  "monitoring:ds/kube-prometheus-stack-prometheus-node-exporter  # node-exporter DaemonSet (node infra)"
)

# ── Helpers ──────────────────────────────────────────────────────────────────────────────────────
die() {
  echo "ABORT: $*" >&2
  exit 1
}

tier_array_name() {
  case "$1" in
  dns) echo TIER_DNS ;;
  operators) echo TIER_OPERATORS ;;
  platform) echo TIER_PLATFORM ;;
  dnscache) echo TIER_DNSCACHE ;;
  apps) echo TIER_APPS ;;
  *) return 1 ;;
  esac
}

# Probe all 4 nodes; ABORT naming any wedged/unreachable WORKER. The CP host-netns 10.43.0.1
# probe is unreliable (reads wedged while healthy — same quirk watch-reboot.sh gates around),
# so the CP verdict is ADVISORY; the CP's hard gates are its loopback LB (127.0.0.1:6443) and
# kube-dns ready endpoints. A false CP abort here would strand a half-rolled fleet.
verify_all_nodes() {
  local phase="$1" node rc cp_lb dns_ready
  echo "── ClusterIP probe (all nodes) [$phase] ──"
  for node in "${NODES[@]}"; do
    rc=0
    "$VERIFY_CLUSTERIP" "$node" || rc=$?
    if [ "$rc" -ne 0 ] && [ "$node" = "gmk-k3s-control-plane" ]; then
      echo "  (CP clusterip advisory — host-netns quirk; hard-gating CP via loopback LB + kube-dns below)"
      continue
    fi
    [ "$rc" -eq 0 ] || die "node '$node' not healthy (verify-clusterip rc=$rc) during [$phase] — stopping roll."
  done
  cp_lb="$(ssh -o ConnectTimeout=5 gmk-k3s-control-plane \
    'curl -sS -m5 -k -o /dev/null -w "%{http_code}" https://127.0.0.1:6443/healthz 2>/dev/null || echo 000' 2>/dev/null || echo 000)"
  case "$cp_lb" in 200 | 401) ;; *) die "CP loopback LB unhealthy (127.0.0.1:6443 → $cp_lb) during [$phase] — stopping roll." ;; esac
  dns_ready="$(kubectl get endpoints kube-dns -n kube-system \
    -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' ')"
  [ "${dns_ready:-0}" -ge 1 ] || die "kube-dns has 0 ready endpoints during [$phase] — stopping roll."
}

# Build a label selector "k1=v1,k2=v2" from a workload's spec.selector.matchLabels.
workload_selector() {
  local ns="$1" kind="$2" name="$3"
  kubectl -n "$ns" get "$kind" "$name" -o json 2>/dev/null |
    jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")'
}

# Roll one workload: rollout restart → rollout status → Flux-stale detection → delete-pod fallback.
roll_one() {
  local entry="$1" ns kind name target sel before_uids before_map after_json after_uids surviving_uids stale_names
  ns="${entry%%:*}"
  target="${entry#*:}" # e.g. deploy/coredns
  kind="${target%%/*}"
  name="${target#*/}"

  echo "  → rolling $ns/$target"
  sel="$(workload_selector "$ns" "$kind" "$name")"
  [ -n "$sel" ] || die "could not resolve selector for $ns/$target"
  # Capture the pre-roll pods as both a sorted UID set (for the set-intersection test) and a
  # uid<TAB>name map (pods don't support a metadata.uid field-selector, so we delete survivors
  # by name).
  before_map="$(kubectl -n "$ns" get pods --selector="$sel" \
    -o jsonpath='{range .items[*]}{.metadata.uid}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  before_uids="$(printf '%s\n' "$before_map" | awk 'NF{print $1}' | sort || true)"

  if ! kubectl -n "$ns" rollout restart "$target"; then
    die "rollout restart failed for $ns/$target"
  fi
  if ! kubectl -n "$ns" rollout status "$target" --timeout="$ROLLOUT_TIMEOUT"; then
    die "rollout status failed for $ns/$target (timeout=$ROLLOUT_TIMEOUT)"
  fi

  # Flux-stale detection — Deployment-ONLY. On Flux-managed Deployments, drift-detection can revert
  # the restartedAt annotation, abandon the new RS, and leave STALE pod(s) alive while `rollout
  # status` still reports success. With ≥2 replicas under a PDB the revert can land mid-roll, so
  # only SOME pods cycle and the rest stay stale. So check whether ANY old pod UID remains in
  # the after-set. If any remains, delete just those pods by name: Flux owns the Deployment, not
  # the pods, so the RS recreates them and Flux does not revert those pod deletions.
  #
  # Deployment-only because DaemonSets and StatefulSets have no ReplicaSet and roll differently;
  # a false "did not cycle" on a DaemonSet would delete pods on ALL nodes at once (a fleet-wide
  # gap, e.g. alloy log shipping). For those kinds, trust `rollout status` alone.
  if [ "$kind" = "deploy" ] && [ -n "$before_uids" ]; then
    # Exclude Terminating pods (deletionTimestamp set): after a successful roll the old
    # pods can linger in their grace period and would read as false "survivors".
    # Fail LOUD on fetch/parse failure — an empty after-set would silently read as
    # "all cycled" and skip the stale-pod check entirely.
    after_json="$(kubectl -n "$ns" get pods --selector="$sel" -o json 2>/dev/null)" ||
      die "could not list pods to verify cycle for $ns/$target"
    [ -n "$after_json" ] || die "empty pod list JSON for $ns/$target (cannot verify cycle)"
    after_uids="$(printf '%s' "$after_json" |
      jq -r '.items[] | select(.metadata.deletionTimestamp == null) | .metadata.uid' | sort)" ||
      die "could not parse pod list for $ns/$target"
    # Surviving old pods = intersection of before-UIDs and after-UIDs.
    surviving_uids="$(comm -12 <(printf '%s\n' "$before_uids") <(printf '%s\n' "$after_uids") | awk 'NF')"
    if [ -n "$surviving_uids" ]; then
      # Map surviving UIDs back to pod names via the pre-roll uid<TAB>name map. Two-file awk
      # (UIDs first, then the map) keeps this portable to BSD awk (macOS) — a multi-line -v var
      # is rejected there.
      stale_names="$(awk 'FNR==NR{if($1!="")keep[$1]=1;next} NF && ($1 in keep){print $2}' \
        <(printf '%s\n' "$surviving_uids") <(printf '%s\n' "$before_map"))"
      echo "    ! $(printf '%s\n' "$stale_names" | awk 'NF' | wc -l | tr -d ' ') stale pod(s) survived (Flux likely reverted restartedAt) — delete-pod fallback"
      # Delete only the survivors (old pods that never cycled), not the freshly-rolled ones.
      # `|| true` on the delete: a survivor may vanish between listing and delete (benign race);
      # the post-check below is what guarantees the fallback actually worked.
      printf '%s\n' "$stale_names" | while IFS= read -r pod; do
        [ -n "$pod" ] || continue
        kubectl -n "$ns" delete pod "$pod" --wait=false 2>/dev/null || true
      done
      if ! kubectl -n "$ns" rollout status "$target" --timeout="$ROLLOUT_TIMEOUT"; then
        die "rollout status failed for $ns/$target after delete-pod fallback"
      fi
      # Post-check: rollout status succeeds trivially on an already-stable (Flux-reverted)
      # deployment, so re-run the UID intersection and exit with an error if any old pod STILL
      # survives. Same Terminating exclusion, and the same error exit if fetching or parsing fails.
      after_json="$(kubectl -n "$ns" get pods --selector="$sel" -o json 2>/dev/null)" ||
        die "could not list pods to verify delete-pod fallback for $ns/$target"
      [ -n "$after_json" ] || die "empty pod list JSON after fallback for $ns/$target"
      after_uids="$(printf '%s' "$after_json" |
        jq -r '.items[] | select(.metadata.deletionTimestamp == null) | .metadata.uid' | sort)" ||
        die "could not parse pod list after fallback for $ns/$target"
      surviving_uids="$(comm -12 <(printf '%s\n' "$before_uids") <(printf '%s\n' "$after_uids") | awk 'NF')"
      [ -z "$surviving_uids" ] || die "stale pod(s) STILL alive after delete-pod fallback for $ns/$target — manual intervention needed"
    fi
  fi
}

roll_tier() {
  local tname="$1" arr_name entries entry
  arr_name="$(tier_array_name "$tname")" || die "unknown tier '$tname'"
  # shellcheck disable=SC1087  # not array expansion — building a nameref
  declare -n entries="$arr_name"
  echo "════ TIER: $tname (${#entries[@]} workloads) ════"
  for entry in "${entries[@]}"; do
    roll_one "$entry"
  done
  echo "  ⏳ settle ${SETTLE_SECS}s …"
  sleep "$SETTLE_SECS"
  verify_all_nodes "post-tier:$tname"
  echo "════ TIER $tname: rolled OK ════"
  echo
}

# ── Preflight (abort-on-fail) ──────────────────────────────────────────────────────────────────
preflight() {
  echo "── Preflight ──"
  local replicas desired
  replicas="$(kubectl -n kube-system get ds coredns-ha -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
  desired="$(kubectl -n kube-system get ds coredns-ha -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)"
  # Gate on ready == desired (not a fixed >=2): at 2/3 the roll would land pods on the node
  # whose local DNS pod is dead.
  if [ -z "$replicas" ] || [ "${desired:-0}" -lt 1 ] || [ "$replicas" != "$desired" ]; then
    die "coredns-ha DaemonSet ready=$replicas desired=$desired (must match). Fix cluster DNS first, then re-run."
  fi
  echo "  coredns-ha DaemonSet ready=$replicas/$desired (OK)"
  verify_all_nodes "preflight"
  check_orphans || die "workload map incomplete; add each orphan to a tier or SKIP, then re-run."
  echo "  Baseline unready pods (warn-only):"
  "$POD_HEALTH" --count | sed 's/^/    /' || true
  echo "── Preflight OK ──"
  echo
}

# ── Dry-run: print the full ordered plan + cross-check ZERO orphans ─────────────────────────────
dry_run() {
  local arr_name entry tname
  echo "###############  CLUSTER-ROLL DRY-RUN (plan only — nothing executed)  ###############"
  echo
  for tname in "${ALL_TIERS[@]}"; do
    arr_name="$(tier_array_name "$tname")"
    # shellcheck disable=SC1087
    declare -n entries="$arr_name"
    echo "════ TIER: $tname (${#entries[@]} workloads) ════"
    for entry in "${entries[@]}"; do
      echo "    $entry"
    done
    echo
  done
  echo "════ SKIP (recycle via operator/CRD/Helm; never blanket-roll) ════"
  for entry in "${SKIP[@]}"; do
    echo "    $entry"
  done
  echo
  check_orphans || return 1
  echo
  echo "###############  END DRY-RUN  ###############"
}

# Every live deploy/sts/ds must appear in a tier or SKIP. Preflight runs it too, because a live
# roll never touches an unmapped workload and says nothing about it.
check_orphans() {
  local arr_name entry tname mapped=()
  for tname in "${ALL_TIERS[@]}"; do
    arr_name="$(tier_array_name "$tname")"
    # shellcheck disable=SC1087
    declare -n entries="$arr_name"
    mapped+=("${entries[@]}")
  done
  for entry in "${SKIP[@]}"; do
    mapped+=("${entry%% *}") # strip trailing "  # why"
  done

  echo "════ ORPHAN CROSS-CHECK (live deploy/sts/ds vs map) ════"
  local live orphans=0 key kind ns name
  # Normalize live workloads into "<ns>:<kind>/<name>" with kind ∈ deploy|sts|ds.
  # An empty list cannot validate the map: kubectl failed, or the context points at the wrong cluster.
  live="$(kubectl get deploy,sts,ds -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{":"}{.kind}{"/"}{.metadata.name}{"\n"}{end}')" || live=""
  if [ -z "$live" ]; then
    echo "    ✘ kubectl listed no workloads — cannot check the map."
    return 1
  fi
  local normalized=()
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    ns="${key%%:*}"
    kind="${key#*:}"
    name="${kind#*/}"
    kind="${kind%%/*}"
    case "$kind" in
    Deployment) kind=deploy ;;
    StatefulSet) kind=sts ;;
    DaemonSet) kind=ds ;;
    esac
    normalized+=("$ns:$kind/$name")
  done <<<"$live"

  local m found
  for key in "${normalized[@]}"; do
    found=0
    for m in "${mapped[@]}"; do
      [ "$m" = "$key" ] && {
        found=1
        break
      }
    done
    if [ "$found" -eq 0 ]; then
      echo "    ⚠ ORPHAN (unmapped): $key"
      orphans=$((orphans + 1))
    fi
  done
  if [ "$orphans" -eq 0 ]; then
    echo "    ✔ zero orphans — every live deploy/sts/ds is mapped to a tier or SKIP (${#normalized[@]} workloads checked)"
  else
    echo "    ✘ $orphans orphan workload(s) — FIX THE MAP before any live roll."
    return 1
  fi
}

# ── Arg parsing / main ──────────────────────────────────────────────────────────────────────────
ALL_TIERS=(dns operators platform dnscache apps)

usage() {
  echo "usage: cluster-roll.sh [--dry-run | --tier <name> | --from-tier <name> | --user-facing]" >&2
  echo "       tier names: ${ALL_TIERS[*]}" >&2
  exit 2
}

main() {
  command -v kubectl >/dev/null || die "kubectl not found"
  command -v jq >/dev/null || die "jq not found"
  [ -x "$VERIFY_CLUSTERIP" ] || die "verify-clusterip.sh not executable at $VERIFY_CLUSTERIP"
  [ -x "$POD_HEALTH" ] || die "pod-health.sh not executable at $POD_HEALTH"

  # Strict arg counts: if extra args were ignored, `--tier dns --dry-run` would run LIVE.
  case "${1:-}" in
  --dry-run)
    [ "$#" -eq 1 ] || usage
    dry_run
    ;;
  --tier)
    [ "$#" -eq 2 ] || usage
    local t="${2:-}"
    tier_array_name "$t" >/dev/null || usage
    preflight
    roll_tier "$t"
    ;;
  --from-tier)
    [ "$#" -eq 2 ] || usage
    local t="${2:-}" started=0 x
    tier_array_name "$t" >/dev/null || usage
    preflight
    for x in "${ALL_TIERS[@]}"; do
      [ "$x" = "$t" ] && started=1
      [ "$started" -eq 1 ] && roll_tier "$x"
    done
    ;;
  --user-facing) # alias: roll just tier 5 (the user-facing app fleet)
    [ "$#" -eq 1 ] || usage
    preflight
    roll_tier apps
    ;;
  "")
    [ "$#" -eq 0 ] || usage
    preflight
    for x in "${ALL_TIERS[@]}"; do roll_tier "$x"; done
    ;;
  *)
    usage
    ;;
  esac
}

main "$@"
