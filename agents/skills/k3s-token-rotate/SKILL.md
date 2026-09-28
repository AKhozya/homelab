---
name: k3s-token-rotate
description: >-
  Use to rotate the homelab k3s SERVER token cluster-wide — after it leaks/is exposed (pasted into a
  chat/log/ticket, committed, screen-shared) or on a rotation schedule. The server token
  (K10…::server:…) is the credential that lets a node JOIN the cluster; rotating it kills the old
  value for future joins. NOT for DB passwords → secrets-rotation skill. NOT for the k3s binary
  version → k3s-upgrade skill. NOT for SOPS/app secrets.
---

# k3s server-token rotation

Rotate the k3s **server token** (`K10<ca-hash>::server:<secret>`) cluster-wide. This is the join
credential — an attacker with it + LAN access to the CP `:6443` can join a rogue node. Rotate on leak
or schedule.

## Hard facts (read before running)

- **Irreversible.** `k3s token rotate` re-keys the datastore bootstrap; the old token dies
  immediately, cluster-wide. There is **no roll-back-to-old** — recovery after a rotation is always
  fix-forward (the new token is already in place). Never restore the old token.
- **Cluster-wide.** Per [docs.k3s.io/cli/token](https://docs.k3s.io/cli/token), after rotation the CP
  **and every agent that joined with the old token** must be updated to the new token and restarted.
  The CP restart is a brief apiserver blip; agents keep running on cached certs but need the new token
  for any future re-bootstrap.
- **Runs on the CP as root** (CP-local `k3s token rotate` + `/var/lib/rancher/k3s/server/token` +
  node-maintenance SSH creds to reach agents). **Agents cannot do this** (no CP sudo) — it is an
  operator step.
- **Non-leaking by construction.** `k3s token rotate` generates the new token straight into the
  token file (no `--new-token` in argv). The script never exposes it:

  | Path | Safeguard |
  |---|---|
  | output | the script never prints the token |
  | transport to agents | the script sends it in an ssh-stdin heredoc, never argv/`ps` |
  | env files | the `printf` builtin writes them at `0600` |

  Do NOT rotate by hand in a way that echoes the token.

## Weigh it first

Rotation is a cluster-wide token swap + restarts. If the leak was **local-only** (a private
session/log on a trusted machine) and the CP `:6443` has **zero inbound from the internet** (homelab
default — LAN-only), the practical risk is low; rotating may not be worth the disruption. A leak that
is **public** (committed, pushed, pasted somewhere shared) → rotate.

## Procedure (operator, on the CP)

The script is idempotent-safe and **dry-run by default**.

```bash
# 1. sync the latest repo to the CP (pulls the script into /etc/node-maintenance/)
sudo systemctl start node-maintenance-sync.service

# 2. DRY-RUN first — prints the health check + plan, changes nothing:
sudo /usr/local/sbin/rotate-k3s-server-token.sh

# 3. only if dry-run is clean (cluster healthy, all agents reachable), execute:
sudo /usr/local/sbin/rotate-k3s-server-token.sh --apply
```

What `--apply` does: refuses on a sick cluster → backs up the token/env → `k3s token rotate` to a
freshly generated token → updates the CP token source + restarts k3s + gates on `/readyz` → then, for
each agent **serially**, rewrites `K3S_TOKEN` + restarts k3s-agent + gates on a fresh kubelet
heartbeat (the node Lease `renewTime` advances past the restart; the Ready condition can be stale).

| Exit | Meaning | Next step |
|---|---|---|
| `0` | fully rotated + healthy | none |
| `11` | CP unhealthy after restart; the new token is in `/var/lib/rancher/k3s/server/token` | fix forward: `journalctl -u k3s` |
| `12` | an agent reports no fresh heartbeat; it has the correct new token | investigate that node's `k3s-agent` |

## Gotchas

- **Do not run on a degraded cluster** — the script refuses (preflight gates on `/readyz` + all nodes
  Ready + all agents reachable), because a token swap during instability is how you wedge the CP.
- **A new node joined with the old token?** After rotation it must be (re)joined with the new token
  (`sudo cat /var/lib/rancher/k3s/server/token` on the CP gives the current one — treat as a secret).
- **Backups hold the OLD (now-dead) token** — `…/token-rotate-backups/<stamp>/` on the CP and
  `k3s-agent.service.env.bak-rotate-<stamp>` on each agent. Delete once satisfied; they're forensic
  only, not a rollback (the old token can't decrypt the re-keyed datastore).
- **Only the server token** is rotated. A separate agent-token (`--agent-token`) is not configured on
  this fleet; joins use the server token.
