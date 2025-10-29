# GitHub Workflows

## Overview

This repository uses **two GitHub Action workflows**:

1. **renovate-analysis.yaml** - Automated version change analysis for Renovate dependency updates
2. **claude.yml** - Interactive Claude responses via @claude mentions

**Important**: This setup does **NOT** include automatic code reviews. The Renovate workflow detects version changes and breaking changes only.

---

## Renovate Version Change Analysis

**Workflow**: `renovate-analysis.yaml`

### What it does

Automatically analyzes **version changes** in Renovate PRs and posts detailed analysis:

**Detects:**
- 📦 What changed: Docker image, Helm chart, or Flux component
- 📊 Version change: old → new
- 🎯 Update type: major/minor/patch and risk level
- 🚨 Package-specific breaking changes to review
- 📝 Links to release notes and changelogs

**Does NOT:**
- ❌ Review code quality
- ❌ Check syntax or formatting
- ❌ Analyze application logic

### How it works

1. **Trigger**: Runs when Renovate PRs are opened/updated
2. **Filter**: Only runs for `github.actor == 'renovate[bot]'`
3. **Analysis**: Executes `scripts/analyze-update-gh.sh`
4. **Output**: Posts or updates a comment with version analysis

### Example Output

```markdown
## 🔄 Version Change Analysis

> **Note**: This analyzes version changes and breaking changes, not code quality.

<details>
<summary>📋 Click to expand full analysis</summary>

Package: ghcr.io/goauthentik/server
Update Type: minor
Version Change: v2025.10.0 → v2025.11.0
Update Category: Docker Image in Kubernetes resource

🟡 MINOR UPDATE - Medium risk

🔐 Authentik Update
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

- `pull-requests: write` - To post analysis comments
- `contents: read` - To checkout the repository

### Manual Testing

Test the analysis script locally:

```bash
# Analyze a specific Renovate PR
./scripts/analyze-update.sh <PR_NUMBER>

# Generate GitHub-formatted output
./scripts/analyze-update-gh.sh <PR_NUMBER>
```

### Customization

To add package-specific analysis:
1. Edit `scripts/analyze-update.sh`
2. Add a new case in the package analysis section (line ~110)
3. Define what to check and action items
4. Commit and push - workflow uses the latest version

---

## Claude Interactive

**Workflow**: `claude.yml`

### What it does

Responds to **@claude mentions** in:
- Issue comments
- PR review comments (except Renovate PRs)
- PR reviews (except Renovate PRs)
- New issues

### Exclusions

- ❌ @claude mentions on Renovate PRs are ignored (use version analysis instead)
- ✅ @claude works everywhere else

### How to use

Mention `@claude` in a comment with your request:

```
@claude can you explain how this authentication flow works?
```

```
@claude what does this function do?
```

**Note**: Claude has access to repository files and can run limited `gh` CLI commands.

---

## Workflow Coordination

| Event | Renovate PR | Regular PR | Issue |
|-------|-------------|------------|-------|
| **Opened/Updated** | ✅ Version analysis posted | ❌ No automatic action | N/A |
| **@claude mention** | ❌ Ignored | ✅ Claude responds | ✅ Claude responds |

**Renovate Detection**: Both workflows use `github.actor == 'renovate[bot]'` for consistent filtering.

---

## Disabled Workflows

### claude-code-review.yml.disabled

**Why disabled**: To avoid automatic code reviews on all PRs. The repository focuses on:
- Version change analysis for dependencies (Renovate)
- Manual @claude interactions when needed

**To re-enable**: Rename from `.disabled` to `.yml` and adjust the workflow conditions as needed.

---

## Troubleshooting

### Renovate Analysis Not Running?

**Check:**
1. PR author is `renovate[bot]` or `app/renovate`
2. View workflow runs: Actions → Renovate Version Change Analysis
3. Check workflow logs for errors

### Comment Not Appearing?

**Check:**
1. Workflow completed successfully (green checkmark)
2. `GITHUB_TOKEN` has write permissions to pull-requests
3. Scripts are executable in the repository
4. Look for error in "Post comment on PR" step

### Need to Update Analysis?

**Options:**
1. Push changes to PR branch → workflow auto-updates comment
2. Edit `scripts/analyze-update.sh` → affects future PRs
3. Manually run: `./scripts/analyze-update-gh.sh <PR_NUMBER>`

---

## Adding New Package Analysis

Edit `scripts/analyze-update.sh` and add a case:

```bash
case "$PACKAGE_NAME" in
    *your-package*)
        echo "📦 Your Package Update"
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

Common packages already covered:
- Authentik, Grafana, Prometheus Stack
- Flux, Traefik, External-DNS
- PostgreSQL, Redis
- n8n, Paperless, Immich, Home Assistant

---

## Summary

**Active Workflows:** 2
- ✅ Renovate version analysis (automatic)
- ✅ @claude mentions (manual)

**Disabled Workflows:** 1
- ❌ Claude code review (not needed)

**Focus:** Detecting version changes and breaking changes in dependencies, not code review.
