# Kyverno Policy Promotion — scripts

Read this when you need the flags, exit codes or limits of a script in `scripts/`.

| Script | Use |
|---|---|
| `scripts/scan-violations.sh [--policy <name>] [--json] [--force-regen]` | Read-only scan. Lists PolicyReport fails. Exit 0 clean / 1 violations / 3 false-clean guard. |
| `scripts/seccomp-violators.sh [--json] [--count] [--exclude-ns a,b]` | Read-only LIVE-pod seccomp audit (RuntimeDefault), grouped ns/owner. Bypasses lagging PolicyReports; point-in-time (also check CronJob/Job templates). Exit 0 clean / 1 violators. |
| `scripts/check-policy-action.sh <policy-name>` | Read-only. Prints live vpol `spec.validationActions` (Audit / Deny / unknown). |
| `scripts/prepare-enforce.sh <policy-file-path>` | Local edit: `validationActions` [Audit] → [Deny]. Runs plain `--dry-run=server` (NOT `--server-side`). Does NOT commit. |

## Script quality

All scripts are `set -euo pipefail` with `shellcheck`/`shfmt` clean.
