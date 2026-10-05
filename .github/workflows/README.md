# GitHub Workflows

This folder holds four workflows. The ruleset requires two checks:

| Fact (2026-10-05) | Effect |
|---|---|
| The `main` ruleset requires a PR whose `gitleaks secret scan` and `ci-ok` checks succeed. It requires no approval | a PR merges only after both checks succeed |
| The ruleset has no bypass actor | nobody, the owner included, can push to `main` directly or merge a PR before its checks succeed |
| The ruleset allows merge commits only, and blocks force pushes and branch deletion | the rules bind everyone, including Renovate and any app token |
| A branch need not be up to date with `main` before it merges | the checks run on GitHub's test merge with `main` as it was then. If `main` moves after that, only the merge commit's own run on `main` checks the combined result |
| Flux applies `main` every few minutes | if the merge commit's run fails, that commit still deploys |

If an outside contributor opens a PR from a fork, GitHub runs its workflows only after the owner approves the run.

| Workflow | Runs on | Does |
|---|---|---|
| `validate.yaml` | push to `main`, pull requests to `main`, by hand | the checks below |
| `gitleaks.yaml` | push to `main`, pull requests to `main`, by hand; no path filter | secret scan |
| `flux-update.yaml` | Sunday 06:00 UTC, or by hand | opens a PR to update the Flux components |
| `claude-telegram-build.yml` | Monday and Thursday 23:00 UTC, or by hand | builds and pushes the Telegram bot image |

## validate.yaml

| Job | Checks | Script |
|---|---|---|
| `yamllint` | YAML syntax and style | `yamllint .` |
| `shellcheck` | shell scripts across the repo | inline |
| `node-script-tests` | offline tests for the node-maintenance scripts | three `test-*.sh` scripts under `node-maintenance/**/tests/` |
| `sops-check` | every Secret manifest is SOPS-encrypted | `scripts/ci/check-sops-encrypted.sh` |
| `init-resources` | every init container sets resource limits | `scripts/ci/check-init-resources.sh` |
| `image-pin` | every image is pinned to `major.minor.patch`; the script holds a small allowlist | `scripts/ci/image-pin-audit.sh` |
| `kubeconform` | manifest schemas in all seven Kustomize roots | inline |
| `homelab-analysis-drift` | key numbers in `docs/HOMELAB_ANALYSIS.md` still match the repo; warn-only (`continue-on-error: true`) | inline |
| `helm-render` | every HelmRelease chart renders at its pinned version; kubeconform checks only the HelmRelease resource, not the chart's templates | `scripts/ci/helm-render-check.sh` |
| `ci-ok` | every job above except `homelab-analysis-drift` succeeded; the ruleset requires this check | inline |

## gitleaks.yaml

The ruleset requires the check name `gitleaks secret scan`. If you rename the job, update the
ruleset in the same change. It scans the same events as `validate.yaml`;
pushes to other branches are scanned by neither.

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
