#!/usr/bin/env bash
# Pass 3 of rotate-redis-users.sh without a Redis restart: on each running Redis pod, remove every
# ACL password hash of each user that is not sha256(its redis-passwords value).
# Why not restart: the ACL Secret is mounted with subPath, so a running pod never sees the new file
# and `ACL LOAD` would re-read the old one; a restart re-reads it but gives both pods new IPs, and on
# 2026-10-02 that left both pods master for ~50s and all three sentinels on a dead IP until they
# were restarted. `ACL SETUSER <user> !<hash>` changes the running server only; the committed
# one-token ACL covers the next start.
# Commands reach redis-cli on stdin, so no hash appears in argv. Prints counts only. Stops before any
# change if a pod lacks a user's NEW hash. ACL changes do not replicate, so it runs on every pod.
#
# Usage (repo root, AFTER the pass-3 commit is applied): redis-acl-drop-old.sh
set -euo pipefail
PW=infrastructure/configs/databases/redis-ha/passwords-secret.yaml
USERS="immich paperless blocky admin default"
[ -f "$PW" ] || {
  echo "run from the homelab repo root" >&2
  exit 2
}
tmp="$(mktemp -d)"
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT
sops -d --output-type json "$PW" >"$tmp/pw.json"
# `default` holds the admin password: the operator, its probe and the exporter log in with it.
for u in $USERS; do
  k="$u"
  if [ "$u" = default ]; then k="admin"; fi
  jq -j --arg k "$k-password" '.stringData[$k]' "$tmp/pw.json" | shasum -a 256 | cut -d' ' -f1 >"$tmp/keep.$u"
done
# redis-cli inside the pod, authenticated with the pod's own REDIS_PASSWORD; commands on stdin.
# shellcheck disable=SC2016  # expands inside the pod
RCLI='[ -z "${REDIS_PASSWORD:-}" ] || export REDISCLI_AUTH="$REDIS_PASSWORD"; exec redis-cli'
rcli() { kubectl exec -i -n databases "$1" -c redis-replication -- sh -c "$RCLI"; }
mapfile -t pods < <(kubectl get pod -n databases -l app=redis-replication -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[ "${#pods[@]}" = 2 ] || {
  echo "expected 2 redis-replication pods, found ${#pods[@]}" >&2
  exit 1
}
# If a pod still runs with REDIS_PASSWORD = OLD admin password (its pass2 restart was skipped),
# dropping OLD from `default` breaks its probe, exporter and operator login on every pod at once.
# shellcheck disable=SC2016  # expands inside the pod
for p in "${pods[@]}"; do
  envhash="$(kubectl exec -n databases "$p" -c redis-replication -- sh -c 'printf %s "${REDIS_PASSWORD:-}" | sha256sum | cut -c1-64' </dev/null)"
  if [ "$envhash" != "$(cat "$tmp/keep.default")" ]; then
    echo "$p: REDIS_PASSWORD is not the NEW admin password; restart the Redis pods (pass2) first" >&2
    exit 1
  fi
done
# Check every pod first, then change any.
for p in "${pods[@]}"; do
  echo "ACL LIST" | rcli "$p" >"$tmp/acl.$p"
  for u in $USERS; do
    grep "^user $u " "$tmp/acl.$p" | grep -o -E '#[0-9a-f]{64}' | cut -c2- >"$tmp/h.$p.$u" || true
    grep -q -x -F -f "$tmp/keep.$u" "$tmp/h.$p.$u" || {
      echo "$p $u: running ACL lacks the NEW hash; stopping before any change" >&2
      exit 1
    }
  done
done
for p in "${pods[@]}"; do
  : >"$tmp/cmds"
  for u in $USERS; do
    { grep -v -x -F -f "$tmp/keep.$u" "$tmp/h.$p.$u" || true; } | sed "s/^/ACL SETUSER $u !/" >>"$tmp/cmds"
  done
  if [ -s "$tmp/cmds" ]; then
    # redis-cli exits 0 on a server error reply, so count the OK replies instead.
    rcli "$p" <"$tmp/cmds" >"$tmp/out"
    want="$(wc -l <"$tmp/cmds" | tr -d ' ')"
    got="$(grep -c -x 'OK' "$tmp/out" || true)"
    echo "$p: $got of $want removals OK"
    [ "$got" = "$want" ] || rc=1
  fi
done
# Every user on every pod must now hold exactly one hash, NEW's. Run again to finish a partial run.
for p in "${pods[@]}"; do
  echo "ACL LIST" | rcli "$p" >"$tmp/acl.$p"
  for u in $USERS; do
    grep "^user $u " "$tmp/acl.$p" | grep -o -E '#[0-9a-f]{64}' | cut -c2- >"$tmp/h.$p.$u" || true
    if [ "$(wc -l <"$tmp/h.$p.$u" | tr -d ' ')" != 1 ] || ! cmp -s "$tmp/h.$p.$u" "$tmp/keep.$u"; then
      echo "$p $u: does not hold exactly the NEW hash" >&2
      rc=1
    fi
  done
done
if [ "${rc:-0}" = 0 ]; then echo "every user on every pod holds only the NEW hash"; fi
exit "${rc:-0}"
