# GitHub Workflows

## Overview

This repository uses three GitHub Action workflows to manage automated reviews and analysis:

1. **renovate-analysis.yaml** - Automated analysis of Renovate dependency updates
2. **claude-code-review.yml** - Claude-powered code review for regular PRs
3. **claude.yml** - Interactive Claude responses via @claude mentions

**Renovate Detection**: All workflows use **actor-based detection** (`github.actor == 'renovate[bot]'`) instead of title matching for more reliable filtering.

---

## Renovate PR Analysis

**Workflow**: `renovate-analysis.yaml`

### What it does

Automatically analyzes every Renovate PR and posts a comment with:
- Package name and version change
- Update type (major/minor/patch) and risk level
- Package-specific guidance (Authentik, Flux, Traefik, etc.)
- Breaking changes checklist
- Action items before and after merge
- Quick merge commands

### How it works

1. **Trigger**: Runs when a PR is opened, synchronized, or reopened
2. **Filter**: Only runs for PRs created by `renovate[bot]`
3. **Analysis**: Executes `scripts/analyze-update-gh.sh`
4. **Comment**: Posts or updates a comment on the PR with the analysis

### Example Output

The workflow posts a collapsible comment like this:

```markdown
## 🔍 Automated Update Analysis

<details>
<summary>📋 Click to expand full analysis</summary>

[Full analysis output with version changes, risk assessment, and action items]

</details>

### Quick Actions

**Merge this PR:**
```bash
gh pr merge 123 --squash
```
```

### Permissions Required

The workflow needs these permissions (already configured):
- `pull-requests: write` - To post comments
- `contents: read` - To checkout the repository

### Manual Testing

You can test the analysis script locally:

```bash
# Analyze a specific PR
./scripts/analyze-update.sh <PR_NUMBER>

# Generate GitHub-formatted output
./scripts/analyze-update-gh.sh <PR_NUMBER>
```

### Customization

To add package-specific analysis:
1. Edit `scripts/analyze-update.sh`
2. Add a new case in the package analysis section
3. Define what to check and action items
4. Commit and push - workflow uses the latest script version

### Troubleshooting

**Workflow not running?**
- Check that the PR author is `renovate[bot]`
- View workflow runs: Actions → Renovate PR Analysis

**Comment not appearing?**
- Check workflow logs for errors
- Verify `GITHUB_TOKEN` has write permissions
- Ensure the script is executable in the repository

**Need to update an existing comment?**
- Push changes to the PR branch
- Workflow will automatically update its comment

---

## Claude Code Review

**Workflow**: `claude-code-review.yml`

### What it does

Automatically reviews **non-Renovate PRs** when they're opened or updated using Claude Code.

**Reviews include:**
- Code quality and best practices
- Potential bugs or issues
- Performance considerations
- Security concerns
- Test coverage

**Exclusions:**
- ❌ Renovate PRs (handled by renovate-analysis.yaml)
- ✅ All other PRs get automatic review

### How it works

1. PR opened/synchronized by any author except Renovate
2. Checks `github.actor` to skip Renovate
3. Runs Claude Code review with repository context
4. Posts review as PR comment using `gh pr comment`

---

## Claude Interactive

**Workflow**: `claude.yml`

### What it does

Responds to **@claude mentions** in:
- Issue comments
- PR review comments
- PR reviews
- New issues

**Exclusions:**
- ❌ @claude mentions on Renovate PRs are ignored
- ✅ @claude works everywhere else

### How to use

Simply mention `@claude` in a comment with your request:

```
@claude can you explain how this authentication flow works?
```

```
@claude please review the error handling in this PR
```

**Note**: Claude has access to repository files and can run limited commands via `gh` CLI.

---

## Workflow Coordination

| Event | Renovate PR | Regular PR |
|-------|-------------|------------|
| **PR opened** | renovate-analysis.yaml runs | claude-code-review.yml runs |
| **PR updated** | renovate-analysis.yaml updates comment | claude-code-review.yml runs |
| **@claude mention** | ❌ Ignored | claude.yml responds |
| **Issue created** | N/A | claude.yml responds if @claude |

All workflows use consistent **actor-based detection** to identify Renovate PRs.
