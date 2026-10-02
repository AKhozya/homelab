# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/immich_gpu_node/files/immich-gpu-heal.sh
OUT_FILES=(/var/lib/node-maintenance/immich-gpu-heal.state)
ARGS=(--selfcheck)
