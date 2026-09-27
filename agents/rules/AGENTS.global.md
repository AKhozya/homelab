# Global Agent Guidance

## Peer-Reviewed Implementation

For non-trivial implementation work, use the shared
`peer-reviewed-implementation` skill when available. Keep the short form here
as the fallback:

1. Work in an isolated worktree when the task touches a git repo, unless the
   repo/tooling already provides isolation or the user asks to work in place.
2. Plan before coding. Surface assumptions, cut corners, and unknowns.
3. Research or spike load-bearing unknowns, then update the plan before broad
   implementation.
4. Before coding, get peer review from the other available agent family. If the
   `peer-reviewed-implementation` skill is installed, run its `reviewer-peer`
   script with the current family and `--format json` to resolve the reviewer.
   If no different reviewer is available, do a self-review and say why. Plan
   and code reviews by Claude or Codex must use `xhigh` effort/reasoning.
5. Process review feedback through the `receiving-code-review` /
   `receive-review` skill when available: understand it, verify against the
   codebase, push back when technically wrong, then implement valid fixes.
6. Implement, run the smallest meaningful checks, then get a second peer review
   of the actual diff before committing or pushing.

## Agent-Neutral Skills

Treat `Claude`, `Claude Code`, and `Codex` in older skills as adapter names
unless the instruction is about a specific CLI, transcript source, backend, or
auth path. For peer review, resolve the current and peer agent with the shared
script when available.

Keep reusable workflows in shared skills under `~/.agents/skills`. Do not copy
the same workflow into per-agent `CLAUDE.md`, `CODEX.md`, or repo skills unless
there is a clear source of truth and a drift check.
