# KB Hygiene — scripts

Read this when you need the flags, exit codes or behaviour of a script in `scripts/`.

| Script | Use |
|---|---|
| `scripts/index-integrity.sh [MEMORY_DIR]` | Read-only. Axis 1 mechanics: orphans, dangling index links, broken `[[wiki-links]]`. Exit 1 if orphans/dangling. A link resolves against a filename stem or a frontmatter `name:` slug, because files use underscores and slugs use hyphens. It skips code spans and fenced blocks, and reads `name:` only inside the frontmatter delimiters. |
| `scripts/tests/test-index-integrity.sh [SCRIPT]` | Checks both link spellings, an anchored link, code-span and fenced-block links, a genuinely absent link, an orphan, and a dangling link. Takes the script under test as its first argument, so an older copy shows which checks it fails. Run it after editing the resolver. |
| `scripts/skill-sizes.sh [ROOT] [THRESH]` | Read-only. Live SKILL.md word counts; flags FAT (>THRESH, default 1000) relocate candidates. Token-efficiency lens — never hardcode counts. |
| `scripts/lossless-verify.sh OLD NEW...` | Phase-2 gate. Extracts SHAs/commands/ports/flags/filenames from OLD, confirms each survives in NEW; sweeps NEW for tag-leaks. Exit 1 on LOST/leak. |
| `scripts/tag-leak-sweep.sh [PATH...]` | Sweep for leaked subagent tool-call tags (`</content>`, `</invoke>`). Run on subagent-written files. Exit 1 if found. |
| `scripts/lint-skill-scripts.sh [ROOT]` | Axis 4 mechanics: shellcheck + shfmt + rg-as-command audit across the `.sh` of every non-vendored skill. It skips a skill listed in `ROOT/../.skill-lock.json` or carrying `.INSTALLED-FROM.txt`, because the next skill update overwrites a local fix. Reading the lock needs `jq`. Exit 1 on any lint/format/rg issue; exit 2 if ROOT is missing, a tool is missing, or the lock exists but cannot be read or parsed. |
| `scripts/tests/test-lint-skill-scripts.sh [SCRIPT]` | Checks that a locked or marked skill is skipped and a skill of your own still fails. Run it after editing the linter. |
