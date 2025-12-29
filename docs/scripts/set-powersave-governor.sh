#!/bin/bash
# Switch CPU governor to powersave for quieter operation
# Run with: sudo bash set-powersave-governor.sh

set -e

echo "Current governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"

# Set governor immediately for all CPUs
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo powersave | tee "$cpu" > /dev/null
done

echo "New governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"

# Make persistent via tmpfiles.d (overwrites performance setting)
cat > /etc/tmpfiles.d/cpu-governor.conf << 'EOF'
w /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor - - - - powersave
EOF

echo "Persistent config written to /etc/tmpfiles.d/cpu-governor.conf"
echo "Done! Governor will persist across reboots."
