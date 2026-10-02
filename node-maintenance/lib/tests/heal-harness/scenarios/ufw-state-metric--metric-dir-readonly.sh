# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/firewall/files/ufw-state-metric.sh
mkdir -p /etc/ufw && echo 'ENABLED=yes' >/etc/ufw/ufw.conf
mount --bind /var/lib/node_exporter/textfile /var/lib/node_exporter/textfile
mount -o remount,bind,ro /var/lib/node_exporter/textfile
