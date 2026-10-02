# shellcheck shell=bash disable=SC2034
SCRIPT=node-maintenance/ansible/roles/k3s_config/files/k3s-wait-ready.sh
OUT_FILES=(/run/k3s-ready)
behave date <<'EOF'
n=$(( $(cat /harness/clock 2>/dev/null || echo 0) + 1 )); echo "$n" >/harness/clock
if [ "${1:-}" = "+%s" ]; then echo $((FAKE_NOW + n * 5)); else echo "Fri Oct  2 20:00:00 UTC 2026"; fi
EOF
behave iptables-save <<'EOF'
cat /harness-src/inputs/iptables-save.v4
EOF
behave ip6tables-save <<'EOF'
cat /harness-src/inputs/iptables-save.v6
EOF
mkdir -p /etc/rancher/k3s && echo 'apiVersion: v1' >/etc/rancher/k3s/k3s.yaml
stub_at /usr/local/bin/k3s
behave k3s <<'EOF'
case "$*" in *--no-headers*) echo 'coredns-abc 1/1 Running 0 1d' ;; *jsonpath*) echo True ;; esac
EOF
