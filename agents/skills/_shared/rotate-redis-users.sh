#!/usr/bin/env bash
# Rotate the redis-ha ACL users (immich, paperless, blocky, admin) in three passes that overlap the
# old and new password. Edits SOPS files only; the caller commits, merges, reconciles and restarts
# between passes (docs/SECRETS_ROTATION.md section 2).
# Trade-off: pass1 commits the ACL and the consumers together. If a consumer pod restarts between
# that reconcile and the Redis restart, Redis refuses it until the restart. A separate ACL-only
# commit would close that gap at the cost of one more merge; the gap is minutes.
#
#   pass1  ACL line of each user gets `>OLD >NEW`; redis-passwords app keys and every consumer
#          (immich redis-url, paperless PAPERLESS_REDIS, blocky config.yml) get NEW.
#          admin-password stays OLD: the sentinels log in with it.
#          Then: restart Redis replica + master (Redis reads the ACL at startup), then cycle the
#          consumers.
#   pass2  admin-password <- admin's second ACL token (NEW). A rerun is a no-op. Then: restart
#          the Redis pods (REDIS_PASSWORD comes from admin-password) and each sentinel.
#   pass3  each ACL line keeps only the token equal to its redis-passwords key.
#          Then: restart Redis replica + master.
#
# Each pass derives its input from the files, so a lost shell between passes loses nothing.
# Blocky sets redis `required: true`: a blocky pod that cannot log in to Redis does not start,
# and blocky serves cluster DNS. That is why pass 1 must restart Redis before cycling consumers.
# Never prints a password. Passwords go to stdin, environment variables and a private temp dir,
# never to argv. All checks run before the first write. If a `sops set` still fails mid-pass, the
# edits are uncommitted: `git checkout -- <the 5 files>` and run the pass again.
#
# Usage (repo root or worktree): rotate-redis-users.sh pass1|pass2|pass3|status
#   status  per user: ACL token count, and whether redis-passwords and each consumer hold a
#           value the ACL accepts. Run it after every pass and before committing.
set -euo pipefail

PW=infrastructure/configs/databases/redis-ha/passwords-secret.yaml
ACL=infrastructure/configs/databases/redis-ha/acl-secret.yaml
IMMICH=apps/immich/immich-redis-url-secret.yaml
PAPERLESS=apps/paperless-ngx/paperless-env-secret.yaml
BLOCKY=apps/blocky/config-secret.yaml
USERS="immich paperless blocky admin"

pass="${1:-}"
case "$pass" in pass1 | pass2 | pass3 | status) ;; *)
  echo "usage: $0 pass1|pass2|pass3|status" >&2
  exit 2
  ;;
esac
for f in "$PW" "$ACL" "$IMMICH" "$PAPERLESS" "$BLOCKY"; do
  [ -f "$f" ] || {
    echo "missing $f; run from the homelab repo root" >&2
    exit 2
  }
done

tmp="$(mktemp -d)"
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT

sops -d --output-type json "$PW" >"$tmp/pw.json"
sops -d --extract '["stringData"]["user.acl"]' "$ACL" >"$tmp/acl"

# The ACL tokens of one user, one per line, without the leading '>'.
acl_tokens() { awk -v u="$1" '$1 == "user" && $2 == u { for (i = 3; i <= NF; i++) if ($i ~ /^>/) print substr($i, 2) }' "$tmp/acl"; }
cur() { jq -j --arg k "$1-password" '.stringData[$k]' "$tmp/pw.json"; }
set_key() { # file key ; JSON string value on stdin
  sops set --value-stdin "$1" "[\"stringData\"][\"$2\"]"
}
# Rewrite one user's ACL line: its '>' tokens become the given list (newline-separated, from a file).
rewrite_acl_user() {
  TOK="$(paste -sd' ' "$2" | sed 's/[^ ][^ ]*/>&/g')" awk -v u="$1" '
    $1 == "user" && $2 == u {
      out = ""; done = 0
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^>/) { if (!done) { out = out " " ENVIRON["TOK"]; done = 1 } continue }
        out = out " " $i
      }
      print substr(out, 2); next
    }
    { print }' "$tmp/acl" >"$tmp/acl.new" && mv "$tmp/acl.new" "$tmp/acl"
}
write_acl() { jq -Rs . <"$tmp/acl" | set_key "$ACL" user.acl; }
# The ACL `default` user holds the admin password (the RedisReplication redisSecret is
# admin-password: the operator, probe, exporter and masterauth use it). Keep its tokens equal to
# admin's in every pass. If `default` is still `nopass`, leave it alone.
mirror_default() {
  acl_tokens default >"$tmp/tok.default"
  if [ -s "$tmp/tok.default" ]; then
    acl_tokens admin >"$tmp/tok.admin.now"
    rewrite_acl_user default "$tmp/tok.admin.now"
  fi
}
# Consumer password of a user, extracted from its secret, to "$tmp/consumer.<user>".
consumer_pw() {
  case "$1" in
  immich)
    v="$(sops -d --extract '["stringData"]["redis-url"]' "$IMMICH")"
    printf '%s' "${v#ioredis://}" | base64 -d | jq -j '.password' >"$tmp/consumer.immich"
    ;;
  paperless)
    sops -d --extract '["stringData"]["PAPERLESS_REDIS"]' "$PAPERLESS" |
      sed -E 's#^[a-z]+://paperless:([^@]*)@.*#\1#' | tr -d '\n' >"$tmp/consumer.paperless"
    ;;
  blocky)
    sops -d --extract '["stringData"]["config.yml"]' "$BLOCKY" | yq -r '.redis.password' | tr -d '\n' >"$tmp/consumer.blocky"
    ;;
  esac
}

case "$pass" in
status)
  for u in $USERS; do
    acl_tokens "$u" >"$tmp/tok.$u"
    cur "$u" >"$tmp/pw.$u"
    line="$u acl-tokens=$(wc -l <"$tmp/tok.$u" | tr -d ' ') redis-passwords-accepted=$(grep -q -x -F -f "$tmp/pw.$u" "$tmp/tok.$u" && echo yes || echo NO)"
    if [ "$u" != admin ]; then
      consumer_pw "$u"
      line="$line consumer-accepted=$(grep -q -x -F -f "$tmp/consumer.$u" "$tmp/tok.$u" && echo yes || echo NO) consumer==redis-passwords=$(cmp -s "$tmp/consumer.$u" "$tmp/pw.$u" && echo yes || echo no)"
    fi
    echo "$line"
  done
  acl_tokens default >"$tmp/tok.default"
  acl_tokens admin >"$tmp/tok.admin"
  echo "default acl-tokens=$(wc -l <"$tmp/tok.default" | tr -d ' ') equals-admin=$(cmp -s "$tmp/tok.default" "$tmp/tok.admin" && echo yes || echo NO)"
  ;;
pass1)
  for u in immich paperless blocky; do
    consumer_pw "$u"
    cmp -s "$tmp/consumer.$u" <(cur "$u") || {
      echo "$u: consumer password differs from redis-passwords $u-password; fix that first" >&2
      exit 1
    }
  done
  for u in $USERS; do
    acl_tokens "$u" >"$tmp/tok.$u"
    [ "$(wc -l <"$tmp/tok.$u" | tr -d ' ')" = 1 ] || {
      echo "$u: ACL line must hold exactly one password before pass1 (an unfinished rotation?)" >&2
      exit 1
    }
    cur "$u" >"$tmp/old.$u"
    cmp -s <(tr -d '\n' <"$tmp/tok.$u") "$tmp/old.$u" || {
      echo "$u: ACL password differs from redis-passwords $u-password; fix that first" >&2
      exit 1
    }
    openssl rand -hex 32 | tr -d '\n' >"$tmp/new.$u"
    # Order matters: pass2 takes the SECOND token as NEW.
    {
      cat "$tmp/old.$u"
      echo
      cat "$tmp/new.$u"
      echo
    } >"$tmp/both.$u"
    rewrite_acl_user "$u" "$tmp/both.$u"
  done
  acl_tokens default >"$tmp/tok.default"
  if [ -s "$tmp/tok.default" ] && ! cmp -s "$tmp/tok.default" <(printf '%s\n' "$(cat "$tmp/old.admin")"); then
    echo "default: ACL password differs from admin's; fix that first" >&2
    exit 1
  fi
  mirror_default
  # Build every consumer's new value before the first write. paperless URL and blocky config
  # hold the password as plain text; it must occur exactly once, so nothing else changes.
  for x in "paperless:$PAPERLESS:PAPERLESS_REDIS" "blocky:$BLOCKY:config.yml"; do
    IFS=: read -r u f k <<<"$x"
    sops -d --output-type json "$f" | jq -c --arg k "$k" '.stringData[$k]' >"$tmp/val.$u"
    if [ "$(OLD="$(cat "$tmp/old.$u")" jq '(split(env.OLD) | length) - 1' "$tmp/val.$u")" != 1 ]; then
      echo "$u: old password must occur exactly once in $f [$k]" >&2
      exit 1
    fi
    OLD="$(cat "$tmp/old.$u")" NEW="$(cat "$tmp/new.$u")" jq -c 'split(env.OLD) | join(env.NEW)' "$tmp/val.$u" >"$tmp/out.$u"
  done
  # immich: ioredis://<base64(JSON)>, the password is a JSON field.
  v="$(sops -d --extract '["stringData"]["redis-url"]' "$IMMICH")"
  printf '%s' "${v#ioredis://}" | base64 -d >"$tmp/immich.json"
  OLD="$(cat "$tmp/old.immich")" jq -e '.password == env.OLD' "$tmp/immich.json" >/dev/null || {
    echo "immich: old password not found in $IMMICH [redis-url]" >&2
    exit 1
  }
  NEW="$(cat "$tmp/new.immich")" jq -j -c '.password = env.NEW' "$tmp/immich.json" >"$tmp/immich.new"
  printf 'ioredis://%s' "$(base64 <"$tmp/immich.new" | tr -d '\n')" | jq -Rs . >"$tmp/out.immich"

  # Writes.
  write_acl
  echo "acl: 4 users (and default, if it has a password) hold OLD and NEW"
  for u in immich paperless blocky; do
    jq -c -n --rawfile v "$tmp/new.$u" '$v' | set_key "$PW" "$u-password"
  done
  echo "redis-passwords: immich, paperless, blocky -> NEW (admin unchanged)"
  set_key "$PAPERLESS" PAPERLESS_REDIS <"$tmp/out.paperless"
  set_key "$BLOCKY" config.yml <"$tmp/out.blocky"
  set_key "$IMMICH" redis-url <"$tmp/out.immich"
  echo "consumers: paperless, blocky, immich -> NEW"
  ;;
pass2)
  acl_tokens admin >"$tmp/tok.admin"
  cur admin >"$tmp/cur.admin"
  [ "$(wc -l <"$tmp/tok.admin" | tr -d ' ')" = 2 ] || {
    echo "admin: ACL must hold OLD then NEW (run pass1 first)" >&2
    exit 1
  }
  sed -n 2p "$tmp/tok.admin" | tr -d '\n' >"$tmp/new.admin"
  if cmp -s "$tmp/cur.admin" "$tmp/new.admin"; then
    echo "admin-password already holds NEW; nothing to do"
  elif cmp -s "$tmp/cur.admin" <(sed -n 1p "$tmp/tok.admin" | tr -d '\n'); then
    jq -Rs . <"$tmp/new.admin" | set_key "$PW" admin-password
    echo "redis-passwords: admin -> NEW"
  else
    echo "admin-password matches neither ACL token; stopping" >&2
    exit 1
  fi
  ;;
pass3)
  # A consumer still holding OLD would be refused after this pass's Redis restart.
  for u in immich paperless blocky; do
    consumer_pw "$u"
    cmp -s "$tmp/consumer.$u" <(cur "$u") || {
      echo "$u: consumer does not hold redis-passwords $u-password; finish pass1 first" >&2
      exit 1
    }
  done
  for u in $USERS; do
    cur "$u" >"$tmp/keep.$u"
    acl_tokens "$u" >"$tmp/tok.$u"
    grep -q -x -F -f "$tmp/keep.$u" "$tmp/tok.$u" || {
      echo "$u: redis-passwords $u-password is not among its ACL tokens; stopping" >&2
      exit 1
    }
    {
      cat "$tmp/keep.$u"
      echo
    } >"$tmp/one.$u"
    rewrite_acl_user "$u" "$tmp/one.$u"
  done
  mirror_default
  write_acl
  echo "acl: each user holds only its redis-passwords value"
  ;;
esac
