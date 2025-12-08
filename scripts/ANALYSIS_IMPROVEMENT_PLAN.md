# Renovate Analysis Script Improvement Plan

## Research Summary

### Common Changelog Standards

Based on research from [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Common Changelog](https://common-changelog.org/):

**Standard File Names** (priority order):
1. `CHANGELOG.md` / `changelog.md`
2. `HISTORY.md` / `History.md`
3. `CHANGES.md` / `Changes.md`
4. `RELEASES.md` / `releases.md`
5. `NEWS.md` / `news.md`
6. `RELEASE_NOTES.md`

**Standard Section Names** (Keep a Changelog):
- `Added` - new features
- `Changed` - changes in existing functionality
- `Deprecated` - soon-to-be removed features
- `Removed` - now removed features
- `Fixed` - bug fixes
- `Security` - vulnerabilities

**Breaking Change Indicators** (from Conventional Commits):
- `BREAKING CHANGE:` in footer
- `!` after type/scope (e.g., `feat!:` or `feat(api)!:`)
- `**Breaking:**` prefix in Common Changelog
- Keywords: "breaking", "migration required", "action required"

### Helm Chart Specific

Some Helm charts maintain:
- `UPGRADE.md` - migration/upgrade steps
- `BREAKING_CHANGES.md` - dedicated breaking changes file (e.g., Elastic charts)

### How Renovate Works

Per [Renovate docs](https://docs.renovatebot.com/key-concepts/changelogs/):
1. Checks GitHub/GitLab "Releases" metadata first
2. Falls back to commonly known changelog file names
3. Case-insensitive matching
4. `.md` extension required

## Current Script Issues

1. **Bug**: `UPDATE_CATEGORY` used before defined (line 123 vs 217)
2. **Issue**: CHANGELOG.md blob URLs return HTML pages with JSON metadata
3. **Missing**: Multiple changelog file name search
4. **Missing**: UPGRADE.md content not displayed
5. **Missing**: GitHub release API for cleaner content
6. **Missing**: Version-specific section extraction

## Improvement Plan

### Phase 1: Fix Bugs (Immediate)
- [x] Move UPDATE_CATEGORY detection earlier in script
- [x] Fix blob URL to raw URL conversion

### Phase 2: Multi-Source Documentation Fetch
Priority order for fetching documentation:

1. **GitHub API Release** (cleanest)
   - URL: `https://api.github.com/repos/{owner}/{repo}/releases/tags/{tag}`
   - Returns `.body` field as markdown

2. **Raw Changelog Files** (in order)
   ```
   CHANGELOG.md, changelog.md
   HISTORY.md, history.md
   CHANGES.md, changes.md
   RELEASES.md, releases.md
   NEWS.md, news.md
   ```

3. **Helm-Specific Files**
   - `UPGRADE.md` for kube-prometheus-stack and similar
   - `BREAKING_CHANGES.md` for Elastic charts

4. **Fallback: GitHub Compare Diff**
   - Parse commit messages for breaking change indicators

### Phase 3: Better Breaking Change Detection
Search for these patterns:
- `BREAKING CHANGE:` (conventional commits)
- `**Breaking:**` (common changelog)
- `!:` after commit type
- Section headers containing "breaking"
- `migration required`, `action required`
- `removed`, `deprecated` sections
- CRD changes for Kubernetes resources

### Phase 4: Version-Specific Extraction
For CHANGELOG.md files with multiple versions:
- Extract only the section for NEW_VERSION
- Parse from `## [version]` to next version header
- Handle anchor links like `#v010771`

## Test Cases

Test against these recent PRs:
- PR 208: AdGuard Home (CHANGELOG.md with anchor)
- PR 207: kube-prometheus-stack (UPGRADE.md needed)
- PR 197: Stirling PDF (GitHub releases)
- PR 205: n8n (GitHub releases)

## Implementation Order

1. Fix UPDATE_CATEGORY bug
2. Add GitHub API release fetching
3. Add multi-file changelog search
4. Add Helm-specific UPGRADE.md support
5. Improve breaking change detection
6. Add version-specific section extraction
7. Test and compare results
