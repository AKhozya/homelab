# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/immich_gpu_node/files/immich-gpu-heal.sh
OUT_FILES=(/var/lib/node-maintenance/immich-gpu-heal.state)
mount -t tmpfs none /sys/bus/pci/devices
mkdir -p /sys/bus/pci/devices/0000:00:10.0
echo 0x8086 >/sys/bus/pci/devices/0000:00:10.0/vendor
echo 0x030000 >/sys/bus/pci/devices/0000:00:10.0/class
mount -t tmpfs none /sys/module
mkdir -p /sys/module/i915
behave systemctl <<'EOF'
[ "$1" = cat ] && rc=1
EOF
echo "$((FAKE_NOW - 100)) 3 7 $((FAKE_NOW - 400)) $((FAKE_NOW - 60))" >/var/lib/node-maintenance/immich-gpu-heal.state
# A vainfo from an earlier probe still runs: pgrep finds it, so the render-down path must report qsv_stuck 1.
rm -f /usr/bin/pgrep
stub_at /usr/bin/pgrep
