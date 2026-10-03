# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/immich_gpu_node/files/immich-gpu-heal.sh
OUT_FILES=(/var/lib/node-maintenance/immich-gpu-heal.state)
mount -t tmpfs none /sys/bus/pci/devices
mkdir -p /sys/bus/pci/devices/0000:00:10.0
echo 0x8086 >/sys/bus/pci/devices/0000:00:10.0/vendor
echo 0x030000 >/sys/bus/pci/devices/0000:00:10.0/class
mount -t tmpfs none /sys/module
mkdir -p /sys/module/i915
echo "0 0 0 0 $((FAKE_NOW - 60))" >/var/lib/node-maintenance/immich-gpu-heal.state
# The restart moves the clock 200 s, so the saved `last` tells the save after the restart from the one before it.
behave systemctl <<'EOF'
[ "$1" = cat ] && rc=1
[ "$1" = restart ] && echo "$((FAKE_NOW + 200))" >/harness/now && rc=1
EOF
