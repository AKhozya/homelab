# GitHub Workflows

## Overview

Two workflows:

1. **renovate-analysis.yaml** — Renovate version change analysis
2. **claude.yml** — @claude mention responder

**Important:** NO auto code reviews. Renovate workflow detects version + breaking changes only.

---

## Renovate Version Change Analysis

**Workflow:** `renovate-analysis.yaml`

### What it does

Analyzes version changes in Renovate PRs, posts analysis:

**Detects:**
- Package: Docker image, Helm chart, Flux component
- Version change: old → new
- Update type: major/minor/patch + risk level
- Package-specific breaking changes
- Links to release notes

**Does NOT:**
- Code quality review
- Syntax/formatting check
- App logic analysis

### How it works

1. **Trigger:** Renovate PR opened/updated
2. **Filter:** `github.actor == 'renovate[bot]'`
3. **Analysis:** Runs `scripts/analyze-update-gh.sh`
4. **Output:** Posts/updates PR comment

### Example Output

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

### Permissions Required

- `pull-requests: write` — post comments
- `contents: read` — checkout

### Manual Testing

```bash
# Analyze specific Renovate PR
./scripts/analyze-update.sh <PR_NUMBER>

# Generate GitHub-formatted output
./scripts/analyze-update-gh.sh <PR_NUMBER>
```

### Customization

Add package-specific analysis:
1. Edit `scripts/analyze-update.sh`
2. Add new case in package analysis section (line ~110)
3. Define checks + action items
4. Commit + push — workflow uses latest

---

## Claude Interactive

**Workflow:** `claude.yml`

### What it does

Responds to **@claude mentions** in:
- Issue comments
- PR review comments (except Renovate PRs)
- PR reviews (except Renovate PRs)
- New issues

### Exclusions

- @claude on Renovate PRs ignored (version analysis instead)
- @claude works everywhere else

### Usage

Mention `@claude` in comment:

```
@claude can you explain how this authentication flow works?
```

```
@claude what does this function do?
```

**Note:** Claude reads repo files, runs limited `gh` CLI.

---

## Workflow Coordination

| Event | Renovate PR | Regular PR | Issue |
|-------|-------------|------------|-------|
| **Opened/Updated** | Version analysis posted | No auto action | N/A |
| **@claude mention** | Ignored | Claude responds | Claude responds |

**Renovate detection:** Both workflows use `github.actor == 'renovate[bot]'`.

---

## Disabled Workflows

### claude-code-review.yml.disabled

**Why disabled:** Avoid auto code reviews on all PRs. Repo focus:
- Version change analysis (Renovate)
- Manual @claude when needed

**Re-enable:** Rename `.disabled` → `.yml`, adjust conditions.

---

## Troubleshooting

### Renovate Analysis Not Running?

**Check:**
1. PR author = `renovate[bot]` or `app/renovate`
2. Workflow runs: Actions → Renovate Version Change Analysis
3. Workflow logs for errors

### Comment Not Appearing?

**Check:**
1. Workflow completed (green check)
2. `GITHUB_TOKEN` has pull-requests write
3. Scripts executable
4. Error in "Post comment on PR" step

### Update Analysis?

**Options:**
1. Push to PR branch → workflow auto-updates comment
2. Edit `scripts/analyze-update.sh` → affects future PRs
3. Manual: `./scripts/analyze-update-gh.sh <PR_NUMBER>`

---

## Adding New Package Analysis

Edit `scripts/analyze-update.sh`, add case:

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

Common packages covered:
- Authentik, Grafana, Prometheus Stack
- Flux, Traefik, External-DNS
- PostgreSQL, Redis
- n8n, Paperless, Immich, Home Assistant

---

## Summary

**Active:** 2
- Renovate version analysis (auto)
- @claude mentions (manual)

**Disabled:** 1
- Claude code review (not needed)

**Focus:** Version + breaking change detection, not code review.
