# Renovate Update Review Process

## Configuration Changes (2025-10-29)

Auto-merge has been **disabled** for all updates. All minor, patch, and major updates now require manual review and approval.

**Configuration file**: `renovate.json`
**Changes**: Removed `automerge: true` and `automergeType: "branch"` settings

---

## 🤖 Automated Analysis (NEW!)

**GitHub Action**: `.github/workflows/renovate-analysis.yaml`

Every Renovate PR now gets **automatic analysis** posted as a comment:
- ✅ Package name and version change
- ✅ Update risk level (major/minor/patch)
- ✅ Package-specific breaking changes to check
- ✅ Action items checklist
- ✅ Quick merge and monitoring commands

**Manual analysis** is still available:
```bash
./scripts/analyze-update.sh <PR_NUMBER>
./scripts/analyze-update-gh.sh <PR_NUMBER>  # GitHub-formatted
```

See [Workflow Documentation](.github/workflows/README.md) for details.

---

## Recent Updates Analysis

### Update Types & Review Guidelines

#### 🟢 Patch Updates (Low Risk)
**Example**: n8n v1.118.0 → v1.118.1

**Review Process**:
- ✅ Check PR description for bug fixes or security patches
- ✅ Review changed files (usually just version number)
- ✅ Verify deployment has readiness probes configured
- ✅ Monitor application logs after deployment

**Action Required**: Generally safe to merge after quick review

---

#### 🟡 Minor Updates (Medium Risk)
**Examples**:
- Authentik v2025.8.4 → v2025.10.0
- busybox v1.36 → v1.37

**Review Process**:
- ⚠️ Review release notes for new features and breaking changes
- ⚠️ Check for configuration changes required
- ⚠️ Test in staging if available
- ⚠️ Verify all integrations still work
- ⚠️ Check application-specific documentation for migration steps

**Action Required**:
1. **Authentik**: Review authentication flows and provider configurations
2. **Check logs** for deprecated features or warnings
3. **Test login flows** after deployment
4. **Monitor metrics** for authentication errors

---

#### 🔴 Major Updates (High Risk)
**Examples**:
- Node.js v22 → v24
- kube-prometheus-stack v78 → v79

**Review Process**:
- 🚨 **CRITICAL**: Read full changelog and migration guide
- 🚨 Review breaking changes carefully
- 🚨 Test thoroughly before applying to production
- 🚨 Have rollback plan ready
- 🚨 Check for deprecated APIs or features

**Action Required**:

##### Node.js v22 → v24
- Review Node.js 24 [release notes](https://nodejs.org/en/blog/release/v24.9.0)
- Notable changes:
  - util.getCallSite removed (SEMVER-MINOR breaking)
  - New SQLite authorization API
  - HTTP upgrade callback support
- **Impact**: Applications using removed APIs need updates
- **Testing**: Run full test suite before deployment

##### kube-prometheus-stack v78 → v79
- **SECURITY FIX**: Fixes insecure default password in Grafana
- **Action**: Update Grafana password immediately after applying
- **Review**: Check if custom Grafana configurations are affected
- **Testing**: Verify all dashboards and alerts work after upgrade

---

#### 🔧 Infrastructure Updates (Critical)
**Example**: Flux v2.7.2 → v2.7.3

**Components Updated**:
- helm-controller v1.4.2 → v1.4.3
- kustomize-controller v1.7.1 → v1.7.2
- notification-controller v1.7.3 → v1.7.4
- source-controller v1.7.2 → v1.7.3

**Review Process**:
- 🛠️ Review all controller changelogs
- 🛠️ Check for reconciliation behavior changes
- 🛠️ Monitor Flux system namespace after update
- 🛠️ Verify all GitOps reconciliations succeed

**Action Required**:
1. Apply update during maintenance window
2. Monitor with: `flux get all --all-namespaces`
3. Check controller logs: `kubectl logs -n flux-system -l app=<controller>`
4. Verify reconciliation status for all apps

---

## GitHub PR Review Workflow

### Manual Review Process
1. **Open PR in GitHub**
2. **Review Changes**: Check files changed and PR description
3. **Check CI/CD**: Ensure all checks pass
4. **Merge PR**: Use "Squash and merge" or "Rebase and merge"
5. **Monitor Deployment**: Watch Flux reconcile the changes

### Using GitHub PR Override (Bypass Reviews)

⚠️ **Note**: Repository administrators can bypass branch protection rules

**To enable PR merge without reviews**:
1. Go to repository **Settings** → **Branches**
2. Edit branch protection rule for `main`
3. Under "Require approvals", set to **0** approvals
4. Or check "Allow specified actors to bypass required pull requests"
5. Add your username to bypass list

**Current Setup**: Reviews are required for quality control

**Alternative**: Use GitHub CLI to merge without reviews:
```bash
# Merge a PR directly (requires admin permissions)
gh pr merge <number> --squash --auto
```

---

## Quick Merge Commands

### Review and Merge a Renovate PR
```bash
# View PR details
gh pr view <number>

# Review changes
gh pr diff <number>

# Merge PR
gh pr merge <number> --squash

# Force reconciliation (if needed)
flux reconcile source git flux-system --timeout 45s --force
flux reconcile kustomization apps --timeout 45s --force
```

### Automated Workflow
```bash
#!/bin/bash
# Review and merge Renovate PR

PR_NUMBER=$1
echo "Reviewing PR #$PR_NUMBER"

# Show PR details
gh pr view $PR_NUMBER

# Ask for confirmation
read -p "Merge this PR? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    gh pr merge $PR_NUMBER --squash
    echo "PR merged. Monitoring Flux reconciliation..."
    flux get kustomizations --watch
fi
```

---

## Update Priority Guidelines

### High Priority (Apply ASAP)
- Security patches
- Critical bug fixes
- Flux/infrastructure updates

### Medium Priority (Review within 3 days)
- Minor version updates
- Feature releases
- Dependency updates

### Low Priority (Review weekly)
- Patch updates
- Documentation updates
- Dev dependency updates

---

## Rollback Procedure

If an update causes issues:

```bash
# 1. Suspend Flux reconciliation
flux suspend kustomization <app-name>

# 2. Revert the commit
git revert <commit-hash>
git push

# 3. Resume reconciliation
flux resume kustomization <app-name>
flux reconcile kustomization <app-name> --timeout 45s --force

# 4. Verify rollback
kubectl get pods -n <namespace>
```

---

## Monitoring After Updates

### Check Application Health
```bash
# Check pod status
kubectl get pods -n <namespace>

# Check logs
kubectl logs -n <namespace> -l app=<app-name> --tail=100

# Check readiness
kubectl get pods -n <namespace> -o wide
```

### Check Metrics
- Monitor Grafana dashboards
- Check Prometheus alerts
- Review application-specific metrics

---

## Next Steps

1. ✅ Auto-merge disabled
2. ⏳ Review open Renovate PRs using this guide
3. ⏳ Merge safe updates (patches) first
4. ⏳ Test major updates in staging
5. ⏳ Document any issues found

---

## References

- [Renovate Documentation](https://docs.renovatebot.com/)
- [Flux Documentation](https://fluxcd.io/docs/)
- [GitHub Branch Protection](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)
