# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/clusterip_heal/files/clusterip-heal.sh
OUT_FILES=(/var/lib/node-maintenance/clusterip-heal.state /var/lib/k3s-agent-restart/cooldown)
stub_at /etc/node-maintenance/bin/clusterip-probe.sh
behave_seq clusterip-probe.sh "1"
# Another watchdog holds the shared restart lock for the whole run.
mkdir -p /var/lib/k3s-agent-restart && touch -d "@$((FAKE_NOW - 3600))" /var/lib/k3s-agent-restart/cooldown
# tail, not sleep: sleep is a stub here and would return at once, releasing the lock.
# The holder blocks for the lock: the probe loop below briefly takes it too, and a -n holder
# that lost that race would exit and leave the lock free.
flock /var/lib/k3s-agent-restart/cooldown tail -f /dev/null &
end=$((SECONDS + 10))
until ! flock -n /var/lib/k3s-agent-restart/cooldown true; do [ "$SECONDS" -lt "$end" ] || break; done
