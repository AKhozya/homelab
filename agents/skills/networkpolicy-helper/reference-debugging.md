# NetworkPolicy debugging

Read this when a pod reports `connection refused` or `connection timed out` and a NetworkPolicy may be the cause.

**REJECT vs DROP — read the error verb (kube-router; memory `gotchas.md` "kube-router renders NP-blocked egress as connection refused (RST)"):**
- `connection refused` to a peer that is **Running+Ready and listening** = kube-router actively REJECTed a policy-blocked egress with a RST. It looks identical to "nothing is listening" / app-down — but the cause is a MISSING EGRESS rule on the SOURCE pod, not the destination. Check the source NP before touching the target.
- `connection timed out` = packet silently DROPped — no matching rule, wrong CNI, or the target genuinely unreachable.
- Confirm causation: correlate the error's earliest log timestamp against the NP's apply time (`kubectl get netpol <x> -o jsonpath` AGE / Flux apply). F-48: 56 × "connection refused" to a 2/2-Running redis pod, earliest ts = exactly NP-apply → the NP, not redis.
