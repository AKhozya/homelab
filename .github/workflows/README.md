# GitHub Workflows

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
