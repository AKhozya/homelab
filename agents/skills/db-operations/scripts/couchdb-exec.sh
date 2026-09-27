#!/usr/bin/env bash
# CouchDB HTTP API via kubectl exec — sibling of mysql-exec.sh / pg-primary.sh.
# Multi-master: any node accepts writes; sts/couchdb-couchdb lets kubectl pick a pod.
# Resolves admin credentials from the couchdb-couchdb secret (never echoed).
#
# Usage:
#   couchdb-exec.sh <path>                 # GET, e.g. couchdb-exec.sh /_membership
#   couchdb-exec.sh -X POST <path> [curl-args...]   # any method; extra args go to curl
#
# Examples:
#   couchdb-exec.sh /_up
#   couchdb-exec.sh /obsidian/_all_docs
#   couchdb-exec.sh -X POST /obsidian/_compact -H 'Content-Type: application/json'
#
# Override: COUCH_NS=databases COUCH_STS=couchdb-couchdb COUCH_SECRET=couchdb-couchdb
set -euo pipefail
NS="${COUCH_NS:-databases}" # ns is databases, NOT couchdb (verified live 2026-05-16)
STS="${COUCH_STS:-couchdb-couchdb}"
SECRET="${COUCH_SECRET:-couchdb-couchdb}"

[ "$#" -ge 1 ] || {
  echo "usage: $0 [-X METHOD] </path> [extra curl args...]" >&2
  exit 2
}

ADMIN="$(kubectl get secret -n "$NS" "$SECRET" -o jsonpath='{.data.adminUsername}' | base64 -d)"
PW="$(kubectl get secret -n "$NS" "$SECRET" -o jsonpath='{.data.adminPassword}' | base64 -d)"
[ -n "$ADMIN" ] && [ -n "$PW" ] || {
  echo "could not resolve CouchDB admin creds from secret $NS/$SECRET" >&2
  exit 1
}

method=(-X GET)
if [ "$1" = "-X" ]; then
  method=(-X "${2:?method after -X}")
  shift 2
fi
path="${1:?path, e.g. /_membership}"
shift

# Credentials via stdin config (-K -), not argv — argv is visible in ps on the node.
exec kubectl exec -i -n "$NS" "sts/$STS" -- \
  curl -sS -K - "${method[@]}" "http://localhost:5984${path}" "$@" <<EOF
user = "${ADMIN}:${PW}"
EOF
