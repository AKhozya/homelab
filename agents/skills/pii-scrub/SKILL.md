---
name: pii-scrub
description: >-
  Use before making a repo public, open-sourcing, sharing a tree externally, or whenever the user says "scrub", "sanitize", "redact PII", "is this safe to publish", or "remove secrets/emails". Sweeps the working tree for plaintext credentials/keys (gitleaks) AND personal PII (emails, usernames, sourced at runtime — never hardcoded), separates real leaks from placeholders, and reports file:line + remediation. Read-only by default. Knows the homelab conventions: SOPS secrets, internal IPs/hostnames/`h0melab.work` are KEPT by decision, only personal identifiers get scrubbed.
---

# PII / Secret Scrub

Pre-publication gate. Find what must not go public, classify real-vs-placeholder, propose the fix. **Report-only** unless told to edit.

## When this fires

| Trigger | Layer it complements |
|---|---|
| "make public", "open-source", "safe to publish", "scrub", "sanitize" | proactive sweep (this skill) |
| every `git commit` / CI push | the standing gate stack — §5 |

The gate stack is durable; this skill is the deliberate pre-release audit that also catches **personal PII** gitleaks doesn't model.

## 1+2. Sweep (credentials + personal PII, one script)

Current tree only (no history — history author-email is unavoidable, see §4). Identifiers sourced at runtime from `git config` — never hardcoded (a committed identifier re-exposes it):

```bash
bash ~/.agents/skills/pii-scrub/scripts/sweep.sh [DIR]   # exit 0 clean / 1 findings / 2 tooling
```

Wraps `gitleaks dir . --redact` (repo `.gitleaks.toml` if present) + email/name/provider-email greps with `ENC[`-exclusions (SOPS values are fine).

No `.gitleaks.toml`? The homelab one (`~/source-code/homelab/.gitleaks.toml`) is a good base: `useDefault=true`, a custom `sql-identified-by` rule (gitleaks default MISSES `... IDENTIFIED BY '...'` — the form that leaked 3 MySQL passwords), an `ENC[AES256_GCM` allowlist for SOPS values, and placeholder stopwords. Copy + adapt.

**Homelab scope:** internal IPs (`192.168.1.0/24`), hostnames, and `h0melab.work` are KEPT — they're kept by decision, not PII. Only scrub personal name/email. Confirm scope with the user if unsure.

## 3. Classify + remediate

| Finding | Real? | Fix |
|---|---|---|
| `password:`/`PASSWORD=`/`IDENTIFIED BY '…'` literal | yes | move to SOPS secret, reference via `secretKeyRef`; then **rotate** (it's in history) — see `secrets-rotation` skill |
| API key / token / private key | yes | SOPS secret + rotate the credential |
| personal email in app/infra config | yes | SOPS secret + `secretKeyRef`; if a plain-string field (e.g. cert-manager `spec.acme.email`) use a role alias (`acme@<domain>`) |
| `Bearer YOUR_TOKEN`, `<value>`, `${VAR}`, `changeme` | placeholder | leave; add a stopword if the scanner flags it |

Plaintext that already landed in git needs **rotation**, not just redaction — redacting the working tree leaves the secret live in history.

## 4. History caveat

`git log` author email/name are on **every commit** and are your public Git identity — a file-content scrub does not remove them, and rewriting all history to do so is pointless for a published identity. So: scrub file *content*, accept author metadata. Only rewrite history for a real secret (key/token/password) that leaked into a commit — and then rotate it too.

## 5. The gate stack (all wired)

1. `~/.claude/hooks/gitleaks-precommit.sh` — PreToolUse hook, blocks `git commit` (incl. `--no-verify`) on a staged-diff leak. Degrades to allow if gitleaks is missing.
2. `.pre-commit-config.yaml` gitleaks hook — blocks the commit for anyone with pre-commit installed.
3. `gitleaks.yaml` — a separate workflow, because `validate.yaml` skips markdown-only pushes. It runs two server-side scans.

   | Scan | Covers |
   |---|---|
   | `gitleaks dir .` | the checked-out tree |
   | `gitleaks git --log-opts` | the commits this push adds |

   The range scan catches a secret that one commit adds and a later commit in the same push removes. Full history stays unscanned. It holds rotated values that would fail the gate on every run.

All three share `.gitleaks.toml`. This skill is the deliberate, full-tree pre-release audit on top of those incremental gates.

## Boundaries

- Report-only by default. Editing secrets out = explicit ask, and pairs with rotation.
- Never print unredacted secret values; use `--redact` / show file:line.
- Never write a personal identifier into a committed config (scanner rules included).
