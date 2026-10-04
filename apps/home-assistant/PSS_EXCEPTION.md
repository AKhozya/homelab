# Home Assistant Security Documentation

## Pod Security Standards Classification

**Policy Level:** `privileged` (enforce), with `baseline` audit and warn labels (`namespace.yaml`)

The namespace enforces **privileged**; baseline audit and warn report baseline violations. Every capability the container now adds is on the baseline allowlist, because `NET_RAW` and `NET_ADMIN` are dropped (see below). Lowering enforce to baseline is a separate change: prove it with `kubectl apply --dry-run=server` on the namespace first.

The Kyverno policies `require-non-root` and `require-readonly-rootfs` exclude this namespace (`infrastructure/configs/kyverno-policies/`).

## Security Context Configuration

### Pod-Level Security

```yaml
securityContext:
  runAsUser: 0
  runAsGroup: 0
  fsGroup: 0
  seccompProfile:
    type: RuntimeDefault
```

### Container-Level Security

```yaml
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
    add:
      - NET_BIND_SERVICE
      - CHOWN
      - SETGID
      - SETUID
      - DAC_OVERRIDE
```

## Why Home Assistant Runs as Root

At 2026.9.4 the Home Assistant image starts as root by default. Its image config sets no `User`, and its entrypoint is the s6-overlay `/init`. The upstream container install docs run it with `--privileged` and host networking. Their CLI and Compose examples set no user. This review did not test a non-root start.

### Required Capabilities Explained

| Capability | Lets the process | HA uses it to | Impact |
|---|---|---|---|
| `NET_BIND_SERVICE` | bind ports below 1024 | bind standard ports for some protocols | Low: port binding only |
| `CHOWN` | change file ownership | manage permissions under `/config` | Low: pod filesystem and its own PVC |
| `SETGID` / `SETUID` | set the group or user ID of a process | spawn worker processes | Medium: stays inside the pod |
| `DAC_OVERRIDE` | skip file read, write and execute checks | read and write config files with mixed owners in `/config` | Low: pod filesystem and its own PVC |

### Capabilities deliberately not granted

| Capability | Why HA does not need it here |
|---|---|
| `NET_RAW` | Ping and DHCP discovery use raw sockets. No Ping entity exists (checked 2026-09-28), and DHCP discovery sees only this pod's own network namespace. Raw sockets would let the pod forge frames onto `cni0`. If Ping is set up, add it back. |
| `NET_ADMIN` | Bluetooth needs `hostNetwork` and the host adapter, which this pod has neither of. mDNS/Zeroconf is plain multicast UDP and needs no capability. |

## Security Mitigations

### 1. Disabled Privilege Escalation
```yaml
allowPrivilegeEscalation: false
```
The root process cannot gain privileges beyond the ones granted.

### 2. Seccomp Profile
```yaml
seccompProfile:
  type: RuntimeDefault
```
The runtime default seccomp profile blocks dangerous syscalls, even for root.

### 3. Capability Dropping
```yaml
capabilities:
  drop:
    - ALL
  add: [only required capabilities]
```

### 4. Network Isolation
NetworkPolicies allow the traffic below. Egress access is broad:

| Direction | Peer | Ports |
|---|---|---|
| ingress | the `traefik` and `uptime-kuma` namespaces, and the admin-setup Job | TCP 8123 |
| egress | `192.168.0.0/16` (LAN devices) | every port |
| egress | the internet (`0.0.0.0/0` except private ranges) | TCP 80, 443 |
| egress | any address | UDP 5353; TCP 1883, 8883 |
| egress | MySQL in the `databases` namespace | TCP 3306 |
| egress | the `kube-system` namespace, for DNS (`allow-dns-egress` component) | UDP and TCP 53 |

No `hostNetwork`, `hostPID` or `hostIPC` is set, so the pod sees only its own network, processes and IPC.

### 5. Filesystem Isolation
- The Deployment sets no `hostPath` volume and no `privileged` container.
- Persistent storage is one PVC at `/config`.
- `readOnlyRootFilesystem` is off: HA writes to runtime dirs on the root filesystem. `/tmp` is an emptyDir.

## Risk Assessment

### Risk Level: **MEDIUM**

**Justification:** HA runs as root, and the added capabilities serve `/config` file handling and worker processes. The pod has no `hostPath` volume, no `privileged` container, and none of `hostNetwork`, `hostPID` or `hostIPC`, which limits what a compromise reaches on the node. A compromise can still reach whatever the NetworkPolicy allows, and a kernel or container-runtime escape would bypass these controls.

### Attack Vectors Mitigated

| Vector | Mitigations | Residual risk |
|---|---|---|
| Container escape | seccomp profile, no `hostPath`, `allowPrivilegeEscalation: false` | Low |
| Privilege escalation | `allowPrivilegeEscalation: false`, capabilities dropped | Low |
| Network attacks | NetworkPolicy, own network namespace | Medium: a compromised pod reaches every port on the home LAN |
| Filesystem access | no `hostPath`, one PVC, seccomp | Low |

### Accepted Risks

| Risk | Reason | Mitigation |
|---|---|---|
| Root execution | the HA image starts as root by default; a non-root start is untested | seccomp, capabilities dropped, no host filesystem |
| `DAC_OVERRIDE` | config files in `/config` have mixed owners | pod filesystem only, no host access |

## Security Recommendations

### Current Implementation: APPROVED

Root execution stays until HA supports a non-root image. The capability audit below decides each of the five added capabilities on its own.

### Future Improvements

| Improvement | What to do | Status |
|---|---|---|
| Rootless HA | move to non-root when HA supports it officially | upstream documents no non-root mode, and a non-root start is untested (2026-10-04, image 2026.9.4) |
| Capability audit | review the added capabilities as HA changes; if you disable an integration, remove the capabilities only it used | quarterly |
| Runtime monitoring | alert on unexpected privilege use, connections or file access with a runtime security tool | planned (Falco or Tetragon) |

## References

- [Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Home Assistant Container Documentation](https://www.home-assistant.io/installation/linux#docker-compose)
- [Linux Capabilities Manual](https://man7.org/linux/man-pages/man7/capabilities.7.html)
- [Seccomp Security Profiles](https://kubernetes.io/docs/tutorials/security/seccomp/)

## Review 2026-10-04

Checked against `deployment.yaml`, the running pod `home-assistant-5b7f94cd6d-hgkf9` on `worker-node` (image `ghcr.io/home-assistant/home-assistant:2026.9.4`, digest `sha256:3e6710a7…`), and upstream source at tag `2026.9.4`.

| Exception | Evidence | Outcome |
|---|---|---|
| Root | Image config: `User` unset, entrypoint `/init` (s6-overlay). Core `Dockerfile` has no `USER`. Upstream docs (`home-assistant.io`, `_includes/installation/container/cli.md`, `compose.md`) use `--privileged` and host networking. The HA process (PID 10914 on the node) runs as uid 0. | Kept |
| Capability set | `/proc/10914/status` on the node: `CapEff` and `CapBnd` are `0x4c3`, which is CHOWN, DAC_OVERRIDE, SETGID, SETUID and NET_BIND_SERVICE. `NoNewPrivs` is 1 and `Seccomp` is 2 (filter). The running pod matches the manifest. | Matches |
| `NET_BIND_SERVICE` | The observed listeners in the pod's network namespace use local ports of 1024 or above: TCP 8123, 18554 and 18555; UDP 1900, 5353 and ephemeral ports (`/proc/10914/net/{tcp,tcp6,udp,udp6}`, which list the whole namespace, not only PID 10914). k3s v1.37 sets `enable_unprivileged_ports = true` when the kernel is 4.11 or newer (`pkg/agent/containerd/config_linux.go:91`); the node runs 6.18.54. If that holds, the capability grants nothing. The live containerd config needs root on the node to read. Any user inside the pod can read its `ip_unprivileged_port_start` (mode 0644), but this review opened no shell in the pod. | Open: likely unused, not proven. One snapshot cannot show that no integration ever binds a low port |
| `CHOWN`, `DAC_OVERRIDE` | The doc says `/config` has files with mixed owners. The PVC directory on the node needs root to list. | Open: the premise is unverified |
| `SETUID`, `SETGID` | The only child process seen, `go2rtc`, also runs as uid 0, so no user switch was observed. A process snapshot cannot prove the calls never happen. | Open |
| Filesystem | No `hostPath`, no `privileged` container; one PVC at `/config` and an emptyDir at `/tmp`. HA writes `go2rtc` config under `/tmp`. | Kept |
| Host namespaces | The live pod spec sets none of `hostNetwork`, `hostPID` or `hostIPC`. | Kept |
| Network | Egress is wider than this doc said before; see Network Isolation above. | Kept; accepting LAN-wide egress is an operator decision |

A trace of `cap_capable` calls from every process in the container, across a restart and a period of normal use, would show which capabilities HA uses. It cannot prove a capability unused, because an integration that did not run during the trace may still need it. If no check for a capability appears during the observation period, test its removal on its own before changing `deployment.yaml`. The trace needs root on the node (for example `bpftrace`), which this review did not have.

## Approval

**Security Review:** APPROVED, with the open items above
**Last review:** 2026-10-04, by the repo documentation sweep
**Next Review:** 2027-01-04 (quarterly)

**Conclusion:** privileged enforce with baseline audit and warn is the correct classification.
