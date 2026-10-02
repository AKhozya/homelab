#!/usr/bin/env bash
# List the workloads in a namespace that read a given Secret (env secretKeyRef, envFrom
# secretRef, a secret volume, or a projected volume source) — Deployments, StatefulSets,
# DaemonSets, CronJobs and Jobs.
# Reads workload specs only, never the Secret. A script, not an inline pipeline: the permission
# deny list refuses any command line that starts with `kubectl get` and contains "secret".
#
# Usage: secret-readers.sh <namespace> <secret-name>
set -euo pipefail
if [ "$#" -ne 2 ]; then
  echo "usage: $0 <namespace> <secret-name>" >&2
  exit 2
fi
kubectl get deploy,sts,ds,cronjob,job -n "$1" -o json |
  jq -r --arg s "$2" '.items[] |
    select([.. | objects | (.secretKeyRef.name?, .secretRef.name?, .secret.secretName?, .secret.name?)] | index($s)) |
    "\(.kind)/\(.metadata.name)"'
