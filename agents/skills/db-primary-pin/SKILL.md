---
name: db-primary-pin
description: Pin homelab DB primary (CNPG / Percona MySQL) to a target node. Use when "make sure DB primary on W1" / "switchover Postgres to <node>". One command per engine (cnpg promote / orchestrator graceful takeover) with verify. Redis is NOT pinnable — operator repairs topology; skill reports Redis placement read-only. Pin is best-effort — operator may re-fail-over under outage.
user-invocable: false
---

# DB primary node-pin

## Fast path

```bash
bash ~/.agents/skills/db-primary-pin/scripts/pin.sh <engine> <cluster> <target-node>
```

- `<engine>`: `cnpg` | `percona` (`redis` = read-only placement report, see Caveats)
- `<cluster>`: ns-qualified for cnpg/percona (`databases/main-postgres`, `databases/main-mysql`), or just cluster ns for redis (`databases`)
- `<target-node>`: e.g. `worker-node`, `worker-node-2`

Examples:
```bash
bash ~/.agents/skills/db-primary-pin/scripts/pin.sh cnpg databases/main-postgres worker-node
bash ~/.agents/skills/db-primary-pin/scripts/pin.sh percona databases/main-mysql worker-node
```

Script: find current primary → if already on target, exit 0 → otherwise trigger the engine-specific switchover → poll until primary on target → verify cluster healthy.

## Caveats

- **Redis pin RETIRED (2026-07-04).** ot redis-operator records `RedisReplication .status.masterNode` and actively repairs topology — 3 consecutive sentinel failovers all bounced back within seconds (W2→W1 attempt); each churns immich/paperless connections. Script's `redis` mode now only REPORTS placement and hard-fails on mismatch. Accept placement (apps use master-following Service — cosmetic while replication healthy); revisit if the CRD ever grows a preferred-master knob (none as of operator chart 2026-07). Diagnostic signature: `master_replid2` non-zero = swap-then-bounce.
- **After any Redis failover, check immich.** ioredis SentinelConnector spews reconnect stacks during the transition — usually self-recovers <3min (2026-06-05: 90 error lines then clean); if errors persist past ~5min it's the stale-connection case (2026-05-31) → `~/.agents/skills/_shared/restart-workload.sh immich app.kubernetes.io/name=immich-server` (immich-server is an app Deployment, not a database, so a pod cycle is fine; the bot has no workload `patch` since 2026-08-06). Verify: `kubectl logs -n immich deploy/immich-server --since=60s | grep -ci ioredis` → expect 0.
- **Percona with no primary is out of scope.** `pin.sh` exits with `could not determine current primary index`. If you see that error, follow `db-operations/reference-ops.md` (two "(replica)" blocks) and memory `gotcha_cp_igc_link_flap`.
- **Percona path facts:**

  | Fact | Detail |
  |---|---|
  | orchestrator API auth | basic auth (`ORC_API_AUTH=true`); `pin.sh` passes user `orchestrator` and reads its password inside the pod |
  | live check | the topology step below passed on 2026-09-28 |
  | parser fixture | that run's captured output, in `scripts/pin-parse.test.sh`; run it after any parser change |

  Before a takeover, run the topology step; it must list a line ending in `rw,...]`:
  `kubectl exec -n databases main-mysql-orc-0 -c orchestrator -- bash -c 'ORCHESTRATOR_AUTH_USER=orchestrator ORCHESTRATOR_AUTH_PASSWORD=$(<"/etc/orchestrator/orchestrator-users-secret/orchestrator"); export ORCHESTRATOR_AUTH_USER ORCHESTRATOR_AUTH_PASSWORD; exec orchestrator-client -c topology -i main-mysql-mysql-0.main-mysql-mysql.databases:3306'`
- **Percona `downtimed` flag** appears briefly on old primary after orchestrator takeover. Auto-clears within minutes; not an error.
- **CNPG promote** doesn't restart pods, only switches primary role. Spec-change restarts need `/cnpg-full-roll`.
- **Pin drifts SILENTLY on spurious failover.** 2026-06-04: cnpg-operator (leader on wn2, flaky VXLAN) declared the healthy W1 primary dead → failover moved primary to wn2; nothing alerted, found a day later via flannel TX-drop forensics. After ANY node/network incident: `kubectl get cluster main-postgres -n databases -o jsonpath='{.status.currentPrimary}'` + Percona/Redis equivalents, re-pin if drifted. Mitigations live since `47fbf602`: `failoverDelay: 30` + operator nodeAffinity off wn2 (memory: gotcha_worker_node2_flannel_dns).

## See also

- `[[gotchas]]` "DB primary node-pin patterns" — per-engine command details.
- `/cnpg-full-roll` skill — full instance restart for CNPG spec changes.
- `/db-operations` skill — connection patterns + admin queries.
