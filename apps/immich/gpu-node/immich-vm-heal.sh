#!/usr/bin/env sh
# immich-vm-heal.sh — Tier-2 host watchdog for the Immich GPU node (Path B).
#
# Runs in-cluster as a k8s CronJob scheduled OFF the GPU node, SSHes the zettOS
# NAS host and drives libvirt via `virsh` (akhozya is in the NAS `libvirt` group —
# no root). It keeps the immich-vm domain (a) defined from the Git canonical XML
# and (b) running. Design: docs/plans/2026-07-10-immich-gpu-node-substrate-heal.md.
#
# SAFETY — host-crash class (incident C3, 2026-07-10):
#   * NEVER `virsh destroy`. Force-destroying this passthrough VM re-binds the
#     still-dirty iGPU to the host i915 (managed='yes') → host GuC wedge → NAS
#     crash. There is no line in this script that destroys.
#   * NEVER restart a *running* domain. The only start path is `virsh start` on a
#     `shut off` domain (a cold start cleanly resets the iGPU). A wedged-but-running
#     guest is left to NodeNotReady alerting + an operator (graceful shutdown or NAS
#     host reboot) — auto cold-restart is barred (kills live transcodes / risks C3).
#   * Heal actions are limited to: `virsh define` (from Git canonical XML) on
#     drift/missing, and `virsh start` on a shut-off domain. Everything else alerts.
#
# Exit 0 = healthy or fully healed. Non-zero = a fault the watchdog cannot fix
# (surfaces via the JobFailed / heal-last-success VMRule → Telegram).
set -eu

NAS_HOST="${NAS_HOST:-192.168.1.136}"
NAS_PORT="${NAS_PORT:-56634}"
NAS_USER="${NAS_USER:-akhozya}"
DOMAIN="${DOMAIN:-0398541a-c088-48cd-b16a-4b45d31a92f3}"
LIBRARY_SRC="${LIBRARY_SRC:-/home/akhozya/immich/library}" # virtiofs source on the NAS (lazy-mounted)
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_nas}"
KNOWN_HOSTS="${KNOWN_HOSTS:-/ssh-known-hosts/known_hosts}"
CANONICAL_XML="${CANONICAL_XML:-/canonical/immich-vm-domain.xml}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
fail() {
  log "RESULT=FAIL reason=$1"
  exit "${2:-1}"
}

# Materialize the NAS key from the SSH_PRIVATE_KEY secret env into an owner-only
# 0400 file. The pod runs non-root (Kyverno require-non-root Enforce covers immich),
# so a secret *volume* — mounted root-owned — can't be chmod'd to the perms sshd's
# StrictModes demands; writing it self-owned into the HOME emptyDir side-steps that.
if [ -n "${SSH_PRIVATE_KEY:-}" ]; then
  mkdir -p "$(dirname "$SSH_KEY")"
  (umask 077 && printf '%s\n' "$SSH_PRIVATE_KEY" >"$SSH_KEY")
  chmod 400 "$SSH_KEY"
fi

# ssh to the NAS. No agent, key-only, pinned host key (a NAS rekey by a firmware
# update → StrictHostKeyChecking fails → surfaces as ssh_unreachable, correct).
ssh_nas() {
  ssh -i "$SSH_KEY" \
    -o IdentitiesOnly=yes \
    -o IdentityAgent=none \
    -o UserKnownHostsFile="$KNOWN_HOSTS" \
    -o GlobalKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=yes \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -p "$NAS_PORT" \
    "$NAS_USER@$NAS_HOST" "$@"
}

# virsh subcommand on the NAS (qemu:///system — non-root default is qemu:///session
# = an EMPTY domain list, which would look like the VM vanished).
vsh() { ssh_nas "virsh -c qemu:///system $1"; }

log "immich-vm-heal start domain=$DOMAIN nas=$NAS_HOST:$NAS_PORT"

# 1. SSH reachability = key present + NAS up + host key matches. All three fail
#    modes (key wiped by update, NAS down, NAS rekeyed) are operator-fix only.
if ! ssh_nas true 2>/tmp/ssh.err; then
  log "DIAGNOSE=ssh_unreachable detail=$(tr '\n' ' ' </tmp/ssh.err)"
  fail ssh_unreachable 3
fi

# 2. libvirt group membership. A zettOS update can rewrite /etc/group: SSH still
#    works but every virsh call would silently fail. Detect explicitly.
if ! ssh_nas "getent group libvirt" | grep -qw "$NAS_USER"; then
  log "DIAGNOSE=libvirt_group_missing fix='usermod -aG libvirt $NAS_USER (needs NAS root)'"
  fail libvirt_group_missing 4
fi

# 3. Defined? Fetch inactive XML; failure = domain missing → define from canonical.
if ! LIVE_XML="$(vsh "dumpxml --inactive $DOMAIN" 2>/tmp/virsh.err)"; then
  log "DIAGNOSE=domain_undefined detail=$(tr '\n' ' ' </tmp/virsh.err)"
  if vsh "define /dev/stdin" <"$CANONICAL_XML"; then
    log "HEAL=redefined_missing"
  else
    fail define_failed 5
  fi
  LIVE_XML="$(vsh "dumpxml --inactive $DOMAIN")"
fi

# 4. Drift = the appliance/UI regenerated the domain from its template (C2/C5),
#    dropping our passthrough edits. libvirt re-emits dumpxml with runtime <address>
#    elements, so a byte-diff false-drifts every run — match the load-bearing markers
#    instead. Any missing marker = clobber → re-define from Git.
drift=0
check_marker() {
  if ! printf '%s' "$LIVE_XML" | grep -q "$1"; then
    drift=1
    log "DRIFT=$2"
  fi
}
check_marker "machine='pc-q35" machine_not_q35
check_marker "type='memfd'" memfd_missing
check_marker "type='virtiofs'" virtiofs_missing
check_marker "immich-library" virtiofs_target_missing
check_marker "52:54:00:82:be:df" mac_changed
# The iGPU passthrough: match the FULL host PCI source address as one marker (not
# slot+function alone — that would pass a managed hostdev on a different bus) plus
# managed passthrough. NOT a bare "<hostdev", which any clobbered hostdev satisfies.
# Inactive XML strips guest-side <address> elements, so this source address is
# unique to the GPU hostdev.
check_marker "domain='0x0000' bus='0x00' slot='0x02' function='0x0'" hostdev_gpu_source_missing
check_marker "managed='yes'" hostdev_gpu_unmanaged
# Pin on_reboot=restart. QEMU supports only destroy|restart here (preserve is on_crash-only → `define`
# rejects it). Both are imperfect on a slipped in-guest reboot, but `destroy` is the C3 host-crash path
# (managed iGPU re-attach) while `restart` only wedges (NAS-host-reboot recoverable) — so if an
# appliance regen flips it to destroy, treat it as drift and re-define back to the canonical restart.
check_marker "<on_reboot>restart</on_reboot>" on_reboot_not_restart

STATE="$(vsh "domstate $DOMAIN" 2>/dev/null || echo unknown)"

if [ "$drift" -eq 1 ]; then
  if vsh "define /dev/stdin" <"$CANONICAL_XML"; then
    log "HEAL=redefined_drift prior_state=$STATE"
  else
    fail define_failed 5
  fi
  if [ "$STATE" = "running" ]; then
    # define only updates persistent config; the running (clobbered, GPU-less)
    # instance is untouched and Immich transcode is degraded until an operator
    # gracefully restarts it. Do NOT auto-restart (reset-bug C3 / live transcodes).
    log "WARN=drift_while_running operator='virsh shutdown --mode acpi $DOMAIN → poll domstate for shut off → virsh start (NEVER destroy/reset)'"
    fail drift_while_running 8
  fi
  # drift while shut off → fall through; the start below boots the canonical XML.
  STATE="$(vsh "domstate $DOMAIN" 2>/dev/null || echo unknown)"
fi

# 5. Ensure running. Only a shut-off domain is started (cold start = clean iGPU
#    reset). This IS the autostart — UI/native autostart is OFF by design (C2/C4).
case "$STATE" in
  running)
    log "OK=domain_running"
    ;;
  "shut off")
    # Autostart mount-gate: the virtiofs SOURCE on the NAS (a btrfs subvol on bcache) lazy-mounts LATE
    # after a NAS reboot — /home/akhozya is a ro tmpfs stub until the subvol mounts over it. Before
    # then `virsh start` fails "virtiofs export directory ... does not exist". Gate on the source dir
    # existing (virsh's own predicate) → skip this cycle if not ready; the next 5-min tick retries. A
    # persistently-down VM is independently caught by k3s NodeNotReady, so a skip needs no separate alert.
    if ! ssh_nas "test -d $LIBRARY_SRC"; then
      log "SKIP=library_source_not_ready path=$LIBRARY_SRC (NAS lazy-mount not up yet — retry next cycle)"
      log "RESULT=OK"
      exit 0
    fi
    if vsh "start $DOMAIN"; then
      log "HEAL=started_domain"
    else
      fail start_failed 6
    fi
    ;;
  *)
    # paused / pmsuspended / crashed / in-shutdown / unknown — never auto-act.
    log "DIAGNOSE=domain_unexpected_state state=$STATE"
    fail "domain_state_${STATE}" 7
    ;;
esac

log "RESULT=OK"
