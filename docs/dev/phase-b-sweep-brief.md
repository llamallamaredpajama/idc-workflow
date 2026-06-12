# Phase B Sweep Brief — shared rules for all sweep teammates

You are rewriting IDC workflow files in <this repo's checkout> so they work as a Claude Code plugin named `idc` and are fully generic/public. This is a **reference + namespacing + genericization sweep — never a content rewrite**. Semantics, role authority, write-surface boundaries, tool lists, workflows, formatting, and document structure stay EXACTLY as they are. Every changed line must trace to one of the rules below.

Read first: `docs/dev/phase-0-spike-findings.md` (empirically verified plugin mechanics + rules R1–R11).

## Transforms (apply to body text AND frontmatter descriptions)

| # | From | To |
|---|------|-----|
| T1 | bare `idc-skill-X`, `codex-idc-X`, `idc-workflow` skill refs | `idc:idc-skill-X`, `idc:codex-idc-X`, `idc:idc-workflow` |
| T2 | `subagent_type: "idc-role-X"` / `subagent_type: "idc-plan"` etc., and prose refs to spawning those agents | `subagent_type: "idc:idc-role-X"` etc. |
| T3 | `/agent-think` `/agent-plan` `/agent-sequence` `/agent-build` `/agent-ripple` `/agent-autorun` | `/idc:think` `/idc:plan` `/idc:sequence` `/idc:build` `/idc:ripple` `/idc:autorun` |
| T4 | `~/.claude/agents/<file>.md` | `${CLAUDE_PLUGIN_ROOT}/agents/<file>.md` |
| T5 | `~/.claude/skills/<dir>` | `${CLAUDE_PLUGIN_ROOT}/skills/<dir>` |
| T6 | `~/.claude/commands/agent-X.md` | `${CLAUDE_PLUGIN_ROOT}/commands/X.md` |
| T7 | "see memory feedback_agent_teams_for_large_scale" (and similar memory refs) | inline the rule: "(spawn as a TEAMMATE via TeamCreate + Agent with team_name — never as a Task subagent: Task subagents cannot hold durable context, coordinate with peers, or be messaged mid-run, which roleplayer agents require)" — adapt wording to fit the sentence |
| T8 | "Knowledge Engine" / "knowledge-engine" as the project name | "the governed repo" (generic); where an example helps, "(e.g. a data-platform repo)". In codex-idc-* descriptions "for Knowledge Engine or an IDC-governed repo" → "for an IDC-governed repo" |
| T9 | `/Users/<name>/...` personal paths | portable form: `$HOME/...` only if genuinely machine-local; `<governed-repo>/...` for project paths; `${CLAUDE_PLUGIN_ROOT}/...` for plugin files |
| T10 | citations of team-execute / te-* docs ("see ~/.claude/agents/team-execute-runbook.md", "per team-execute v2 doctrine") | inline a one-sentence explanation of the cited rule (e.g. the worktree-isolation race: "pre-create worktrees with git worktree add and verify with git worktree list before any teammate writes — the Agent-tool isolation parameter can silently run the teammate in the shared checkout") |
| T11 | governance self-edit doctrine mentioning `~/.claude` files + `.bak` snapshots | the workflow's own definition now lives in the idc-workflow plugin repo; self-edits happen as git commits/PRs against that repo (no `.bak` files) |

## Subtleties — get these right

- **Frontmatter `name:` fields stay BARE** (`name: idc-skill-ripple-verdict`, `name: idc-role-writer`). The harness adds the `idc:` namespace at load time. Namespacing a frontmatter name breaks loading.
- **Skill/agent FILE and DIR names stay bare** (no renames in skills/ or agents/).
- **`docs/workflow/...`, `TRACKER.md`, `docs/considerations/...` project-relative paths: KEEP UNCHANGED** — they refer to the governed repo's tree, not the plugin.
- **`~/.claude/teams/` and `~/.claude/tasks/` harness runtime paths: KEEP UNCHANGED** (identical for every user).
- **`$CLAUDE_PLUGIN_ROOT` is NOT a shell env var** (verified empirically). If a Bash snippet inside a file needs the plugin root, the surrounding markdown must pass it as text: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh "${CLAUDE_PLUGIN_ROOT}"`.
- **codex-idc-* skill bodies must NOT use `${CLAUDE_PLUGIN_ROOT}`** — Codex reads them as raw text with no substitution. Use paths relative to the skill dir (e.g. `../../agents/idc-plan.md`) for sibling references, and note "(relative to this skill directory inside the idc-workflow plugin)".
- **Slash-command surface lines** ("Slash command surface — `/agent-build`") → `/idc:build`.
- Skill cross-references inside prose like "wraps `idc-skill-plan-review`" or "BS-3" alias tables: namespace the skill name; keep alias labels (BS-3 etc.) unchanged.
- Do NOT touch `.claude-plugin/`, `LICENSE`, `README.md`, or files outside your assigned set.

## Verification (every teammate, before reporting)

1. `git -C <repo-root> status --short` — ONLY your assigned files modified.
2. Run the linter scoped to your files: `bash scripts/lint-references.sh 2>&1 | grep -F "<your-dir-or-file-prefix>"` — zero findings for your set (the repo-wide run may still show other units' findings; that's fine).
3. Spot-check that frontmatter `name:` lines are still bare and YAML frontmatter still parses (starts/ends with `---`).
4. Report to team-lead via SendMessage: files touched count, transforms applied (rough counts per rule), any judgment calls or lines you were unsure about (quote them), lint result for your set. DO NOT commit — team-lead commits per unit.
