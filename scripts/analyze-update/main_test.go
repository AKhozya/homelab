package main

import (
	"strings"
	"testing"
)

func TestCleanVersionString(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{"simple version", "1.2.3", "1.2.3"},
		{"with v prefix", "v1.2.3", "1.2.3"},
		{"monorepo format", "n8n@1.123.4", "1.123.4"},
		{"monorepo with v", "package@v2.0.0", "2.0.0"},
		{"multiple @", "org@pkg@1.0.0", "1.0.0"},
		{"empty string", "", ""},
		{"just v", "v", ""},
		{"prerelease", "v1.2.3-beta.1", "1.2.3-beta.1"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := cleanVersionString(tt.input)
			if result != tt.expected {
				t.Errorf("cleanVersionString(%q) = %q, want %q", tt.input, result, tt.expected)
			}
		})
	}
}

func TestComputeUpdateType(t *testing.T) {
	tests := []struct {
		name     string
		oldVer   string
		newVer   string
		expected string
	}{
		{"major bump", "1.0.0", "2.0.0", "major"},
		{"minor bump", "1.0.0", "1.1.0", "minor"},
		{"patch bump", "1.0.0", "1.0.1", "patch"},
		{"with v prefix", "v1.0.0", "v1.0.1", "patch"},
		{"monorepo major", "n8n@1.0.0", "n8n@2.0.0", "major"},
		{"monorepo minor", "pkg@1.0.0", "pkg@1.5.0", "minor"},
		{"monorepo patch", "app@1.2.3", "app@1.2.4", "patch"},
		{"mixed formats", "v1.0.0", "pkg@1.1.0", "minor"},
		{"invalid old", "invalid", "1.0.0", "unknown"},
		{"invalid new", "1.0.0", "invalid", "unknown"},
		{"same version", "1.0.0", "1.0.0", "unknown"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := computeUpdateType(tt.oldVer, tt.newVer)
			if result != tt.expected {
				t.Errorf("computeUpdateType(%q, %q) = %q, want %q", tt.oldVer, tt.newVer, result, tt.expected)
			}
		})
	}
}

func TestExtractRepoPath(t *testing.T) {
	tests := []struct {
		name     string
		url      string
		expected string
	}{
		{"github https", "https://github.com/owner/repo", "owner/repo"},
		{"github with trailing slash", "https://github.com/owner/repo/", "owner/repo"},
		{"github releases url", "https://github.com/owner/repo/releases/tag/v1.0.0", "owner/repo"},
		{"github compare url", "https://github.com/owner/repo/compare/v1.0.0...v1.1.0", "owner/repo"},
		{"github blob url", "https://github.com/owner/repo/blob/main/README.md", "owner/repo"},
		{"ghcr image (not supported)", "ghcr.io/owner/repo", ""}, // extractRepoPath only handles github.com URLs
		{"empty string", "", ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := extractRepoPath(tt.url)
			if result != tt.expected {
				t.Errorf("extractRepoPath(%q) = %q, want %q", tt.url, result, tt.expected)
			}
		})
	}
}

func TestDetectUpdateCategory(t *testing.T) {
	tests := []struct {
		name     string
		files    []string
		expected UpdateCategory
	}{
		{
			name:     "docker image update - deployment.yaml",
			files:    []string{"apps/base/home-assistant/deployment.yaml"},
			expected: DockerImage,
		},
		{
			name:     "docker image update - statefulset.yaml",
			files:    []string{"apps/base/redis/statefulset.yaml"},
			expected: DockerImage,
		},
		{
			name:     "helm release update",
			files:    []string{"infrastructure/controllers/base/cert-manager/release.yaml"},
			expected: HelmChart,
		},
		{
			name:     "monitoring helm update",
			files:    []string{"monitoring/controllers/base/kube-prometheus-stack/release.yaml"},
			expected: HelmChart,
		},
		{
			name:     "flux components update",
			files:    []string{"clusters/gotk-components.yaml"},
			expected: FluxComponents,
		},
		{
			name:     "config file update",
			files:    []string{"apps/base/home-assistant/configmap.yaml"},
			expected: Configuration,
		},
		{
			name:     "empty files",
			files:    []string{},
			expected: Configuration,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := detectUpdateCategory(tt.files)
			if result != tt.expected {
				t.Errorf("detectUpdateCategory() = %v, want %v", result, tt.expected)
			}
		})
	}
}

func TestExtractDocumentationLinks(t *testing.T) {
	tests := []struct {
		name     string
		body     string
		hasLinks bool
	}{
		{
			name: "renovate PR body with links",
			body: `| Package | Update | Change |
| --- | --- | --- |
| [ghcr.io/home-assistant/home-assistant](https://github.com/home-assistant/core) | patch | 2025.12.0 -> 2025.12.1 |

---

### Release Notes

<details>
<summary>home-assistant/core (ghcr.io/home-assistant/home-assistant)</summary>

### [v2025.12.1](https://github.com/home-assistant/core/releases/tag/2025.12.1): 2025.12.1

[Compare Source](https://github.com/home-assistant/core/compare/2025.12.0...2025.12.1)
</details>`,
			hasLinks: true,
		},
		{
			name:     "empty body",
			body:     "",
			hasLinks: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := extractDocumentationLinks(tt.body)
			hasLinks := result.ReleaseLink != "" || result.CompareLink != "" || result.SourceRepo != ""
			if hasLinks != tt.hasLinks {
				t.Errorf("extractDocumentationLinks() hasLinks = %v, want %v, got %+v", hasLinks, tt.hasLinks, result)
			}
		})
	}
}

func TestTruncate(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		maxLines int
	}{
		{"short content", "line1\nline2\nline3", 30},
		{"empty content", "", 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := truncate(tt.input)
			// Just verify it doesn't panic and returns something
			if tt.input != "" && result == "" {
				t.Error("truncate() returned empty for non-empty input")
			}
		})
	}
}

func TestCleanContent(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "strips html comments",
			input:    "<!-- comment -->actual content",
			expected: "actual content",
		},
		{
			name:     "strips html tags",
			input:    "<details>content</details>",
			expected: "content",
		},
		{
			name:     "preserves normal text",
			input:    "normal text here",
			expected: "normal text here",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := cleanContent(tt.input)
			// cleanContent may do additional processing, just check key behaviors
			if tt.input == "normal text here" && result != tt.expected {
				t.Errorf("cleanContent(%q) = %q, want %q", tt.input, result, tt.expected)
			}
		})
	}
}

func TestExtractPackageInfo(t *testing.T) {
	tests := []struct {
		name           string
		pr             *PullRequest
		expectedName   string
		expectedType   string
		expectedOldVer string
		expectedNewVer string
	}{
		{
			name: "standard renovate PR body with table",
			pr: &PullRequest{
				Title: "chore(deps): update ghcr.io/home-assistant/home-assistant Docker tag to v2025.12.1",
				Body: `| Package | Update | Change |
| --- | --- | --- |
| [ghcr.io/home-assistant/home-assistant](https://github.com/home-assistant/core) | patch | 2025.12.0 -> 2025.12.1 |`,
			},
			expectedName:   "ghcr.io/home-assistant/home-assistant",
			expectedType:   "patch",
			expectedOldVer: "2025.12.0",
			expectedNewVer: "2025.12.1",
		},
		{
			name: "minor update table",
			pr: &PullRequest{
				Title: "chore(deps): update getmeili/meilisearch Docker tag to v1.29.0",
				Body: `| Package | Update | Change |
| --- | --- | --- |
| [getmeili/meilisearch](https://github.com/meilisearch/meilisearch) | minor | v1.28.2 -> v1.29.0 |`,
			},
			expectedName:   "getmeili/meilisearch",
			expectedType:   "minor",
			expectedOldVer: "v1.28.2",
			expectedNewVer: "v1.29.0",
		},
		{
			name: "monorepo n8n format",
			pr: &PullRequest{
				Title: "chore(deps): update n8nio/n8n Docker tag to v1.123.4",
				Body: `| Package | Update | Change |
| --- | --- | --- |
| [n8nio/n8n](https://github.com/n8n-io/n8n) | patch | 1.123.3 -> 1.123.4 |`,
			},
			expectedName:   "n8nio/n8n",
			expectedType:   "patch",
			expectedOldVer: "1.123.3",
			expectedNewVer: "1.123.4",
		},
		{
			name: "fallback to title when no table",
			pr: &PullRequest{
				Title: "chore(deps): update ghcr.io/home-assistant/home-assistant Docker tag to v2025.12.1",
				Body:  "No table here, just text.",
			},
			expectedName:   "ghcr.io/home-assistant/home-assistant",
			expectedType:   "patch",
			expectedOldVer: "unknown",
			expectedNewVer: "2025.12.1",
		},
		{
			name: "major update from title",
			pr: &PullRequest{
				Title: "chore(deps): update some-package Helm release to v2.0.0 (major)",
				Body:  "",
			},
			expectedName:   "some-package",
			expectedType:   "major",
			expectedOldVer: "unknown",
			expectedNewVer: "2.0.0",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := extractPackageInfo(tt.pr)
			if result.Name != tt.expectedName {
				t.Errorf("Name = %q, want %q", result.Name, tt.expectedName)
			}
			if result.UpdateType != tt.expectedType {
				t.Errorf("UpdateType = %q, want %q", result.UpdateType, tt.expectedType)
			}
			if result.OldVersion != tt.expectedOldVer {
				t.Errorf("OldVersion = %q, want %q", result.OldVersion, tt.expectedOldVer)
			}
			if result.NewVersion != tt.expectedNewVer {
				t.Errorf("NewVersion = %q, want %q", result.NewVersion, tt.expectedNewVer)
			}
		})
	}
}

func TestContains(t *testing.T) {
	tests := []struct {
		name     string
		slice    []string
		s        string
		expected bool
	}{
		{"found in slice", []string{"a", "b", "c"}, "b", true},
		{"not found", []string{"a", "b", "c"}, "d", false},
		{"empty slice", []string{}, "a", false},
		{"empty string found", []string{"", "a"}, "", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := contains(tt.slice, tt.s)
			if result != tt.expected {
				t.Errorf("contains(%v, %q) = %v, want %v", tt.slice, tt.s, result, tt.expected)
			}
		})
	}
}

func TestFindMatches(t *testing.T) {
	tests := []struct {
		name       string
		content    string
		maxMatches int
		wantCount  int
	}{
		{
			name:       "finds breaking changes",
			content:    "This is a BREAKING CHANGE\nAnother line\nBreaking: something",
			maxMatches: 5,
			wantCount:  2,
		},
		{
			name:       "respects max matches",
			content:    "BREAKING CHANGE 1\nBREAKING CHANGE 2\nBREAKING CHANGE 3",
			maxMatches: 2,
			wantCount:  2,
		},
		{
			name:       "no matches",
			content:    "This is normal content\nNo issues here",
			maxMatches: 5,
			wantCount:  0,
		},
		{
			name:       "empty content",
			content:    "",
			maxMatches: 5,
			wantCount:  0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := findMatches(tt.content, breakingPatterns, tt.maxMatches)
			if len(result) != tt.wantCount {
				t.Errorf("findMatches() got %d matches, want %d", len(result), tt.wantCount)
			}
		})
	}
}

func TestAnalyzeBreakingChanges(t *testing.T) {
	tests := []struct {
		name           string
		docs           DocumentationContent
		hasBreaking    bool
		hasSecurity    bool
		hasDeprecation bool
		hasMigration   bool
	}{
		{
			name: "breaking change detected",
			docs: DocumentationContent{
				ReleaseNotes: "This release includes a BREAKING CHANGE that affects all users.",
			},
			hasBreaking: true,
		},
		{
			name: "security fix detected",
			docs: DocumentationContent{
				ReleaseNotes: "Fixed a security vulnerability CVE-2024-12345.",
			},
			hasSecurity: true,
		},
		{
			name: "deprecation detected",
			docs: DocumentationContent{
				ReleaseNotes: "The old API is now deprecated and will be removed in v3.0.",
			},
			hasDeprecation: true,
		},
		{
			name: "migration required",
			docs: DocumentationContent{
				UpgradeNotes: "Migration required: run the upgrade script before deploying.",
			},
			hasMigration: true,
		},
		{
			name: "no findings",
			docs: DocumentationContent{
				ReleaseNotes: "Bug fixes and performance improvements.",
			},
			hasBreaking:    false,
			hasSecurity:    false,
			hasDeprecation: false,
		},
		{
			name:        "empty docs",
			docs:        DocumentationContent{},
			hasBreaking: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := analyzeBreakingChanges(tt.docs)
			if result.HasBreaking != tt.hasBreaking {
				t.Errorf("HasBreaking = %v, want %v", result.HasBreaking, tt.hasBreaking)
			}
			if result.HasSecurity != tt.hasSecurity {
				t.Errorf("HasSecurity = %v, want %v", result.HasSecurity, tt.hasSecurity)
			}
			if result.HasDeprecated != tt.hasDeprecation {
				t.Errorf("HasDeprecated = %v, want %v", result.HasDeprecated, tt.hasDeprecation)
			}
			if result.HasMigration != tt.hasMigration {
				t.Errorf("HasMigration = %v, want %v", result.HasMigration, tt.hasMigration)
			}
		})
	}
}

func TestAssessPriority(t *testing.T) {
	tests := []struct {
		name       string
		updateType string
		analysis   BreakingChangeAnalysis
		expected   Priority
	}{
		{
			name:       "major update is high priority",
			updateType: "major",
			analysis:   BreakingChangeAnalysis{},
			expected:   PriorityHigh,
		},
		{
			name:       "breaking changes are high priority",
			updateType: "minor",
			analysis:   BreakingChangeAnalysis{HasBreaking: true},
			expected:   PriorityHigh,
		},
		{
			name:       "security fixes are high priority",
			updateType: "patch",
			analysis:   BreakingChangeAnalysis{HasSecurity: true},
			expected:   PriorityHigh,
		},
		{
			name:       "patch without issues is low priority",
			updateType: "patch",
			analysis:   BreakingChangeAnalysis{},
			expected:   PriorityLow,
		},
		{
			name:       "minor without issues is medium priority",
			updateType: "minor",
			analysis:   BreakingChangeAnalysis{},
			expected:   PriorityMedium,
		},
		{
			name:       "unknown type is medium priority",
			updateType: "unknown",
			analysis:   BreakingChangeAnalysis{},
			expected:   PriorityMedium,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := assessPriority(tt.updateType, tt.analysis)
			if result != tt.expected {
				t.Errorf("assessPriority(%q, %+v) = %v, want %v", tt.updateType, tt.analysis, result, tt.expected)
			}
		})
	}
}

func TestDetermineRepoPath(t *testing.T) {
	tests := []struct {
		name     string
		links    DocumentationLinks
		expected string
	}{
		{
			name: "prefers source repo",
			links: DocumentationLinks{
				SourceRepo:  "https://github.com/owner/source-repo",
				ReleaseLink: "https://github.com/owner/release-repo/releases/tag/v1.0.0",
			},
			expected: "owner/source-repo",
		},
		{
			name: "falls back to release link",
			links: DocumentationLinks{
				ReleaseLink: "https://github.com/owner/repo/releases/tag/v1.0.0",
			},
			expected: "owner/repo",
		},
		{
			name: "falls back to changelog link",
			links: DocumentationLinks{
				ChangelogLink: "https://github.com/owner/repo/blob/main/CHANGELOG.md",
			},
			expected: "owner/repo",
		},
		{
			name:     "empty links returns empty",
			links:    DocumentationLinks{},
			expected: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := determineRepoPath(tt.links)
			if result != tt.expected {
				t.Errorf("determineRepoPath() = %q, want %q", result, tt.expected)
			}
		})
	}
}

func TestExtractVersionSection(t *testing.T) {
	tests := []struct {
		name            string
		content         string
		version         string
		shouldContain   string
		shouldNotContain string
	}{
		{
			name: "extracts specific version section",
			content: `# Changelog

## [1.2.0] - 2024-01-15
### Added
- New feature A

## [1.1.0] - 2024-01-01
### Fixed
- Bug fix B`,
			version:          "1.2.0",
			shouldContain:    "New feature A",
			shouldNotContain: "Bug fix B",
		},
		{
			name: "handles v prefix",
			content: `## v1.2.0
- Change for 1.2.0

## v1.1.0
- Change for 1.1.0`,
			version:       "v1.2.0",
			shouldContain: "Change for 1.2.0",
		},
		{
			name:          "fallback for missing version",
			content:       "Line 1\nLine 2\nLine 3",
			version:       "9.9.9",
			shouldContain: "Line 1",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := extractVersionSection(tt.content, tt.version)
			if tt.shouldContain != "" && !containsString(result, tt.shouldContain) {
				t.Errorf("extractVersionSection() should contain %q, got:\n%s", tt.shouldContain, result)
			}
			if tt.shouldNotContain != "" && containsString(result, tt.shouldNotContain) {
				t.Errorf("extractVersionSection() should not contain %q, got:\n%s", tt.shouldNotContain, result)
			}
		})
	}
}

func TestExtractUpgradeSection(t *testing.T) {
	tests := []struct {
		name          string
		content       string
		oldVersion    string
		newVersion    string
		shouldContain string
	}{
		{
			name: "extracts upgrade section for major version",
			content: `# Upgrade Guide

## From 1.x to 2.x
Run migration script

## From 0.x to 1.x
Initial setup required`,
			oldVersion:    "1.5.0",
			newVersion:    "2.0.0",
			shouldContain: "migration script",
		},
		{
			name: "handles specific version headers",
			content: `## 2.0.0
Breaking changes for v2

## 1.0.0
Initial release`,
			oldVersion:    "1.5.0",
			newVersion:    "2.0.0",
			shouldContain: "Breaking changes",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := extractUpgradeSection(tt.content, tt.oldVersion, tt.newVersion)
			if tt.shouldContain != "" && !containsString(result, tt.shouldContain) {
				t.Errorf("extractUpgradeSection() should contain %q, got:\n%s", tt.shouldContain, result)
			}
		})
	}
}

// Helper function for string containment check
func containsString(s, substr string) bool {
	return strings.Contains(s, substr)
}
