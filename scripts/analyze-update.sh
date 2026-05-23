#!/bin/bash
#
# Analyze Renovate PR - Detect Version Changes and Breaking Changes
#
# Usage: ./scripts/analyze-update.sh <PR_NUMBER>
#
# This script analyzes dependency updates (NOT code review):
# 1. Detects what changed: Docker image, Helm chart, or Flux component
# 2. Extracts version change (old → new)
# 3. Identifies update type: major/minor/patch
# 4. Fetches documentation from multiple sources (GitHub API, changelog files, UPGRADE.md)
# 5. Detects breaking changes using standard patterns
# 6. Generates actionable review checklist
#

set -eu
# Note: pipefail disabled to avoid SIGPIPE when awk exits early on large content

PR_NUMBER="${1:-}"

if [ -z "$PR_NUMBER" ]; then
    echo "Usage: $0 <PR_NUMBER>"
    echo ""
    echo "Example: $0 85"
    exit 1
fi

# Maximum content length to prevent GitHub comment overflow (65536 limit)
MAX_CONTENT_LENGTH=30000

echo "==================================="
echo "Analyzing Renovate PR #$PR_NUMBER"
echo "==================================="
echo ""

# Fetch PR details
echo "📥 Fetching PR details..."
PR_JSON=$(gh pr view "$PR_NUMBER" --json title,body,files,state)
PR_TITLE=$(echo "$PR_JSON" | jq -r '.title')
PR_BODY=$(echo "$PR_JSON" | jq -r '.body')
PR_STATE=$(echo "$PR_JSON" | jq -r '.state')

echo "Title: $PR_TITLE"
echo "State: $PR_STATE"
echo ""

# Extract package and version info from PR body or title
echo "📦 Extracting package information..."

# Try to extract from PR body table
PACKAGE_INFO=$(echo "$PR_BODY" | grep "^|" | grep -v "Package\|---" | head -n 1 || echo "")

if [ -n "$PACKAGE_INFO" ]; then
    # Parse from table format
    PACKAGE_NAME=$(echo "$PACKAGE_INFO" | awk -F'|' '{print $2}' | xargs | sed 's/\[//' | sed 's/\].*//')
    UPDATE_TYPE=$(echo "$PACKAGE_INFO" | awk -F'|' '{print $3}' | xargs)
    VERSION_CHANGE=$(echo "$PACKAGE_INFO" | awk -F'|' '{print $4}' | xargs)
    OLD_VERSION=$(echo "$VERSION_CHANGE" | awk '{print $1}' | sed 's/`//g' | sed 's/->.*//')
    NEW_VERSION=$(echo "$VERSION_CHANGE" | awk '{print $3}' | sed 's/`//g')
else
    # Fall back to parsing title
    PACKAGE_NAME=$(echo "$PR_TITLE" | sed 's/chore(deps): update //' | sed 's/ Docker tag.*//' | sed 's/ to.*//')
    OLD_VERSION="unknown"
    NEW_VERSION=$(echo "$PR_TITLE" | grep -oE 'to v?[0-9.]+' | sed 's/to v\?//' || echo "unknown")
    if echo "$PR_TITLE" | grep -iq "major"; then
        UPDATE_TYPE="major"
    elif echo "$PR_TITLE" | grep -iq "minor"; then
        UPDATE_TYPE="minor"
    else
        UPDATE_TYPE="patch"
    fi
fi

echo "Package: $PACKAGE_NAME"
echo "Update Type: $UPDATE_TYPE"
echo "Version Change: $OLD_VERSION → $NEW_VERSION"
echo ""

# Show changed files and detect update category EARLY (needed for conditional logic)
CHANGED_FILES=$(echo "$PR_JSON" | jq -r '.files[].path')

UPDATE_CATEGORY="unknown"
if echo "$CHANGED_FILES" | grep -q "deployment.yaml\|statefulset.yaml\|daemonset.yaml"; then
    UPDATE_CATEGORY="Docker Image"
elif echo "$CHANGED_FILES" | grep -q "release.yaml\|helmrelease.yaml"; then
    UPDATE_CATEGORY="Helm Chart"
elif echo "$CHANGED_FILES" | grep -q "gotk-components.yaml"; then
    UPDATE_CATEGORY="Flux Components"
else
    UPDATE_CATEGORY="Configuration"
fi

# Extract source repository from PR body (markdown format: [source](url))
SOURCE_REPO=""
if echo "$PR_BODY" | grep -qE '\[source\]'; then
    SOURCE_REPO=$(echo "$PR_BODY" | grep -oE '\[source\]\(https://[^)]+\)' | sed 's|\[source\](||' | sed 's|)||' | sed 's|redirect.github.com|github.com|' | head -1)
fi

# Extract various documentation links from PR body
RELEASE_LINK=$(echo "$PR_BODY" | grep -oE 'https://[^)]+/releases/tag/[^)]+' | head -n 1 | sed 's|redirect.github.com|github.com|' || echo "")
CHANGELOG_LINK=$(echo "$PR_BODY" | grep -oE 'https://[^)]+/CHANGELOG[^)]*' | head -n 1 | sed 's|redirect.github.com|github.com|' || echo "")
COMPARE_LINK=$(echo "$PR_BODY" | grep -oE 'https://[^)]+/compare/[^)]+' | head -n 1 | sed 's|redirect.github.com|github.com|' || echo "")

echo "📄 Changed files:"
echo "$CHANGED_FILES" | sed 's/^/  - /'
echo ""
echo "📦 Update Type: $UPDATE_CATEGORY"
echo ""

# Display detected links
if [ -n "$RELEASE_LINK" ]; then
    echo "📝 Release Notes: $RELEASE_LINK"
fi
if [ -n "$CHANGELOG_LINK" ]; then
    echo "📝 Changelog: $CHANGELOG_LINK"
fi
if [ -n "$COMPARE_LINK" ]; then
    echo "📝 Compare: $COMPARE_LINK"
fi
if [ -n "$SOURCE_REPO" ]; then
    echo "📝 Source: $SOURCE_REPO"
fi
echo ""

# Function to extract repo path from GitHub URL
extract_repo_path() {
    local url="$1"
    echo "$url" | sed -E 's|https?://(redirect\.)?github\.com/||' | sed 's|/releases.*||' | sed 's|/blob.*||' | sed 's|/compare.*||'
}

# Function to fetch GitHub release via API
fetch_github_release() {
    local repo="$1"
    local tag="$2"
    local package_name="${3:-}"

    # Try various tag formats
    local content=""

    # 1. Try exact tag
    content=$(curl -sL "https://api.github.com/repos/$repo/releases/tags/$tag" 2>/dev/null | jq -r '.body // empty' 2>/dev/null || echo "")

    # 2. Try with 'v' prefix
    if [ -z "$content" ] && [[ ! "$tag" =~ ^v ]]; then
        content=$(curl -sL "https://api.github.com/repos/$repo/releases/tags/v$tag" 2>/dev/null | jq -r '.body // empty' 2>/dev/null || echo "")
    fi

    # 3. Try monorepo format: package@version (e.g., n8n@1.123.4)
    if [ -z "$content" ] && [ -n "$package_name" ]; then
        local short_name=$(echo "$package_name" | sed 's|.*/||')  # n8nio/n8n -> n8n
        content=$(curl -sL "https://api.github.com/repos/$repo/releases/tags/${short_name}@$tag" 2>/dev/null | jq -r '.body // empty' 2>/dev/null || echo "")
    fi

    echo "$content" | head -c "$MAX_CONTENT_LENGTH"
}

# Function to fetch raw file from GitHub
fetch_raw_file() {
    local repo="$1"
    local filepath="$2"
    local branch="${3:-main}"

    # Try main, then master
    local content=""
    content=$(curl -sL "https://raw.githubusercontent.com/$repo/$branch/$filepath" 2>/dev/null || echo "")

    if [ -z "$content" ] || echo "$content" | grep -q "404: Not Found"; then
        content=$(curl -sL "https://raw.githubusercontent.com/$repo/master/$filepath" 2>/dev/null || echo "")
    fi

    # Check if we got valid content (not 404 page)
    if echo "$content" | grep -q "404: Not Found"; then
        echo ""
    else
        echo "$content" | head -c "$MAX_CONTENT_LENGTH"
    fi
}

# Function to search for changelog files
find_changelog() {
    local repo="$1"

    # Standard changelog file names (priority order per Keep a Changelog)
    local filenames=("CHANGELOG.md" "changelog.md" "HISTORY.md" "History.md" "CHANGES.md" "Changes.md" "RELEASES.md" "releases.md" "NEWS.md" "news.md" "RELEASE_NOTES.md")

    for filename in "${filenames[@]}"; do
        local content
        content=$(fetch_raw_file "$repo" "$filename")
        if [ -n "$content" ]; then
            echo "   Found: $filename"
            echo "$content"
            return
        fi
    done

    echo ""
}

# Function to extract version-specific section from changelog
extract_version_section() {
    local content="$1"
    local version="$2"

    # Remove 'v' prefix for matching
    local clean_version="${version#v}"

    # Try to extract section between this version header and next version header
    # Common formats: ## [1.2.3], ## v1.2.3, ### v1.2.3, ## 1.2.3
    local section
    section=$(echo "$content" | awk -v ver="$clean_version" '
        BEGIN { found=0; printing=0 }
        /^##+ *\[?v?[0-9]+\.[0-9]+/ {
            if (printing) exit
            if (index($0, ver) > 0) { found=1; printing=1 }
        }
        printing { print }
    ' | head -100)

    if [ -n "$section" ]; then
        echo "$section"
    else
        # Fallback: just return first 100 lines
        echo "$content" | head -100
    fi
}

# Fetch documentation from multiple sources
echo "🔍 Fetching documentation..."
echo ""

RELEASE_CONTENT=""
CHANGELOG_CONTENT=""
UPGRADE_CONTENT=""
BREAKING_CHANGES_CONTENT=""

# Determine repository path
REPO_PATH=""
if [ -n "$SOURCE_REPO" ]; then
    REPO_PATH=$(extract_repo_path "$SOURCE_REPO")
elif [ -n "$RELEASE_LINK" ]; then
    REPO_PATH=$(extract_repo_path "$RELEASE_LINK")
elif [ -n "$CHANGELOG_LINK" ]; then
    REPO_PATH=$(extract_repo_path "$CHANGELOG_LINK")
fi

if [ -n "$REPO_PATH" ]; then
    echo "   Repository: $REPO_PATH"

    # 1. Try GitHub Release API first (cleanest source)
    if [ -n "$RELEASE_LINK" ]; then
        TAG=$(echo "$RELEASE_LINK" | sed -E 's|.*/releases/tag/||')
        echo "   Fetching GitHub release for tag: $TAG"
        RELEASE_CONTENT=$(fetch_github_release "$REPO_PATH" "$TAG" "$PACKAGE_NAME")
        if [ -n "$RELEASE_CONTENT" ]; then
            echo "   ✓ Found GitHub release notes"
        fi
    elif [ -n "$NEW_VERSION" ] && [ "$NEW_VERSION" != "unknown" ]; then
        # No explicit release link, try to fetch release by version
        echo "   Fetching GitHub release for version: $NEW_VERSION"
        RELEASE_CONTENT=$(fetch_github_release "$REPO_PATH" "$NEW_VERSION" "$PACKAGE_NAME")
        if [ -n "$RELEASE_CONTENT" ]; then
            echo "   ✓ Found GitHub release notes"
        fi
    fi

    # 2. Try changelog files if no release content
    if [ -z "$RELEASE_CONTENT" ]; then
        echo "   Searching for changelog files..."
        CHANGELOG_CONTENT=$(find_changelog "$REPO_PATH")
        if [ -n "$CHANGELOG_CONTENT" ]; then
            # Extract version-specific section
            CHANGELOG_CONTENT=$(extract_version_section "$CHANGELOG_CONTENT" "$NEW_VERSION")
        fi
    fi

    # 3. For Helm charts, also fetch UPGRADE.md and BREAKING_CHANGES.md
    if [ "$UPDATE_CATEGORY" = "Helm Chart" ] || echo "$PACKAGE_NAME" | grep -qi "helm\|chart\|prometheus-stack"; then
        echo "   Checking for Helm-specific documentation..."

        # kube-prometheus-stack has its own chart repo
        if echo "$PACKAGE_NAME" | grep -qi "kube-prometheus-stack"; then
            UPGRADE_CONTENT=$(fetch_raw_file "prometheus-community/helm-charts" "charts/kube-prometheus-stack/UPGRADE.md")
            if [ -n "$UPGRADE_CONTENT" ]; then
                echo "   ✓ Found UPGRADE.md"
            fi
        else
            UPGRADE_CONTENT=$(fetch_raw_file "$REPO_PATH" "UPGRADE.md")
            if [ -z "$UPGRADE_CONTENT" ]; then
                UPGRADE_CONTENT=$(fetch_raw_file "$REPO_PATH" "charts/UPGRADE.md")
            fi
        fi

        BREAKING_CHANGES_CONTENT=$(fetch_raw_file "$REPO_PATH" "BREAKING_CHANGES.md")
        if [ -n "$BREAKING_CHANGES_CONTENT" ]; then
            echo "   ✓ Found BREAKING_CHANGES.md"
        fi
    fi
fi

echo ""

# Combine all content for analysis
ALL_CONTENT="${RELEASE_CONTENT}${CHANGELOG_CONTENT}"

# Initialize breaking change flags (must be defined before use)
HAS_BREAKING=false
HAS_MIGRATION=false
HAS_REMOVAL=false
HAS_SECURITY=false
HAS_DEPRECATED=false
HAS_CONFIG_CHANGE=false

# Analyze for breaking changes
if [ -n "$ALL_CONTENT" ]; then
    # Clean content (strip HTML if any)
    CLEAN_CONTENT=$(echo "$ALL_CONTENT" | sed 's/<[^>]*>//g' | sed 's/&lt;/</g' | sed 's/&gt;/>/g' | sed 's/&amp;/\&/g' | sed 's/&quot;/"/g')

    # Check for breaking change patterns (Conventional Commits + Common Changelog)
    if echo "$CLEAN_CONTENT" | grep -qiE "breaking.?change|BREAKING:|^\*\*Breaking:"; then
        HAS_BREAKING=true
    fi

    # Check for migration requirements
    if echo "$CLEAN_CONTENT" | grep -qiE "migration.?required|action.?required|migrate|upgrade.?note"; then
        HAS_MIGRATION=true
    fi

    # Check for removals
    if echo "$CLEAN_CONTENT" | grep -qiE "removed|no longer|drop.*support|deprecated.*removed"; then
        HAS_REMOVAL=true
    fi

    # Check for security fixes
    if echo "$CLEAN_CONTENT" | grep -qiE "security|vulnerability|CVE-|insecure|exploit"; then
        HAS_SECURITY=true
    fi

    # Check for deprecations
    if echo "$CLEAN_CONTENT" | grep -qiE "deprecated|deprecating"; then
        HAS_DEPRECATED=true
    fi

    # Check for config changes
    if echo "$CLEAN_CONTENT" | grep -qiE "configuration.?change|config.?change|environment.?variable|breaking.*config"; then
        HAS_CONFIG_CHANGE=true
    fi

    # Display findings
    if [ "$HAS_BREAKING" = true ] || [ "$HAS_MIGRATION" = true ] || [ "$HAS_REMOVAL" = true ] || [ "$HAS_SECURITY" = true ] || [ "$HAS_DEPRECATED" = true ]; then
        echo "🚨 IMPORTANT FINDINGS:"
        echo ""

        if [ "$HAS_BREAKING" = true ]; then
            echo "  ⚠️  BREAKING CHANGES detected!"
            echo "$CLEAN_CONTENT" | grep -iE "breaking|BREAKING:" | head -5 | sed 's/^/     /'
            echo ""
        fi

        if [ "$HAS_SECURITY" = true ]; then
            echo "  🔐 Security fixes detected:"
            echo "$CLEAN_CONTENT" | grep -iE "security|vulnerability|CVE-" | head -5 | sed 's/^/     /'
            echo ""
        fi

        if [ "$HAS_REMOVAL" = true ]; then
            echo "  🗑️  Removed features detected:"
            echo "$CLEAN_CONTENT" | grep -iE "removed|no longer" | head -5 | sed 's/^/     /'
            echo ""
        fi

        if [ "$HAS_DEPRECATED" = true ]; then
            echo "  ⏳ Deprecations detected:"
            echo "$CLEAN_CONTENT" | grep -iE "deprecated" | head -3 | sed 's/^/     /'
            echo ""
        fi

        if [ "$HAS_MIGRATION" = true ]; then
            echo "  📋 Migration steps may be required"
            echo "$CLEAN_CONTENT" | grep -iE "migration|migrate|action.?required" | head -3 | sed 's/^/     /'
            echo ""
        fi

        if [ "$HAS_CONFIG_CHANGE" = true ]; then
            echo "  🔧 Configuration changes detected"
            echo ""
        fi
    else
        echo "✅ No obvious breaking changes detected in release notes"
        echo ""
    fi

    # Show release content summary
    if [ -n "$RELEASE_CONTENT" ]; then
        echo "📋 Release Notes Summary:"
        echo "---"
        # Show first 50 lines of release notes
        echo "$RELEASE_CONTENT" | head -50
        echo "---"
        echo ""
    elif [ -n "$CHANGELOG_CONTENT" ]; then
        echo "📋 Changelog Summary (version $NEW_VERSION):"
        echo "---"
        echo "$CHANGELOG_CONTENT" | head -50
        echo "---"
        echo ""
    fi
else
    echo "⚠️  Could not fetch release notes or changelog"
    echo ""
fi

# Display UPGRADE.md content for Helm charts
if [ -n "$UPGRADE_CONTENT" ]; then
    echo "📦 Helm Chart Upgrade Notes:"
    echo "---"

    # Try to extract version-specific upgrade section
    # kube-prometheus-stack uses "From 79.x to 80.x" format
    VERSION_SECTION=""
    if [ -n "$OLD_VERSION" ] && [ "$OLD_VERSION" != "unknown" ]; then
        OLD_MAJOR=$(echo "$OLD_VERSION" | cut -d. -f1)
        NEW_MAJOR=$(echo "$NEW_VERSION" | cut -d. -f1)

        # Look for section like "From 79.x to 80.x" or "## 80.0.0"
        VERSION_SECTION=$(echo "$UPGRADE_CONTENT" | awk -v old="$OLD_MAJOR" -v new="$NEW_MAJOR" '
            BEGIN { found=0; printing=0 }
            /^##+ *(From|Upgrading)/ {
                if (printing) exit
                if ((index($0, old".x") > 0 && index($0, new".x") > 0) || index($0, new".0") > 0) {
                    found=1; printing=1
                }
            }
            /^##+ *[0-9]+\.[0-9]+/ {
                if (printing) exit
                if (index($0, new".") > 0) { found=1; printing=1 }
            }
            printing { print }
        ' | head -60)
    fi

    if [ -n "$VERSION_SECTION" ]; then
        echo "$VERSION_SECTION"
    else
        # Just show recent upgrade notes
        echo "$UPGRADE_CONTENT" | head -60
    fi
    echo "---"
    echo ""
fi

# Display BREAKING_CHANGES.md if found
if [ -n "$BREAKING_CHANGES_CONTENT" ]; then
    echo "⚠️  Helm Chart Breaking Changes:"
    echo "---"
    echo "$BREAKING_CHANGES_CONTENT" | head -40
    echo "---"
    echo ""
fi

# Priority assessment
PRIORITY="MEDIUM"
if [ "$UPDATE_TYPE" = "major" ]; then
    PRIORITY="HIGH"
    echo "🔴 MAJOR UPDATE - High risk of breaking changes"
elif [ "$HAS_BREAKING" = true ] || [ "$HAS_SECURITY" = true ]; then
    PRIORITY="HIGH"
    echo "🔴 HIGH PRIORITY - Breaking changes or security fixes detected"
elif [ "$UPDATE_TYPE" = "patch" ]; then
    PRIORITY="LOW"
    echo "🟢 PATCH UPDATE - Low risk"
else
    echo "🟡 MINOR UPDATE - Medium risk"
fi
echo ""

# Package-specific guidance
echo "📋 Package-Specific Checklist:"
echo ""

case "$PACKAGE_NAME" in
    *authentik*)
        echo "🔐 Authentik Update"
        echo "  - [ ] Check authentication flow changes"
        echo "  - [ ] Review OAuth/OIDC provider changes"
        echo "  - [ ] Monitor database migrations"
        echo "  - [ ] Test login flows after deployment"
        ;;
    *prometheus-stack*|*grafana*)
        echo "📊 Monitoring Stack Update"
        echo "  - [ ] Run CRD update commands from UPGRADE.md"
        echo "  - [ ] Verify dashboards load correctly"
        echo "  - [ ] Test alert notifications"
        echo "  - [ ] Check Prometheus targets are healthy"
        ;;
    *flux*|*kustomize*|*helm-controller*)
        echo "🔄 Flux/GitOps Update"
        echo "  - [ ] Monitor reconciliation after update"
        echo "  - [ ] Check for failed kustomizations"
        echo "  - [ ] Verify all HelmReleases reconcile"
        ;;
    *traefik*)
        echo "🌐 Traefik Ingress Update"
        echo "  - [ ] Test ingress routes"
        echo "  - [ ] Verify TLS certificates"
        echo "  - [ ] Check middleware configurations"
        ;;
    *postgres*|*couchdb*|*mariadb*)
        echo "🗄️  Database Update"
        echo "  - [ ] BACKUP DATABASE BEFORE MERGE"
        echo "  - [ ] Review migration scripts"
        echo "  - [ ] Test application connections"
        ;;
    *n8n*|*paperless*|*immich*|*home-assistant*|*adguard*)
        echo "📱 Application Update"
        echo "  - [ ] Review changelog for new features"
        echo "  - [ ] Check for config file changes"
        echo "  - [ ] Test core functionality after deployment"
        ;;
    *)
        echo "📦 General Update"
        echo "  - [ ] Review release notes"
        echo "  - [ ] Check for breaking changes"
        echo "  - [ ] Test affected functionality"
        ;;
esac

echo ""
echo "==================================="
echo "Quick Actions"
echo "==================================="
echo ""
echo "Merge: gh pr merge $PR_NUMBER --squash"
echo ""
echo "Monitor deployment:"
echo "  flux reconcile source git flux-system --timeout 45s --force"
echo "  flux reconcile kustomization apps --timeout 45s --force"
echo ""

# Show documentation links
if [ -n "$RELEASE_LINK" ] || [ -n "$CHANGELOG_LINK" ]; then
    echo "📖 Documentation:"
    [ -n "$RELEASE_LINK" ] && echo "  Release: $RELEASE_LINK"
    [ -n "$CHANGELOG_LINK" ] && echo "  Changelog: $CHANGELOG_LINK"
    [ -n "$COMPARE_LINK" ] && echo "  Compare: $COMPARE_LINK"
    echo ""
fi
