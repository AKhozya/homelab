# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/immich_gpu_node/files/immich-gpu-heal.sh
OUT_FILES=(/var/lib/node-maintenance/immich-gpu-heal.state)
mount -t tmpfs none /sys/bus/pci/devices
mkdir -p /sys/bus/pci/devices/0000:00:10.0
echo 0x8086 >/sys/bus/pci/devices/0000:00:10.0/vendor
echo 0x030000 >/sys/bus/pci/devices/0000:00:10.0/class
mount -t tmpfs none /sys/module
mkdir -p /sys/module/i915
mkdir -p /dev/dri && touch /dev/dri/renderD129
behave systemctl <<'EOF'
[ "$1" = cat ] && rc=1
EOF
behave vainfo <<'EOF'
echo 'VAProfileH264Main : VAEntrypointVLD'
EOF
