# GitHub Workflows

This folder holds six workflows. CI is a signal, not a merge gate:

| Fact (2026-09-28) | Effect |
|---|---|
| No ruleset or branch protection guards `main` | a commit reaches `main` whatever CI reports |
| GitHub offers neither on a private Free-plan repo; a public repo gets both for free | a ruleset becomes possible once the repo is public |
| Flux applies `main` every few minutes | a red commit on `main` still deploys |
| Account billing stopped every Actions job from 2026-09-10 | the workflows run again since 2026-10-01 (first green run 17:18Z) |

| Workflow | Runs on | Does |
|---|---|---|
| `validate.yaml` | push to `main`, pull requests to `main`, by hand; skips pushes that change only Markdown or `docs/images/` | the checks below |
| `gitleaks.yaml` | push to `main`, pull requests to `main`, by hand; no path filter | secret scan |
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

## claude.yml

It runs `anthropics/claude-code-action` only if the actor is the repo owner (`github.actor ==
'AKhozya'`) and `@claude` appears in one of these:

| Event | Where `@claude` must appear |
|---|---|
| a new issue comment, including a comment on a PR | the comment body |
| a new PR review comment | the comment body |
| a submitted PR review | the review body |
| a newly opened issue | the title or the body |

If an issue is assigned, the workflow does not run. Otherwise the owner assigning someone else's
issue would pass that person's text to Claude. The owner check also excludes Renovate.

Its job token can read contents, pull requests and issues. The action also requests `actions: read`
through `additional_permissions`, to read CI results. The workflow sets no `claude_args`, so Claude
runs with the action's default tool set. For example:

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
