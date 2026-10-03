# GitHub Workflows

This folder holds four workflows. The secret scan is the only required check:

| Fact (2026-10-03) | Effect |
|---|---|
| The `main` ruleset requires a PR with 1 approval and a successful `gitleaks secret scan` | if the owner does not use the bypass, a PR merges only after the owner approves it and the scan succeeds |
| The repo admin role bypasses the ruleset | GitHub accepts the owner's direct pushes and merges without an approval or a finished scan. The scan still runs on each push |
| No rule requires the Validate checks | if they fail, a commit can still reach `main` |
| Flux applies `main` every few minutes | a commit with failed checks still deploys |

If an outside contributor opens a PR from a fork, GitHub runs its workflows only after the owner approves the run.

| Workflow | Runs on | Does |
|---|---|---|
| `validate.yaml` | push to `main`, pull requests to `main`, by hand; skips pushes that change only Markdown or `docs/images/` | the checks below |
| `gitleaks.yaml` | push to `main`, pull requests to `main`, by hand; no path filter | secret scan |
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

## flux-update.yaml

Every Sunday it reads the `Flux Version:` line in `clusters/flux-system/gotk-components.yaml` and
the version of the Flux CLI that the `fluxcd/flux2/action` step installs. If they differ, it
regenerates the file with `flux install --export` and opens a pull request whose body links the
release notes. It opens the pull request with the repo secret `FLUX_UPDATE_TOKEN`, a fine-grained
PAT for this repo with Contents and Pull requests write. If the secret is absent, the run fails:

| Why not `GITHUB_TOKEN` | Effect |
|---|---|
| the repo setting that lets Actions create pull requests is off since 2026-09-28 | the API refuses the pull request |
| GitHub starts no workflows for a pull request opened with `GITHUB_TOKEN` | `validate.yaml` would not run on it |

## claude-telegram-build.yml

It checks out the bot's own repository (`AKhozya/claude-telegram-bot`), builds a `linux/amd64`
image, pushes it to `ghcr.io/akhozya/claude-telegram-bot` with the next patch version (or the
version given by hand), and pushes a matching `claude-telegram-v<version>` tag to this repo. If
that git tag or that image tag already exists, it stops before the build. The
cluster runs whatever tag `apps/claude-telegram/deployment.yaml` pins, so a new image goes live only
through a commit that bumps it.
