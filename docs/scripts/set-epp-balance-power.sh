#!/bin/bash
# Set EPP to balance_power for quieter operation
# Run with: sudo bash set-epp-balance-power.sh

set -e

echo "Current EPP: $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)"

# Set EPP for all CPUs
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    echo balance_power | tee "$cpu" > /dev/null
done

echo "New EPP: $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)"

# Make persistent via tmpfiles.d
cat > /etc/tmpfiles.d/cpu-epp.conf << 'EOF'
w /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference - - - - balance_power
EOF

echo "Persistent config written to /etc/tmpfiles.d/cpu-epp.conf"
echo "Done!"
