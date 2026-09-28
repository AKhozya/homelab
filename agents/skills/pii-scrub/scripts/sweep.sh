#!/usr/bin/env bash
# sweep.sh — pii-scrub full-tree sweep: gitleaks (credentials/keys) + personal-PII greps.
# Identifiers sourced at RUNTIME from git config — never hardcoded (committing them re-exposes).
# grep not rg: rg is a zsh function in this env, absent from script PATH.
# Read-only. Exit 0 = clean, 1 = findings printed, 2 = tooling/setup failure.
#
# Usage: sweep.sh [DIR]   (default .)
set -euo pipefail

DIR="${1:-.}"
cd "$DIR"
command -v gitleaks >/dev/null || {
  echo "gitleaks not installed" >&2
  exit 2
}

found=0
# X's must end the template: BSD mktemp treats a suffix after the X's literally, so the name is fixed.
tmp="$(mktemp "${TMPDIR:-/tmp}/pii-sweep.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

echo "== gitleaks (current tree; repo .gitleaks.toml if present) =="
# gitleaks exits 1 on an error as well as on leaks, so leaks get their own code (3). An error
# must be exit 2 here, never read as findings or as clean.
rc=0
gitleaks dir . --no-banner --redact --exit-code 3 -f json -r "$tmp" >/dev/null 2>&1 || rc=$?
case "$rc" in
0) echo "  clean" ;;
3)
  jq -r '.[] | "\(.File):\(.StartLine) [\(.RuleID)] \(.Match)"' "$tmp"
  found=1
  ;;
*)
  echo "gitleaks failed (exit $rc)" >&2
  exit 2
  ;;
esac

echo "== personal PII (runtime-sourced) =="
EMAIL="$(git config user.email || true)"
NAME="$(git config user.name || true)"
# ENC[ hits are SOPS-encrypted = fine; exclude .git
pii_grep() { # pattern-args...
  grep -rn --exclude-dir=.git "$@" . 2>/dev/null | grep -v 'ENC\[' || true
}
hits=""
# if-not-&&: a false `[ -n ]` in an &&-list statement trips set -e
if [ -n "$EMAIL" ]; then hits+="$(pii_grep -F "$EMAIL")"$'\n'; fi
if [ -n "$NAME" ]; then hits+="$(pii_grep -F "$NAME")"$'\n'; fi
hits+="$(pii_grep -E '[a-zA-Z0-9._%+-]+@(gmail|outlook|yahoo|proton)' | grep -vE 'example|your_' || true)"
hits="$(printf '%s' "$hits" | grep -v '^$' || true)" # strip blank lines BEFORE the -n test — else newline-only = false findings
if [ -n "$hits" ]; then
  printf '%s\n' "$hits" | sort -u
  found=1
else
  echo "  clean"
fi

exit "$found"
