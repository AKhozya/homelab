# Renovate Update Review Process

## Configuration Changes (2025-10-29)

Auto-merge **disabled**. Minor/patch/major updates need manual review + approval.

**File**: `renovate.json`
**Changes**: removed `automerge: true` + `automergeType: "branch"`

---

## Automated Version Change Detection

**GitHub Action**: `.github/workflows/renovate-analysis.yaml`

Every Renovate PR gets **automatic version change analysis** (NOT code review):

**Detects:**
- What changed: Docker image, Helm chart, Flux component
- Version: old → new
- Type: major/minor/patch
- Package-specific breaking changes
- Release notes links

**Does NOT do:**
- Code quality review
- Syntax check
- App logic analysis

**Manual analysis**:
```bash
./scripts/analyze-update.sh <PR_NUMBER>
./scripts/analyze-update-gh.sh <PR_NUMBER>  # GitHub-formatted
```

See [Workflow Documentation](../.github/workflows/README.md).

---

## Recent Updates Analysis

### Update Types & Review Guidelines

#### Patch Updates (Low Risk)
**Example**: n8n v1.118.0 → v1.118.1

**Review**:
- Check PR description — bug fixes/security patches
- Review changed files (usually version number)
- Verify readiness probes configured
- Monitor logs post-deploy

**Action**: safe to merge after quick review

---

#### Minor Updates (Medium Risk)
**Examples**:
- Authentik v2025.8.4 → v2025.10.0
- busybox v1.36 → v1.37

**Review**:
- Release notes — features + breaking changes
- Config changes required
- Test in staging if available
- Verify integrations
- App docs for migration steps

**Action**:
1. **Authentik**: review auth flows + provider configs
2. **Check logs** for deprecated features/warnings
3. **Test login flows** post-deploy
4. **Monitor metrics** for auth errors

---

#### Major Updates (High Risk)
**Examples**:
- Node.js v22 → v24
- kube-prometheus-stack v78 → v79

**Review**:
- **CRITICAL**: read full changelog + migration guide
- Breaking changes carefully
- Test before prod
- Rollback plan ready
- Deprecated APIs/features

**Action**:

##### Node.js v22 → v24
- Node.js 24 [release notes](https://nodejs.org/en/blog/release/v24.9.0)
- Notable changes:
  - util.getCallSite removed (SEMVER-MINOR breaking)
  - New SQLite authorization API
  - HTTP upgrade callback support
- **Impact**: apps using removed APIs need updates
- **Testing**: full test suite before deploy

##### kube-prometheus-stack v78 → v79
- **SECURITY FIX**: insecure default password in Grafana
- **Action**: update Grafana password immediately after apply
- **Review**: custom Grafana configs affected
- **Testing**: verify dashboards + alerts post-upgrade

---

#### Infrastructure Updates (Critical)
**Example**: Flux v2.7.2 → v2.7.3

**Components Updated**:
- helm-controller v1.4.2 → v1.4.3
- kustomize-controller v1.7.1 → v1.7.2
- notification-controller v1.7.3 → v1.7.4
- source-controller v1.7.2 → v1.7.3

**Review**:
- All controller changelogs
- Reconciliation behavior changes
- Monitor flux-system ns post-update
- Verify all GitOps reconciliations succeed

**Action**:
1. Apply during maintenance window
2. Monitor: `flux get all --all-namespaces`
3. Controller logs: `kubectl logs -n flux-system -l app=<controller>`
4. Verify reconciliation status for all apps

---

## GitHub PR Review Workflow

### Manual Review
1. **Open PR in GitHub**
2. **Review**: files changed + PR description
3. **CI/CD**: checks pass
4. **Merge**: "Squash and merge" or "Rebase and merge"
5. **Monitor**: Flux reconciles

### GitHub PR Override (Bypass Reviews)

**Note**: Repo admins can bypass branch protection

**Enable PR merge without reviews**:
1. Repo **Settings** → **Branches**
2. Edit branch protection for `main`
3. "Require approvals" → **0**
4. Or "Allow specified actors to bypass required pull requests"
5. Add username to bypass list

**Current**: reviews required for quality control

**Alternative**: GitHub CLI merge without reviews:
```bash
# Merge a PR directly (requires admin permissions)
gh pr merge <number> --squash --auto
```

---

## Quick Merge Commands

### Review + Merge Renovate PR
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

### High (Apply ASAP)
- Security patches
- Critical bug fixes
- Flux/infra updates

### Medium (Review within 3 days)
- Minor version updates
- Feature releases
- Dependency updates

### Low (Review weekly)
- Patch updates
- Docs updates
- Dev dependency updates

---

## Rollback Procedure

Update cause issues:

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

### App Health
```bash
# Check pod status
kubectl get pods -n <namespace>

# Check logs
kubectl logs -n <namespace> -l app=<app-name> --tail=100

# Check readiness
kubectl get pods -n <namespace> -o wide
```

### Metrics
- Monitor Grafana dashboards
- Check Prometheus alerts
- Review app-specific metrics

---

## Next Steps

1. Auto-merge disabled
2. Review open Renovate PRs
3. Merge safe updates (patches) first
4. Test major updates in staging
5. Document issues found

---

## References

- [Renovate Documentation](https://docs.renovatebot.com/)
- [Flux Documentation](https://fluxcd.io/docs/)
- [GitHub Branch Protection](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)