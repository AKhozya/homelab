#!/usr/bin/env bash
# prepare-enforce.sh — local Audit → Deny flip on a ValidatingPolicy file
#
# Usage:
#   prepare-enforce.sh <path-to-policy-file>
#
# Behavior:
# 1. Refuse if file lacks "validationActions: [Audit]" (idempotent guard).
# 2. Edit in place: validationActions [Audit] → [Deny].
# 3. Run kubectl apply --dry-run=server against the edited file.
# 4. Print the resulting `git diff` so caller can review.
# 5. Does NOT git add, git commit, or git push. Caller commits via /gitops-workflow.
#
# Exit codes:
#   0 = file edited, dry-run accepted
#   1 = file missing required Audit line / already Deny
#   2 = usage / dependency error
#   3 = dry-run failed (caller must investigate before committing)

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <path-to-policy-file>" >&2
  exit 2
fi

FILE="$1"

if [[ ! -f "$FILE" ]]; then
  echo "error: file not found: $FILE" >&2
  exit 2
fi

for cmd in kubectl grep sed; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: required command not found: $cmd" >&2
    exit 2
  fi
done

# Idempotent guard: only proceed if file carries the canonical flow-style Audit line.
# Homelab VPs use `validationActions: [Audit]` (flow style, one line) — block style
# or extra actions ([Audit, Warn]) need manual review, not a blind sed.
if ! grep -qE '^ *validationActions: \[Audit\]$' "$FILE"; then
  if grep -qE '^ *validationActions: \[Deny\]$' "$FILE"; then
    echo "no-op: file already Deny: $FILE"
    exit 1
  fi
  echo "error: file does not contain 'validationActions: [Audit]' at expected shape" >&2
  echo "       (manual review required — script edits only canonical flow-style VP shape)" >&2
  exit 1
fi

# Edit in place. macOS sed differs from GNU sed on -i flag; use temp file pattern
# that works on both.
TMP="$(mktemp)"
# Pristine copy for rollback if the dry-run rejects the edit.
ORIG="$(mktemp)"
cp "$FILE" "$ORIG"
trap 'rm -f "$TMP" "$ORIG"' EXIT

BEFORE_AUDIT="$(grep -cE '^ *validationActions: \[Audit\]$' "$FILE" || true)"
PRE_DENY="$(grep -cE '^ *validationActions: \[Deny\]$' "$FILE" || true)"

sed -E 's/^( *)validationActions: \[Audit\]$/\1validationActions: [Deny]/' "$FILE" >"$TMP"

AFTER_DENY="$(grep -cE '^ *validationActions: \[Deny\]$' "$TMP" || true)"
FLIPPED=$((AFTER_DENY - PRE_DENY))

if [[ "$FLIPPED" -ne "$BEFORE_AUDIT" ]]; then
  echo "error: flipped $FLIPPED line(s) but file had $BEFORE_AUDIT Audit line(s) (pre-existing Deny=$PRE_DENY)" >&2
  exit 1
fi

mv "$TMP" "$FILE"
# trap stays armed: ORIG must survive until the dry-run below has passed (it is the
# rollback source) and gets cleaned on any exit path.

echo "edited: $FILE"
echo

# Dry-run to catch schema rejection / admission webhook issues.
# Plain --dry-run=server (NOT --server-side) — server-side apply hits
# field-ownership conflicts with Flux's kustomize-controller and returns
# exit 1 even though the policy itself is valid. Plain dry-run still runs
# admission webhooks which is what we actually want to test.
echo "=== kubectl apply --dry-run=server ==="
if ! kubectl apply --dry-run=server -f "$FILE" 2>&1; then
  echo
  echo "error: dry-run failed — review error above before committing" >&2
  echo "       reverting edit to leave working tree clean" >&2
  cp "$ORIG" "$FILE"
  exit 3
fi

echo
echo "=== resulting git diff ==="
if command -v git >/dev/null 2>&1 && git -C "$(dirname "$FILE")" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$(dirname "$FILE")" diff -- "$(basename "$FILE")"
else
  echo "(not in a git repo; showing edited file's action lines)"
  grep -n 'validationActions' "$FILE"
fi

echo
echo "next: review diff above, then commit per /gitops-workflow"
