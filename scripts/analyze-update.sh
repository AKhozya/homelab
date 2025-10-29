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
# 4. Provides package-specific breaking change checklist
# 5. Links to release notes and changelogs
# 6. Generates actionable review checklist
#

set -euo pipefail

PR_NUMBER="${1:-}"

if [ -z "$PR_NUMBER" ]; then
    echo "Usage: $0 <PR_NUMBER>"
    echo ""
    echo "Example: $0 85"
    exit 1
fi

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
    UPDATE_TYPE=$(echo "$PR_TITLE" | grep -iq "major" && echo "major" || echo "$PR_TITLE" | grep -iq "minor" && echo "minor" || echo "patch")
fi

echo "Package: $PACKAGE_NAME"
echo "Update Type: $UPDATE_TYPE"
echo "Version Change: $OLD_VERSION → $NEW_VERSION"
echo ""

# Extract release notes link if available
RELEASE_LINK=$(echo "$PR_BODY" | grep -oE 'https://[^)]+/releases/tag/[^)]+' | head -n 1 || echo "")
CHANGELOG_LINK=$(echo "$PR_BODY" | grep -oE 'https://[^)]+/CHANGELOG[^)]*' | head -n 1 || echo "")
COMPARE_LINK=$(echo "$PR_BODY" | grep -oE 'https://[^)]+/compare/[^)]+' | head -n 1 || echo "")

# Determine which link to use
DOCS_LINK=""
if [ -n "$RELEASE_LINK" ]; then
    DOCS_LINK="$RELEASE_LINK"
    echo "📝 Release Notes: $RELEASE_LINK"
elif [ -n "$CHANGELOG_LINK" ]; then
    DOCS_LINK="$CHANGELOG_LINK"
    echo "📝 Changelog: $CHANGELOG_LINK"
elif [ -n "$COMPARE_LINK" ]; then
    DOCS_LINK="$COMPARE_LINK"
    echo "📝 Compare: $COMPARE_LINK"
else
    echo "⚠️  No release notes link found"
fi
echo ""

# Fetch and analyze release notes if available
if [ -n "$DOCS_LINK" ]; then
    echo "🔍 Fetching and analyzing release notes..."
    echo ""

    # Fetch the content
    RELEASE_CONTENT=$(curl -sL "$DOCS_LINK" 2>/dev/null || echo "")

    if [ -n "$RELEASE_CONTENT" ]; then
        # Convert HTML to more readable text (strip tags, decode entities)
        CLEAN_CONTENT=$(echo "$RELEASE_CONTENT" | sed 's/<[^>]*>//g' | sed 's/&lt;/</g' | sed 's/&gt;/>/g' | sed 's/&amp;/\&/g' | sed 's/&quot;/"/g')

        # Extract sections with breaking changes
        BREAKING_SECTION=$(echo "$CLEAN_CONTENT" | grep -iB 2 -A 15 "breaking change" | head -30 || echo "")

        # Extract migration/upgrade sections
        MIGRATION_SECTION=$(echo "$CLEAN_CONTENT" | grep -iB 2 -A 15 "migration\|upgrade.*note\|action required" | head -30 || echo "")

        # Extract deprecation warnings
        DEPRECATION_SECTION=$(echo "$CLEAN_CONTENT" | grep -iB 2 -A 10 "deprecat" | head -25 || echo "")

        # Look for removed features/dependencies
        REMOVED_SECTION=$(echo "$CLEAN_CONTENT" | grep -iB 2 -A 10 "removed\|no longer\|drop.*support" | head -25 || echo "")

        # Look for security issues
        SECURITY_SECTION=$(echo "$CLEAN_CONTENT" | grep -iB 2 -A 10 "security\|vulnerability\|CVE\|insecure\|exploit\|password.*fix\|credential.*fix" | head -25 || echo "")

        # Check for important keywords
        HAS_BREAKING=false
        HAS_MIGRATION=false
        HAS_CONFIG_CHANGE=false
        HAS_REMOVAL=false
        HAS_SECURITY=false

        [ -n "$BREAKING_SECTION" ] && HAS_BREAKING=true
        echo "$CLEAN_CONTENT" | grep -qi "migration\|migrate" && HAS_MIGRATION=true
        echo "$CLEAN_CONTENT" | grep -qi "configuration\|config.*change\|environment variable\|setting" && HAS_CONFIG_CHANGE=true
        [ -n "$REMOVED_SECTION" ] && HAS_REMOVAL=true
        [ -n "$SECURITY_SECTION" ] && HAS_SECURITY=true

        # Display findings
        if [ "$HAS_BREAKING" = true ] || [ "$HAS_MIGRATION" = true ] || [ "$HAS_CONFIG_CHANGE" = true ] || [ "$HAS_REMOVAL" = true ] || [ "$HAS_SECURITY" = true ]; then
            echo "🚨 IMPORTANT FINDINGS FROM RELEASE NOTES:"
            echo ""

            if [ "$HAS_BREAKING" = true ]; then
                echo "  ⚠️  Breaking changes detected:"
                echo "$BREAKING_SECTION" | grep -i "breaking\|break" | sed 's/^/     /' | head -5
                echo ""
            fi

            if [ "$HAS_SECURITY" = true ]; then
                echo "  🔐 Security fixes/issues detected:"
                echo "$SECURITY_SECTION" | grep -iE "security|vulnerability|CVE|insecure|password|credential" | sed 's/^/     /' | head -5
                echo ""
            fi

            if [ "$HAS_REMOVAL" = true ]; then
                echo "  🗑️  Removed features/dependencies detected:"
                echo "$REMOVED_SECTION" | grep -iE "removed|no longer|drop" | sed 's/^/     /' | head -5
                echo ""
            fi

            if [ "$HAS_MIGRATION" = true ]; then
                echo "  📋 Migration/upgrade steps may be required"
                echo "$MIGRATION_SECTION" | grep -iE "migration|migrate|upgrade" | sed 's/^/     /' | head -5
                echo ""
            fi

            if [ "$HAS_CONFIG_CHANGE" = true ]; then
                echo "  🔧 Configuration changes detected"
                echo ""
            fi

            echo "  👉 READ THE FULL RELEASE NOTES BEFORE MERGING: $DOCS_LINK"
            echo ""
        else
            echo "✅ No obvious breaking changes detected in release notes"
            echo "   (Still recommended to review: $DOCS_LINK)"
            echo ""
        fi
    else
        echo "⚠️  Could not fetch release notes content"
        echo ""
    fi
fi

# Show changed files and extract what's being updated
echo "📄 Changed files:"
CHANGED_FILES=$(echo "$PR_JSON" | jq -r '.files[].path')
echo "$CHANGED_FILES" | sed 's/^/  - /'
echo ""

# Detect update type from files
UPDATE_CATEGORY="unknown"
if echo "$CHANGED_FILES" | grep -q "deployment.yaml\|statefulset.yaml\|daemonset.yaml"; then
    UPDATE_CATEGORY="Docker Image"
    echo "📦 Update Type: Docker Image in Kubernetes resource"
elif echo "$CHANGED_FILES" | grep -q "release.yaml\|helmrelease.yaml"; then
    UPDATE_CATEGORY="Helm Chart"
    echo "📦 Update Type: Helm Chart version"
elif echo "$CHANGED_FILES" | grep -q "gotk-components.yaml"; then
    UPDATE_CATEGORY="Flux Components"
    echo "📦 Update Type: Flux GitOps components"
else
    echo "📦 Update Type: Configuration file"
fi
echo ""

# Check for specific keywords in update type
PRIORITY="MEDIUM"
if [ "$UPDATE_TYPE" = "major" ]; then
    PRIORITY="HIGH"
    echo "🔴 MAJOR UPDATE - High risk of breaking changes"
elif [ "$UPDATE_TYPE" = "patch" ]; then
    PRIORITY="LOW"
    echo "🟢 PATCH UPDATE - Low risk"
else
    echo "🟡 MINOR UPDATE - Medium risk"
fi
echo ""

# Package-specific guidance
echo "📋 Package-Specific Analysis:"
echo ""

case "$PACKAGE_NAME" in
    *authentik*)
        echo "🔐 Authentik Update"
        echo "Check for:"
        echo "  - Authentication flow changes"
        echo "  - OAuth/OIDC provider changes"
        echo "  - Database schema migrations"
        echo "  - Redis/cache configuration changes"
        echo "  - Provider configuration updates"
        echo ""
        echo "Action items:"
        echo "  1. Review release notes for breaking changes"
        echo "  2. Test login flows after deployment"
        echo "  3. Check provider integrations (Grafana, etc.)"
        echo "  4. Monitor authentication error rates"
        ;;

    *prometheus-stack*|*grafana*)
        echo "📊 Monitoring Stack Update"
        echo "Check for:"
        echo "  - Dashboard compatibility"
        echo "  - Alert rule changes"
        echo "  - Grafana plugin updates"
        echo "  - Prometheus query language changes"
        echo "  - Security fixes (especially credentials)"
        echo ""
        echo "Action items:"
        echo "  1. Verify all dashboards load correctly"
        echo "  2. Test alert notifications"
        echo "  3. Check Grafana admin credentials"
        echo "  4. Review prometheus query performance"
        ;;

    *flux*|*kustomize*|*helm-controller*)
        echo "🔄 Flux/GitOps Update"
        echo "Check for:"
        echo "  - API version changes"
        echo "  - Reconciliation behavior changes"
        echo "  - Breaking changes in controllers"
        echo "  - New CRD versions"
        echo ""
        echo "Action items:"
        echo "  1. Monitor reconciliation after update"
        echo "  2. Check for failed kustomizations"
        echo "  3. Verify all apps reconcile successfully"
        echo "  4. Review controller logs for warnings"
        ;;

    *traefik*)
        echo "🌐 Traefik Ingress Update"
        echo "Check for:"
        echo "  - Middleware API changes"
        echo "  - IngressRoute compatibility"
        echo "  - TLS configuration changes"
        echo "  - Plugin updates"
        echo ""
        echo "Action items:"
        echo "  1. Test all ingress routes"
        echo "  2. Verify TLS certificates"
        echo "  3. Check middleware configurations"
        echo "  4. Monitor HTTP error rates"
        ;;

    *external-dns*)
        echo "🌍 External-DNS Update"
        echo "Check for:"
        echo "  - Provider API changes (Cloudflare, etc.)"
        echo "  - DNS record format changes"
        echo "  - IPv4/IPv6 handling changes"
        echo "  - TTL and zone changes"
        echo ""
        echo "Action items:"
        echo "  1. Verify DNS records after deployment"
        echo "  2. Check for unexpected A/AAAA records"
        echo "  3. Monitor external-dns logs"
        echo "  4. Test DNS resolution for all domains"
        ;;

    *postgres*|*couchdb*)
        echo "🗄️  Database Update"
        echo "Check for:"
        echo "  - Schema migration requirements"
        echo "  - Configuration parameter changes"
        echo "  - Backup compatibility"
        echo "  - Extension updates"
        echo "  - Breaking SQL changes"
        echo ""
        echo "Action items:"
        echo "  1. BACKUP DATABASE BEFORE APPLYING"
        echo "  2. Review migration scripts"
        echo "  3. Test application connections"
        echo "  4. Monitor query performance"
        echo "  5. Verify backup/restore works"
        ;;

    *redis*)
        echo "💾 Redis Update"
        echo "Check for:"
        echo "  - Configuration changes"
        echo "  - Persistence behavior changes"
        echo "  - Command deprecations"
        echo "  - Memory management changes"
        echo ""
        echo "Action items:"
        echo "  1. Review configuration compatibility"
        echo "  2. Test application connections"
        echo "  3. Monitor memory usage"
        echo "  4. Check for deprecated commands in logs"
        ;;

    *n8n*|*paperless*|*immich*|*home-assistant*)
        echo "📱 Application Update"
        echo "Check for:"
        echo "  - Feature additions/removals"
        echo "  - Configuration file changes"
        echo "  - Database migrations"
        echo "  - Plugin/integration updates"
        echo ""
        echo "Action items:"
        echo "  1. Review application changelog"
        echo "  2. Test core functionality"
        echo "  3. Check for new configuration options"
        echo "  4. Monitor application logs"
        ;;

    *)
        echo "📦 General Update"
        echo "Check for:"
        echo "  - Breaking changes in release notes"
        echo "  - Deprecated features"
        echo "  - New configuration requirements"
        echo "  - Security advisories"
        echo ""
        echo "Action items:"
        echo "  1. Review release notes/changelog"
        echo "  2. Test affected functionality"
        echo "  3. Monitor application logs"
        ;;
esac

echo ""
echo "==================================="
echo "Review Checklist"
echo "==================================="
echo ""
echo "Before merging:"
echo "  [ ] Read release notes/changelog"
echo "  [ ] Identify breaking changes"
echo "  [ ] Check for deprecation warnings"
echo "  [ ] Review configuration changes needed"
echo "  [ ] Assess rollback complexity"
echo ""
echo "After merging:"
echo "  [ ] Monitor application logs"
echo "  [ ] Verify core functionality"
echo "  [ ] Check Prometheus alerts"
echo "  [ ] Test affected integrations"
echo "  [ ] Document any issues found"
echo ""

if [ -n "$DOCS_LINK" ]; then
    echo "📖 Full release notes: $DOCS_LINK"
    echo ""
fi

echo "To merge this PR:"
echo "  gh pr merge $PR_NUMBER --squash"
echo ""

echo "To monitor deployment:"
echo "  flux reconcile source git flux-system --timeout 45s --force"
echo "  flux reconcile kustomization apps --timeout 45s --force"
echo ""
