# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/node_isolation_heal/files/node-isolation-heal.sh
OUT_FILES=(/var/lib/node-isolation-heal/state /var/lib/k3s-agent-restart/cooldown)
mkdir -p /var/lib/node-isolation-heal
export NIH_MOCK_KUBELET=0 NIH_MOCK_GW=0 NIH_MOCK_PEERS=1 NIH_DRY_RUN=0 NIH_UPTIME_OVERRIDE=50000
export NIH_MOCK_TUNNEL=1 NIH_MOCK_CP=0
echo "$((FAKE_NOW - 400)) 2 0 0" >/var/lib/node-isolation-heal/state
# clusterip-heal holds the shared restart lock for the whole run.
mkdir -p /var/lib/k3s-agent-restart && touch -d "@$((FAKE_NOW - 3600))" /var/lib/k3s-agent-restart/cooldown
# tail, not sleep: sleep is a stub here. The holder blocks for the lock, so the probe loop below
# cannot make it lose a -n race and exit.
flock /var/lib/k3s-agent-restart/cooldown tail -f /dev/null &
end=$((SECONDS + 10))
until ! flock -n /var/lib/k3s-agent-restart/cooldown true; do [ "$SECONDS" -lt "$end" ] || break; done
