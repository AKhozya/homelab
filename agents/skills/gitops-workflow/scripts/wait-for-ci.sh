#!/usr/bin/env bash
# wait-for-ci.sh [sha] [branch] — gitops-workflow §3c gate, scripted.
# Run right after `git push`, before `fr`: resolves the validate.yaml run for the pushed
# SHA (retries — Actions takes a few seconds to register the run), blocks until it
# finishes, then hands the verdict to _shared/ci-red-classify.sh.
#
# Why: the manual version of this loop grabs "the latest run" by eye — which races with
# a neighbouring push and reads the WRONG run — and the infra-vs-content classify step
# gets skipped under pressure. Defaults: sha=HEAD of cwd repo, branch=main.
#
# Exit (ci-red-classify taxonomy): 0 GREEN → fr | 10 CONTENT-RED → block, fix manifest
#   | 11 INFRA-RED → peer+local gate of record, proceed | 5 PENDING (watch died early —
#   re-run) | 3 no-run/tooling | 2 misuse
set -euo pipefail

sha="${1:-$(git rev-parse HEAD 2>/dev/null)}"
branch="${2:-main}"
[ -n "$sha" ] || {
  echo "usage: wait-for-ci.sh [sha] [branch]   (default: HEAD, main — run inside the repo)" >&2
  exit 2
}
command -v gh >/dev/null || {
  echo "need gh CLI" >&2
  exit 3
}

CLASSIFY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_shared" && pwd)/ci-red-classify.sh"
[ -x "$CLASSIFY" ] || {
  echo "ci-red-classify.sh not found at $CLASSIFY" >&2
  exit 3
}

# 1) Resolve the run for THIS sha (not "latest" — that races with neighbouring pushes).
id=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  id="$(gh run list --workflow=validate.yaml --branch "$branch" --limit 15 \
    --json databaseId,headSha \
    --jq "map(select(.headSha | startswith(\"$sha\")))[0].databaseId // empty" 2>/dev/null || true)"
  [ -n "$id" ] && break
  sleep 5
done
if [ -z "$id" ]; then
  echo "no validate.yaml run appeared for sha ${sha:0:8} on $branch after 60s" >&2
  echo "(validate.yaml runs on every push to main; check gh run list --workflow=validate.yaml --limit 3)" >&2
  exit 3
fi

# 2) Block until it finishes (rc ignored — classify below makes the call).
echo "watching run $id for sha ${sha:0:8} …"
gh run watch "$id" --exit-status >/dev/null 2>&1 || true

# 3) Verdict.
exec "$CLASSIFY" "$branch" "$sha"
