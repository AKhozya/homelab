#!/usr/bin/env bash
# ssh-alias-resolve.sh — single source of truth for homelab node SSH identities.
# Source this (do not execute); it defines:
#   SSH_NODE_PORT      65300 (all nodes)
#   resolve_alias X    print user@host for a zsh alias, plain hostname, or shorthand:
#                      ssh_master_node|gmk-k3s-control-plane|cp  → akhozya@gmk-k3s-control-plane
#                      ssh_worker_node|worker-node|w1            → akhozya@worker-node
#                      ssh_worker_node2|worker-node-2|w2         → z3us@worker-node-2
#                      immich-vm|gpu                             → akhozya@immich-vm
# Bash scripts cannot use the caller's zsh aliases (ssh_*), so they use this map. Change a host,
# user or port here, not in the scripts that source this.
# shellcheck disable=SC2034  # consumed by sourcing scripts, not here
SSH_NODE_PORT=65300

resolve_alias() {
  case "$1" in
  ssh_master_node | gmk-k3s-control-plane | cp) echo "akhozya@gmk-k3s-control-plane" ;;
  ssh_worker_node | worker-node | w1) echo "akhozya@worker-node" ;;
  ssh_worker_node2 | worker-node-2 | w2) echo "z3us@worker-node-2" ;;
  immich-vm | gpu) echo "akhozya@immich-vm" ;;
  *)
    echo "resolve_alias: unknown node '$1' (use cp|w1|w2|immich-vm, a hostname, or an ssh_* alias)" >&2
    return 2
    ;;
  esac
}
