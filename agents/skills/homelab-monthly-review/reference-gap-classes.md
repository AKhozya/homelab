# Homelab monthly review — known gap classes

Read this before you record Popeye scores, DB primary pins or event-gated items as clean.

## Gap classes

- **Popeye score fluctuates with load** — compare section-level, not headline; 100→90 ≈ resource warns, not security.
- **Pin drift is silent** — check DB primaries every review even when nothing alerted.
- **Event-gated items need evidence hunting** — "validate on next kernel upgrade" class: the event may have already fired unnoticed.

## Ponytail scope

**ponytail sweep is greenfield-first** — homelab is YAML/bash, not app code: `/ponytail-audit` value is marginal (over-built scripts only) and `/ponytail-debt` is ~empty (no `ponytail:` markers accumulate with mode=off default).
