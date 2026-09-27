# GitHub Workflows

This folder holds six workflows. CI is a signal, not a merge gate: the repo is private on GitHub's
Free plan, which has no branch protection, and Flux applies `main` whatever CI reports. No Actions
job has started since 2026-09-10, because of a billing problem on the account, so today none of
these workflows runs.

| Workflow | Runs on | Does |
|---|---|---|
| `validate.yaml` | push to `main`, pull requests to `main`, by hand; skips pushes that change only Markdown or `docs/images/` | the checks below |
| `gitleaks.yaml` | push to `main`, pull requests to `main`, by hand; no path filter | secret scan |
| `renovate-analysis.yaml` | pull request opened, updated or reopened; runs only for Renovate | posts a version-change analysis on the PR |
| `claude.yml` | `@claude` in an issue, a comment or a PR review | runs Claude Code on the request |
| `flux-update.yaml` | Sunday 06:00 UTC, or by hand | opens a PR to update the Flux components |
| `claude-telegram-build.yml` | Monday and Thursday 23:00 UTC, or by hand | builds and pushes the Telegram bot image |

## validate.yaml

| Job | Checks | Script |
|---|---|---|
| `yamllint` | YAML syntax and style | `yamllint .` |
| `shellcheck` | shell scripts across the repo | inline |
| `sops-check` | every Secret manifest is SOPS-encrypted | `scripts/ci/check-sops-encrypted.sh` |
| `init-resources` | every init container sets resource limits | `scripts/ci/check-init-resources.sh` |
| `image-pin` | every image is pinned to `major.minor.patch`; the script holds a small allowlist | `scripts/ci/image-pin-audit.sh` |
| `kubeconform` | manifest schemas in all seven Kustomize roots | inline |
| `homelab-analysis-drift` | key numbers in `docs/HOMELAB_ANALYSIS.md` still match the repo; warn-only (`continue-on-error: true`) | inline |
| `helm-render` | every HelmRelease chart renders at its pinned version; kubeconform checks only the HelmRelease resource, not the chart's templates | `scripts/ci/helm-render-check.sh` |

## gitleaks.yaml

It is separate from `validate.yaml` on purpose. `validate.yaml` skips Markdown-only pushes, so while
gitleaks lived there, a credential pasted into a runbook or plan reached `main` unscanned (the
workflow's header comment). The scan takes about 15 seconds, so it has no path filter. It scans the same events as `validate.yaml`; pushes to
other branches are scanned by neither.

## renovate-analysis.yaml

For each Renovate pull request, it runs `scripts/analyze-update-gh.sh` and posts or updates one PR
comment. It runs only if the actor is `renovate[bot]`.

| It reports | It does not |
|---|---|
| the package (Docker image, Helm chart or Flux component) | review code quality |
| the version change and whether it is major, minor or patch, with a risk level | check syntax or formatting |
| known breaking changes for that package, and links to the release notes | analyse app logic |

Example comment:

```markdown
## Version Change Analysis

> **Note**: This analyzes version changes and breaking changes, not code quality.

<details>
<summary>Click to expand full analysis</summary>

Package: ghcr.io/goauthentik/server
Update Type: minor
Version Change: v2025.10.0 → v2025.11.0
Update Category: Docker Image in Kubernetes resource

MINOR UPDATE - Medium risk

Authentik Update
Check for:
  - Authentication flow changes
  - OAuth/OIDC provider changes
  - Database schema migrations
  - Redis/cache configuration changes

Action items:
  1. Review release notes for breaking changes
  2. Test login flows after deployment
  [...]
</details>
```

| Permission | Why |
|---|---|
| `pull-requests: write` | post the comment |
| `contents: read` | check out the repo |

Run it by hand:

```bash
# Analyze specific Renovate PR
./scripts/analyze-update.sh <PR_NUMBER>

# Generate GitHub-formatted output
./scripts/analyze-update-gh.sh <PR_NUMBER>
```

To add checks for a package, edit `scripts/analyze-update.sh` and add a case to its package
section:

```bash
case "$PACKAGE_NAME" in
    *your-package*)
        echo "Your Package Update"
        echo "Check for:"
        echo "  - Specific breaking changes"
        echo "  - Configuration updates"
        echo ""
        echo "Action items:"
        echo "  1. Review release notes"
        echo "  2. Test functionality"
        ;;
esac
```

| It already covers |
|---|
| Authentik, Grafana, the Prometheus stack |
| Flux, Traefik, External-DNS |
| PostgreSQL, Redis |
| n8n, Paperless, Immich, Home Assistant |

A change to the script applies to the next run.

| Problem | Check |
|---|---|
| The analysis does not run | the PR author is `renovate[bot]` or `app/renovate`; the run in Actions → Renovate Version Change Analysis; its logs |
| No comment appears | the run finished green; `GITHUB_TOKEN` has `pull-requests: write`; the scripts are executable; the "Post comment on PR" step's log |
| The analysis is out of date | push to the PR branch, which re-runs it and updates the comment |

## claude.yml

It runs `anthropics/claude-code-action` when `@claude` appears in:

| Event | Condition |
|---|---|
| an issue comment, including a comment on a PR | any author |
| a PR review comment, or a PR review | the actor is not Renovate (`github.actor != 'renovate[bot]'`) |
| a new or assigned issue (title or body) | a plain issue, or an actor other than Renovate |

Its job token can read contents, pull requests and issues. The action also requests `actions: read` through `additional_permissions`, to read CI results. Claude reads the repo files and runs a limited set of `gh` commands. For example:

```
@claude can you explain how this authentication flow works?
```

```
@claude what does this function do?
```

## flux-update.yaml

Every Sunday it reads the `Flux Version:` line in `clusters/flux-system/gotk-components.yaml` and
the version of the Flux CLI that the `fluxcd/flux2/action` step installs. If they differ, it
regenerates the file with `flux install --export` and opens a pull request whose body links the
release notes.

## claude-telegram-build.yml

It checks out the bot's own repository (`AKhozya/claude-telegram-bot`), builds a `linux/amd64`
image, pushes it to `ghcr.io/akhozya/claude-telegram-bot` with the next patch version (or the
version given by hand), and pushes a matching `claude-telegram-v<version>` tag to this repo. The
cluster runs whatever tag `apps/claude-telegram/deployment.yaml` pins, so a new image goes live only
through a commit that bumps it.
