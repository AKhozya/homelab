package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"

	"github.com/Masterminds/semver/v3"
	"github.com/google/go-github/v85/github"
	"golang.org/x/oauth2"
)

const (
	owner            = "AKhozya"
	repo             = "homelab"
	maxContentLength = 30000
)

// Types
type PullRequest struct {
	Number int
	Title  string
	Body   string
	State  string
	Files  []string
}

type PackageInfo struct {
	Name       string
	UpdateType string // major, minor, patch, unknown
	OldVersion string
	NewVersion string
}

type DocumentationLinks struct {
	ReleaseLink   string
	ChangelogLink string
	CompareLink   string
	SourceRepo    string
}

type DocumentationContent struct {
	ReleaseNotes   string
	Changelog      string
	UpgradeNotes   string
	BreakingChanges string
}

type BreakingChangeAnalysis struct {
	HasBreaking      bool
	HasMigration     bool
	HasRemoval       bool
	HasSecurity      bool
	HasDeprecated    bool
	HasConfigChange  bool
	BreakingMatches  []string
	SecurityMatches  []string
	RemovalMatches   []string
	DeprecationMatches []string
	MigrationMatches []string
}

type UpdateCategory string

const (
	DockerImage    UpdateCategory = "Docker Image"
	HelmChart      UpdateCategory = "Helm Chart"
	FluxComponents UpdateCategory = "Flux Components"
	Configuration  UpdateCategory = "Configuration"
)

type Priority string

const (
	PriorityHigh   Priority = "HIGH"
	PriorityMedium Priority = "MEDIUM"
	PriorityLow    Priority = "LOW"
)

// Global GitHub client
var client *github.Client
var ctx = context.Background()

func main() {
	if len(os.Args) < 2 {
		fmt.Println("Usage: analyze-update <PR_NUMBER>")
		fmt.Println("")
		fmt.Println("Example: analyze-update 85")
		os.Exit(1)
	}

	prNumber, err := strconv.Atoi(os.Args[1])
	if err != nil {
		fmt.Fprintf(os.Stderr, "Invalid PR number: %s\n", os.Args[1])
		os.Exit(1)
	}

	// Initialize GitHub client
	initGitHub()

	// Run analysis
	if err := analyze(prNumber); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func initGitHub() {
	token := os.Getenv("GH_TOKEN")
	if token == "" {
		token = os.Getenv("GITHUB_TOKEN")
	}

	if token != "" {
		ts := oauth2.StaticTokenSource(&oauth2.Token{AccessToken: token})
		tc := oauth2.NewClient(ctx, ts)
		client = github.NewClient(tc)
	} else {
		client = github.NewClient(nil)
	}
}

func analyze(prNumber int) error {
	fmt.Println("===================================")
	fmt.Printf("Analyzing Renovate PR #%d\n", prNumber)
	fmt.Println("===================================")
	fmt.Println()

	// Fetch PR details
	fmt.Println("📥 Fetching PR details...")
	pr, err := fetchPullRequest(prNumber)
	if err != nil {
		return fmt.Errorf("failed to fetch PR: %w", err)
	}

	fmt.Printf("Title: %s\n", pr.Title)
	fmt.Printf("State: %s\n", pr.State)
	fmt.Println()

	// Extract package info
	fmt.Println("📦 Extracting package information...")
	pkgInfo := extractPackageInfo(pr)
	fmt.Printf("Package: %s\n", pkgInfo.Name)
	fmt.Printf("Update Type: %s\n", pkgInfo.UpdateType)
	fmt.Printf("Version Change: %s → %s\n", pkgInfo.OldVersion, pkgInfo.NewVersion)
	fmt.Println()

	// Detect update category
	category := detectUpdateCategory(pr.Files)

	// Extract documentation links
	links := extractDocumentationLinks(pr.Body)

	// Display changed files
	fmt.Println("📄 Changed files:")
	for _, f := range pr.Files {
		fmt.Printf("  - %s\n", f)
	}
	fmt.Println()
	fmt.Printf("📦 Update Type: %s\n", category)
	fmt.Println()

	// Display detected links
	if links.ReleaseLink != "" {
		fmt.Printf("📝 Release Notes: %s\n", links.ReleaseLink)
	}
	if links.ChangelogLink != "" {
		fmt.Printf("📝 Changelog: %s\n", links.ChangelogLink)
	}
	if links.CompareLink != "" {
		fmt.Printf("📝 Compare: %s\n", links.CompareLink)
	}
	if links.SourceRepo != "" {
		fmt.Printf("📝 Source: %s\n", links.SourceRepo)
	}
	fmt.Println()

	// Fetch documentation
	fmt.Println("🔍 Fetching documentation...")
	fmt.Println()

	// Print repository first (before fetching)
	repoPath := determineRepoPath(links)
	if repoPath != "" {
		fmt.Printf("   Repository: %s\n", repoPath)
	}

	docs, foundSources := fetchDocumentation(links, pkgInfo, category, repoPath)

	for _, src := range foundSources {
		fmt.Printf("   ✓ Found %s\n", src)
	}
	fmt.Println()

	// Analyze breaking changes
	analysis := analyzeBreakingChanges(docs)

	// Display findings
	displayFindings(analysis, docs, pkgInfo.NewVersion)

	// Display UPGRADE.md for Helm charts
	if docs.UpgradeNotes != "" {
		fmt.Println("📦 Helm Chart Upgrade Notes:")
		fmt.Println("---")
		lines := strings.Split(docs.UpgradeNotes, "\n")
		for i, line := range lines {
			if i >= 60 {
				break
			}
			fmt.Println(line)
		}
		fmt.Println("---")
		fmt.Println()
	}

	// Display BREAKING_CHANGES.md if found
	if docs.BreakingChanges != "" {
		fmt.Println("⚠️  Helm Chart Breaking Changes:")
		fmt.Println("---")
		lines := strings.Split(docs.BreakingChanges, "\n")
		for i, line := range lines {
			if i >= 40 {
				break
			}
			fmt.Println(line)
		}
		fmt.Println("---")
		fmt.Println()
	}

	// Priority assessment
	priority := assessPriority(pkgInfo.UpdateType, analysis)
	displayPriority(priority, pkgInfo.UpdateType, analysis)

	// Package-specific checklist
	displayChecklist(pkgInfo.Name)

	// Quick actions
	displayQuickActions(prNumber, links)

	return nil
}

func fetchPullRequest(prNumber int) (*PullRequest, error) {
	pr, _, err := client.PullRequests.Get(ctx, owner, repo, prNumber)
	if err != nil {
		return nil, err
	}

	files, _, err := client.PullRequests.ListFiles(ctx, owner, repo, prNumber, nil)
	if err != nil {
		return nil, err
	}

	fileNames := make([]string, len(files))
	for i, f := range files {
		fileNames[i] = f.GetFilename()
	}

	// Determine state: GitHub API uses "closed" for both merged and closed PRs
	state := strings.ToUpper(pr.GetState())
	if pr.GetMerged() {
		state = "MERGED"
	}

	return &PullRequest{
		Number: pr.GetNumber(),
		Title:  pr.GetTitle(),
		Body:   pr.GetBody(),
		State:  state,
		Files:  fileNames,
	}, nil
}

func extractPackageInfo(pr *PullRequest) PackageInfo {
	info := PackageInfo{
		OldVersion: "unknown",
		NewVersion: "unknown",
		UpdateType: "unknown",
	}

	// Try to extract from PR body table
	lines := strings.Split(pr.Body, "\n")
	for _, line := range lines {
		if strings.HasPrefix(line, "|") && !strings.Contains(line, "Package") && !strings.Contains(line, "---") {
			parts := strings.Split(line, "|")
			if len(parts) >= 5 {
				// Package name (column 2) - extract just the first [name] from markdown
				nameCol := strings.TrimSpace(parts[1])
				// Extract text from first markdown link [text](url)
				if match := markdownLinkRe.FindStringSubmatch(nameCol); len(match) > 1 {
					info.Name = match[1]
				} else {
					// Fallback: strip all markdown links
					info.Name = markdownLinkRe.ReplaceAllString(nameCol, "$1")
				}

				// Update type (column 3)
				info.UpdateType = strings.TrimSpace(parts[2])

				// Version change (column 4)
				versionCol := strings.TrimSpace(parts[3])
				versionCol = strings.ReplaceAll(versionCol, "`", "")
				versionParts := strings.Split(versionCol, "->")
				if len(versionParts) == 2 {
					info.OldVersion = strings.TrimSpace(versionParts[0])
					info.NewVersion = strings.TrimSpace(versionParts[1])

					// Use semver library to verify/compute update type
					computed := computeUpdateType(info.OldVersion, info.NewVersion)
					if computed != "unknown" {
						info.UpdateType = computed
					}
				}
				break
			}
		}
	}

	// Fallback to parsing title
	if info.Name == "" {
		info.Name = pr.Title
		// Remove common Renovate title prefixes
		prefixes := []string{
			"chore(deps): update ",
			"chore(deps): major update ",
			"chore(deps): minor update ",
			"chore(deps): patch update ",
			"chore(deps): ",
		}
		for _, prefix := range prefixes {
			if strings.HasPrefix(info.Name, prefix) {
				info.Name = strings.TrimPrefix(info.Name, prefix)
				break
			}
		}
		info.Name = titleCleanupRe.ReplaceAllString(info.Name, "")

		versionMatch := versionExtractRe.FindStringSubmatch(pr.Title)
		if len(versionMatch) > 1 {
			info.NewVersion = versionMatch[1]
		}

		if strings.Contains(strings.ToLower(pr.Title), "major") {
			info.UpdateType = "major"
		} else if strings.Contains(strings.ToLower(pr.Title), "minor") {
			info.UpdateType = "minor"
		} else {
			info.UpdateType = "patch"
		}
	}

	return info
}

func detectUpdateCategory(files []string) UpdateCategory {
	for _, f := range files {
		if strings.Contains(f, "deployment.yaml") || strings.Contains(f, "statefulset.yaml") || strings.Contains(f, "daemonset.yaml") {
			return DockerImage
		}
		if strings.Contains(f, "release.yaml") || strings.Contains(f, "helmrelease.yaml") {
			return HelmChart
		}
		if strings.Contains(f, "gotk-components.yaml") {
			return FluxComponents
		}
	}
	return Configuration
}

func extractDocumentationLinks(body string) DocumentationLinks {
	links := DocumentationLinks{}

	// Release link
	if match := releaseLinkRe.FindString(body); match != "" {
		links.ReleaseLink = strings.ReplaceAll(match, "redirect.github.com", "github.com")
	}

	// Changelog link
	if match := changelogLinkRe.FindString(body); match != "" {
		links.ChangelogLink = strings.ReplaceAll(match, "redirect.github.com", "github.com")
	}

	// Compare link
	if match := compareLinkRe.FindString(body); match != "" {
		links.CompareLink = strings.ReplaceAll(match, "redirect.github.com", "github.com")
	}

	// Source repo from [source](url) format
	if matches := sourceLinkRe.FindStringSubmatch(body); len(matches) > 1 {
		links.SourceRepo = strings.ReplaceAll(matches[1], "redirect.github.com", "github.com")
	}

	return links
}

func extractRepoPath(url string) string {
	if matches := repoPathRe.FindStringSubmatch(url); len(matches) > 1 {
		return matches[1]
	}
	return ""
}

// cleanVersionString normalizes version strings by handling:
// - Monorepo format: "n8n@1.123.4" -> "1.123.4"
// - Leading 'v': "v1.2.3" -> "1.2.3"
func cleanVersionString(ver string) string {
	// Handle monorepo format: package@version
	if idx := strings.LastIndex(ver, "@"); idx != -1 {
		ver = ver[idx+1:]
	}
	// Remove leading 'v' if present
	ver = strings.TrimPrefix(ver, "v")
	return ver
}

// computeUpdateType uses semver library to accurately determine update type
func computeUpdateType(oldVer, newVer string) string {
	// Clean version strings (handle monorepo format and 'v' prefix)
	oldVer = cleanVersionString(oldVer)
	newVer = cleanVersionString(newVer)

	oldSem, err1 := semver.NewVersion(oldVer)
	newSem, err2 := semver.NewVersion(newVer)

	if err1 != nil || err2 != nil {
		// Fallback to string comparison if not valid semver
		return "unknown"
	}

	if newSem.Major() > oldSem.Major() {
		return "major"
	}
	if newSem.Minor() > oldSem.Minor() {
		return "minor"
	}
	if newSem.Patch() > oldSem.Patch() {
		return "patch"
	}

	return "unknown"
}

func determineRepoPath(links DocumentationLinks) string {
	if links.SourceRepo != "" {
		return extractRepoPath(links.SourceRepo)
	}
	if links.ReleaseLink != "" {
		return extractRepoPath(links.ReleaseLink)
	}
	if links.ChangelogLink != "" {
		return extractRepoPath(links.ChangelogLink)
	}
	return ""
}

func fetchDocumentation(links DocumentationLinks, pkgInfo PackageInfo, category UpdateCategory, repoPath string) (DocumentationContent, []string) {
	docs := DocumentationContent{}
	var foundSources []string

	if repoPath == "" {
		return docs, foundSources
	}

	// 1. Try GitHub Release API first
	if links.ReleaseLink != "" {
		if matches := tagExtractRe.FindStringSubmatch(links.ReleaseLink); len(matches) > 1 {
			tag := matches[1]
			if content := fetchGitHubRelease(repoPath, tag, pkgInfo.Name, true); content != "" {
				docs.ReleaseNotes = truncate(content)
				foundSources = append(foundSources, "GitHub release notes")
			}
		}
	} else if pkgInfo.NewVersion != "" && pkgInfo.NewVersion != "unknown" {
		if content := fetchGitHubRelease(repoPath, pkgInfo.NewVersion, pkgInfo.Name, true); content != "" {
			docs.ReleaseNotes = truncate(content)
			foundSources = append(foundSources, "GitHub release notes")
		}
	}

	// 2. Try changelog files if no release content
	if docs.ReleaseNotes == "" {
		if filename, content := findChangelog(repoPath); content != "" {
			docs.Changelog = truncate(extractVersionSection(content, pkgInfo.NewVersion))
			foundSources = append(foundSources, filename)
		}
	}

	// 3. For Helm charts, also fetch UPGRADE.md and BREAKING_CHANGES.md
	isHelmChart := category == HelmChart ||
		strings.Contains(strings.ToLower(pkgInfo.Name), "helm") ||
		strings.Contains(strings.ToLower(pkgInfo.Name), "chart") ||
		strings.Contains(strings.ToLower(pkgInfo.Name), "prometheus-stack")

	if isHelmChart {
		if strings.Contains(strings.ToLower(pkgInfo.Name), "kube-prometheus-stack") {
			if content := fetchRawFile("prometheus-community/helm-charts", "charts/kube-prometheus-stack/UPGRADE.md"); content != "" {
				docs.UpgradeNotes = truncate(extractUpgradeSection(content, pkgInfo.OldVersion, pkgInfo.NewVersion))
				foundSources = append(foundSources, "UPGRADE.md")
			}
		} else {
			content := fetchRawFile(repoPath, "UPGRADE.md")
			if content == "" {
				content = fetchRawFile(repoPath, "charts/UPGRADE.md")
			}
			if content != "" {
				docs.UpgradeNotes = truncate(extractUpgradeSection(content, pkgInfo.OldVersion, pkgInfo.NewVersion))
				foundSources = append(foundSources, "UPGRADE.md")
			}
		}

		if content := fetchRawFile(repoPath, "BREAKING_CHANGES.md"); content != "" {
			docs.BreakingChanges = truncate(content)
			foundSources = append(foundSources, "BREAKING_CHANGES.md")
		}
	}

	return docs, foundSources
}

func fetchGitHubRelease(repoPath, version, packageName string, verbose bool) string {
	parts := strings.Split(repoPath, "/")
	if len(parts) != 2 {
		return ""
	}
	owner, repo := parts[0], parts[1]

	if verbose {
		fmt.Printf("   Fetching GitHub release for version: %s\n", version)
	}

	// Try different tag formats
	tags := []string{version}
	if !strings.HasPrefix(version, "v") {
		tags = append(tags, "v"+version)
	}
	// Monorepo format (e.g., n8n@1.123.4)
	if packageName != "" {
		shortName := packageName
		if idx := strings.LastIndex(packageName, "/"); idx >= 0 {
			shortName = packageName[idx+1:]
		}
		tags = append(tags, shortName+"@"+version)
	}

	for _, tag := range tags {
		release, _, err := client.Repositories.GetReleaseByTag(ctx, owner, repo, tag)
		if err == nil && release.GetBody() != "" {
			return release.GetBody()
		}
	}

	return ""
}

func fetchRawFile(repoPath, filepath string) string {
	branches := []string{"main", "master"}

	for _, branch := range branches {
		url := fmt.Sprintf("https://raw.githubusercontent.com/%s/%s/%s", repoPath, branch, filepath)
		resp, err := http.Get(url)
		if err != nil {
			continue
		}
		defer resp.Body.Close()

		if resp.StatusCode == 200 {
			body, err := io.ReadAll(resp.Body)
			if err != nil {
				continue
			}
			content := string(body)
			if !strings.Contains(content, "404: Not Found") {
				return content
			}
		}
	}

	return ""
}

func findChangelog(repoPath string) (string, string) {
	filenames := []string{
		"CHANGELOG.md", "changelog.md",
		"HISTORY.md", "History.md",
		"CHANGES.md", "Changes.md",
		"RELEASES.md", "releases.md",
		"NEWS.md", "news.md",
		"RELEASE_NOTES.md",
	}

	for _, filename := range filenames {
		if content := fetchRawFile(repoPath, filename); content != "" {
			return filename, content
		}
	}

	return "", ""
}

func extractVersionSection(content, version string) string {
	cleanVersion := strings.TrimPrefix(version, "v")
	lines := strings.Split(content, "\n")
	var result []string
	capturing := false


	for _, line := range lines {
		if versionHeaderRe.MatchString(line) {
			if capturing {
				break
			}
			if strings.Contains(line, cleanVersion) {
				capturing = true
			}
		}

		if capturing {
			result = append(result, line)
		}
	}

	if len(result) > 0 {
		if len(result) > 100 {
			result = result[:100]
		}
		return strings.Join(result, "\n")
	}

	// Fallback: first 100 lines
	if len(lines) > 100 {
		lines = lines[:100]
	}
	return strings.Join(lines, "\n")
}

func extractUpgradeSection(content, oldVersion, newVersion string) string {
	oldMajor := strings.Split(oldVersion, ".")[0]
	newMajor := strings.Split(newVersion, ".")[0]

	lines := strings.Split(content, "\n")
	var result []string
	capturing := false

	for _, line := range lines {
		isHeader := strings.HasPrefix(line, "##")
		if isHeader {
			if capturing {
				break
			}
			// Check if relevant section
			if (strings.Contains(line, oldMajor+".x") && strings.Contains(line, newMajor+".x")) ||
				strings.Contains(line, newMajor+".0") ||
				strings.Contains(line, newMajor+".") {
				capturing = true
			}
		}

		if capturing {
			result = append(result, line)
		}
	}

	if len(result) > 0 {
		if len(result) > 60 {
			result = result[:60]
		}
		return strings.Join(result, "\n")
	}

	// Fallback
	if len(lines) > 60 {
		lines = lines[:60]
	}
	return strings.Join(lines, "\n")
}

func truncate(content string) string {
	if len(content) > maxContentLength {
		return content[:maxContentLength]
	}
	return content
}

// Breaking change patterns
var (
	breakingPatterns = []*regexp.Regexp{
		regexp.MustCompile(`(?i)breaking[\s-]?change`),
		regexp.MustCompile(`(?i)\bBREAKING:`),
		regexp.MustCompile(`\*\*Breaking:\*\*`),
		regexp.MustCompile(`(?i)⚠️.*breaking`),
	}
	migrationPatterns = []*regexp.Regexp{
		regexp.MustCompile(`(?i)migration[\s-]?required`),
		regexp.MustCompile(`(?i)action[\s-]?required`),
		regexp.MustCompile(`(?i)\bmigrate\b`),
		regexp.MustCompile(`(?i)upgrade[\s-]?note`),
		regexp.MustCompile(`(?i)manual[\s-]?step`),
	}
	removalPatterns = []*regexp.Regexp{
		regexp.MustCompile(`(?i)\bremoved\b`),
		regexp.MustCompile(`(?i)no[\s-]?longer[\s-]?(supported|available)`),
		regexp.MustCompile(`(?i)drop(ped)?[\s-]?support`),
		regexp.MustCompile(`(?i)deprecated.*removed`),
		regexp.MustCompile(`(?i)removed[\s-]?feature`),
	}
	securityPatterns = []*regexp.Regexp{
		regexp.MustCompile(`(?i)\bsecurity\b`),
		regexp.MustCompile(`(?i)vulnerability`),
		regexp.MustCompile(`CVE-\d{4}-\d+`),
		regexp.MustCompile(`(?i)\binsecure\b`),
		regexp.MustCompile(`(?i)\bexploit`),
	}
	deprecationPatterns = []*regexp.Regexp{
		regexp.MustCompile(`(?i)\bdeprecated?\b`),
		regexp.MustCompile(`(?i)\bdeprecating\b`),
		regexp.MustCompile(`(?i)will[\s-]?be[\s-]?removed`),
	}
	configPatterns = []*regexp.Regexp{
		regexp.MustCompile(`(?i)configuration[\s-]?change`),
		regexp.MustCompile(`(?i)config[\s-]?change`),
		regexp.MustCompile(`(?i)environment[\s-]?variable`),
		regexp.MustCompile(`(?i)breaking.*config`),
		regexp.MustCompile(`(?i)renamed[\s-]?(option|parameter|flag)`),
	}

	// Pre-compiled regexes for parsing (avoid runtime compilation)
	markdownLinkRe    = regexp.MustCompile(`\[([^\]]+)\]\([^)]+\)`)
	titleCleanupRe    = regexp.MustCompile(` Docker tag.*| to.*| Helm release.*| for `)
	versionExtractRe  = regexp.MustCompile(`to v?([0-9.]+)`)
	releaseLinkRe     = regexp.MustCompile(`https://[^)\s]+/releases/tag/[^)\s]+`)
	changelogLinkRe   = regexp.MustCompile(`(?i)https://[^)\s]+/CHANGELOG[^)\s]*`)
	compareLinkRe     = regexp.MustCompile(`https://[^)\s]+/compare/[^)\s]+`)
	sourceLinkRe      = regexp.MustCompile(`\[source\]\((https://[^)]+)\)`)
	repoPathRe        = regexp.MustCompile(`github\.com/([^/]+/[^/]+)`)
	tagExtractRe      = regexp.MustCompile(`/releases/tag/(.+)$`)
	versionHeaderRe   = regexp.MustCompile(`^##+ *\[?v?(\d+\.\d+)`)
	htmlTagRe         = regexp.MustCompile(`<[^>]*>`)
)

func cleanContent(content string) string {
	content = htmlTagRe.ReplaceAllString(content, "")
	content = strings.ReplaceAll(content, "&lt;", "<")
	content = strings.ReplaceAll(content, "&gt;", ">")
	content = strings.ReplaceAll(content, "&amp;", "&")
	content = strings.ReplaceAll(content, "&quot;", "\"")
	content = strings.ReplaceAll(content, "&#39;", "'")
	return content
}

func findMatches(content string, patterns []*regexp.Regexp, maxMatches int) []string {
	var matches []string
	lines := strings.Split(content, "\n")

	for _, line := range lines {
		for _, pattern := range patterns {
			if pattern.MatchString(line) {
				trimmed := strings.TrimSpace(line)
				if trimmed != "" && !contains(matches, trimmed) {
					matches = append(matches, trimmed)
					if len(matches) >= maxMatches {
						return matches
					}
				}
				break
			}
		}
	}

	return matches
}

func contains(slice []string, s string) bool {
	for _, v := range slice {
		if v == s {
			return true
		}
	}
	return false
}

func analyzeBreakingChanges(docs DocumentationContent) BreakingChangeAnalysis {
	allContent := strings.Join([]string{
		docs.ReleaseNotes,
		docs.Changelog,
		docs.UpgradeNotes,
		docs.BreakingChanges,
	}, "\n\n")

	if allContent == "" {
		return BreakingChangeAnalysis{}
	}

	cleaned := cleanContent(allContent)

	return BreakingChangeAnalysis{
		HasBreaking:        len(findMatches(cleaned, breakingPatterns, 1)) > 0,
		HasMigration:       len(findMatches(cleaned, migrationPatterns, 1)) > 0,
		HasRemoval:         len(findMatches(cleaned, removalPatterns, 1)) > 0,
		HasSecurity:        len(findMatches(cleaned, securityPatterns, 1)) > 0,
		HasDeprecated:      len(findMatches(cleaned, deprecationPatterns, 1)) > 0,
		HasConfigChange:    len(findMatches(cleaned, configPatterns, 1)) > 0,
		BreakingMatches:    findMatches(cleaned, breakingPatterns, 5),
		SecurityMatches:    findMatches(cleaned, securityPatterns, 5),
		RemovalMatches:     findMatches(cleaned, removalPatterns, 5),
		DeprecationMatches: findMatches(cleaned, deprecationPatterns, 3),
		MigrationMatches:   findMatches(cleaned, migrationPatterns, 3),
	}
}

func displayFindings(analysis BreakingChangeAnalysis, docs DocumentationContent, newVersion string) {
	hasFindings := analysis.HasBreaking || analysis.HasMigration || analysis.HasRemoval ||
		analysis.HasSecurity || analysis.HasDeprecated

	if hasFindings {
		fmt.Println("🚨 IMPORTANT FINDINGS:")
		fmt.Println()

		if analysis.HasBreaking {
			fmt.Println("  ⚠️  BREAKING CHANGES detected!")
			for _, m := range analysis.BreakingMatches {
				fmt.Printf("     %s\n", m)
			}
			fmt.Println()
		}

		if analysis.HasSecurity {
			fmt.Println("  🔐 Security fixes detected:")
			for _, m := range analysis.SecurityMatches {
				fmt.Printf("     %s\n", m)
			}
			fmt.Println()
		}

		if analysis.HasRemoval {
			fmt.Println("  🗑️  Removed features detected:")
			for _, m := range analysis.RemovalMatches {
				fmt.Printf("     %s\n", m)
			}
			fmt.Println()
		}

		if analysis.HasDeprecated {
			fmt.Println("  ⏳ Deprecations detected:")
			for _, m := range analysis.DeprecationMatches {
				fmt.Printf("     %s\n", m)
			}
			fmt.Println()
		}

		if analysis.HasMigration {
			fmt.Println("  📋 Migration steps may be required")
			for _, m := range analysis.MigrationMatches {
				fmt.Printf("     %s\n", m)
			}
			fmt.Println()
		}

		if analysis.HasConfigChange {
			fmt.Println("  🔧 Configuration changes detected")
			fmt.Println()
		}
	} else {
		fmt.Println("✅ No obvious breaking changes detected in release notes")
		fmt.Println()
	}

	// Show release content summary
	if docs.ReleaseNotes != "" {
		fmt.Println("📋 Release Notes Summary:")
		fmt.Println("---")
		lines := strings.Split(docs.ReleaseNotes, "\n")
		for i, line := range lines {
			if i >= 50 {
				break
			}
			fmt.Println(line)
		}
		fmt.Println("---")
		fmt.Println()
	} else if docs.Changelog != "" {
		fmt.Printf("📋 Changelog Summary (version %s):\n", newVersion)
		fmt.Println("---")
		lines := strings.Split(docs.Changelog, "\n")
		for i, line := range lines {
			if i >= 50 {
				break
			}
			fmt.Println(line)
		}
		fmt.Println("---")
		fmt.Println()
	}
}

func assessPriority(updateType string, analysis BreakingChangeAnalysis) Priority {
	if updateType == "major" {
		return PriorityHigh
	}
	if analysis.HasBreaking || analysis.HasSecurity {
		return PriorityHigh
	}
	if updateType == "patch" {
		return PriorityLow
	}
	return PriorityMedium
}

func displayPriority(priority Priority, updateType string, analysis BreakingChangeAnalysis) {
	switch priority {
	case PriorityHigh:
		if updateType == "major" {
			fmt.Println("🔴 MAJOR UPDATE - High risk of breaking changes")
		} else {
			fmt.Println("🔴 HIGH PRIORITY - Breaking changes or security fixes detected")
		}
	case PriorityLow:
		fmt.Println("🟢 PATCH UPDATE - Low risk")
	default:
		fmt.Println("🟡 MINOR UPDATE - Medium risk")
	}
	fmt.Println()
}

func displayChecklist(packageName string) {
	fmt.Println("📋 Package-Specific Checklist:")
	fmt.Println()

	name := strings.ToLower(packageName)

	switch {
	case strings.Contains(name, "authentik"):
		fmt.Println("🔐 Authentik Update")
		fmt.Println("  - [ ] Check authentication flow changes")
		fmt.Println("  - [ ] Review OAuth/OIDC provider changes")
		fmt.Println("  - [ ] Monitor database migrations")
		fmt.Println("  - [ ] Test login flows after deployment")

	case strings.Contains(name, "prometheus-stack") || strings.Contains(name, "grafana"):
		fmt.Println("📊 Monitoring Stack Update")
		fmt.Println("  - [ ] Run CRD update commands from UPGRADE.md")
		fmt.Println("  - [ ] Verify dashboards load correctly")
		fmt.Println("  - [ ] Test alert notifications")
		fmt.Println("  - [ ] Check Prometheus targets are healthy")

	case strings.Contains(name, "flux") || strings.Contains(name, "kustomize") || strings.Contains(name, "helm-controller"):
		fmt.Println("🔄 Flux/GitOps Update")
		fmt.Println("  - [ ] Monitor reconciliation after update")
		fmt.Println("  - [ ] Check for failed kustomizations")
		fmt.Println("  - [ ] Verify all HelmReleases reconcile")

	case strings.Contains(name, "traefik"):
		fmt.Println("🌐 Traefik Ingress Update")
		fmt.Println("  - [ ] Test ingress routes")
		fmt.Println("  - [ ] Verify TLS certificates")
		fmt.Println("  - [ ] Check middleware configurations")

	case strings.Contains(name, "postgres") || strings.Contains(name, "couchdb") || strings.Contains(name, "mariadb"):
		fmt.Println("🗄️  Database Update")
		fmt.Println("  - [ ] BACKUP DATABASE BEFORE MERGE")
		fmt.Println("  - [ ] Review migration scripts")
		fmt.Println("  - [ ] Test application connections")

	case strings.Contains(name, "n8n") || strings.Contains(name, "paperless") || strings.Contains(name, "immich") ||
		strings.Contains(name, "home-assistant") || strings.Contains(name, "adguard"):
		fmt.Println("📱 Application Update")
		fmt.Println("  - [ ] Review changelog for new features")
		fmt.Println("  - [ ] Check for config file changes")
		fmt.Println("  - [ ] Test core functionality after deployment")

	default:
		fmt.Println("📦 General Update")
		fmt.Println("  - [ ] Review release notes")
		fmt.Println("  - [ ] Check for breaking changes")
		fmt.Println("  - [ ] Test affected functionality")
	}

	fmt.Println()
}

func displayQuickActions(prNumber int, links DocumentationLinks) {
	fmt.Println("===================================")
	fmt.Println("Quick Actions")
	fmt.Println("===================================")
	fmt.Println()
	fmt.Printf("Merge: gh pr merge %d --squash\n", prNumber)
	fmt.Println()
	fmt.Println("Monitor deployment:")
	fmt.Println("  flux reconcile source git flux-system --timeout 45s --force")
	fmt.Println("  flux reconcile kustomization apps --timeout 45s --force")
	fmt.Println()

	if links.ReleaseLink != "" || links.ChangelogLink != "" {
		fmt.Println("📖 Documentation:")
		if links.ReleaseLink != "" {
			fmt.Printf("  Release: %s\n", links.ReleaseLink)
		}
		if links.ChangelogLink != "" {
			fmt.Printf("  Changelog: %s\n", links.ChangelogLink)
		}
		if links.CompareLink != "" {
			fmt.Printf("  Compare: %s\n", links.CompareLink)
		}
		fmt.Println()
	}
}
