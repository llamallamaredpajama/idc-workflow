# Phase 0 Spike Findings — Plugin Mechanics (verified empirically 2026-06-10, Claude Code 2.1.172)

Throwaway plugin `spike` (1 agent, 1 skill, 1 command, 1 data file) loaded via `--plugin-dir` and via real local marketplace install. Every claim below was observed, not assumed.

## Verified facts

| # | Question | Result | Evidence |
|---|----------|--------|----------|
| 1 | Skill-tool name for plugin skills | `<plugin>:<skill>` → `spike:spike-skill` accepted on first try | T3 headless run |
| 2 | `subagent_type` for plugin agents | `<plugin>:<agent>` → `spike:spike-agent` accepted | T4 headless run |
| 3 | Slash command form | `/<plugin>:<command-filename>` → `/spike:spike-cmd`; skills ALSO surface as `/<plugin>:<skill>` commands | T1, T2 |
| 4 | `${CLAUDE_PLUGIN_ROOT}` in **command** bodies | EXPANDS to absolute install path | T2: marker arrived expanded; file read OK (magic string found) |
| 5 | `${CLAUDE_PLUGIN_ROOT}` in **skill** bodies | EXPANDS | T3: marker expanded; harness also injects `Base directory for this skill: <path>` |
| 6 | `${CLAUDE_PLUGIN_ROOT}` in **agent** bodies | **EXPANDS** (curious-pike expected it NOT to — runbook-as-skill workaround is UNNECESSARY) | T4: marker arrived expanded; agent read sibling file OK |
| 7 | `$CLAUDE_PLUGIN_ROOT` as **shell env var** inside agent Bash | **EMPTY** — text substitution only, not an env var | T4: `echo $CLAUDE_PLUGIN_ROOT` → "" |
| 8 | Local marketplace dev loop | `claude plugin marketplace add <abs-path>` → `claude plugin install spike@spike-marketplace --scope user` → `claude plugin disable --scope user` all work headlessly; uninstall/remove restore settings cleanly | CLI runs |
| 9 | Per-project scoping | Project with `.claude/settings.json` `{"enabledPlugins": {"spike@spike-marketplace": true}}` sees the skills; project without it (plugin disabled at user scope) sees **zero** | T5a/T5b headless runs |
| 10 | Headless plugin testing | `claude -p --plugin-dir <path>` loads the plugin for that session; prompt must go via stdin if variadic flags like `--allowedTools` are used (they swallow trailing args) | T1–T4 |
| 11 | Live-edit dev loop (docs, not retested) | SKILL.md edits live; agents/commands/hooks need `/reload-plugins` or restart | docs: plugins-reference §Skills-directory plugins |
| 12 | `~/.agents/skills` (Codex chain) | It is a SYMLINK to `~/.claude/skills`; everything in `~/.claude/skills` auto-loads as a bare personal skill in EVERY Claude project | `ls -la ~/.agents/skills` |

## Rewrite rules for Phase B (derived from the above)

- **R1 — Skill refs:** every bare `idc-skill-X` / `codex-idc-X` / `idc-workflow` skill reference (Skill-tool invocations, "wraps skill", "loads BS-3", trigger lists) → `idc:idc-skill-X`, `idc:codex-idc-X`, `idc:idc-workflow`.
- **R2 — Agent refs:** `subagent_type: "idc-role-X"` → `subagent_type: "idc:idc-role-X"`; same for `idc-plan`, `idc-sequence`, etc. Applies in prose too ("spawn `idc-role-writer`" → namespaced form).
- **R3 — Commands:** files `commands/agent-think.md` → `commands/think.md` (etc.); every `/agent-think` mention → `/idc:think`. New surface: `/idc:think|plan|sequence|build|ripple|autorun|init|doctor`.
- **R4 — Path refs:** `~/.claude/agents/idc-build-runbook.md` → `${CLAUDE_PLUGIN_ROOT}/agents/idc-build-runbook.md`; `~/.claude/agents/references/codex-name-aliases.md` → `${CLAUDE_PLUGIN_ROOT}/agents/references/codex-name-aliases.md`. Runbook and aliases stay plain files (no skill conversion needed, per fact 6).
- **R5 — Shell usage:** never rely on `$CLAUDE_PLUGIN_ROOT` inside Bash snippets in agent bodies (fact 7). If a script needs the plugin root, the markdown text passes the expanded path as an argument: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh ${CLAUDE_PLUGIN_ROOT}`.
- **R6 — Memory refs:** "see memory feedback_agent_teams_for_large_scale" and similar → state the rule inline ("always spawn as a TEAMMATE via TeamCreate + Agent with team_name, never as a Task subagent, because Task subagents cannot coordinate/peer-message and the parent loses the context-isolation benefit at team scale").
- **R7 — Genericize:** "Knowledge Engine" → "the governed repo" (one generic example allowed); remove personal-memory framing.
- **R8 — Personal paths:** `/Users/<name>/...` → portable forms (`${CLAUDE_PLUGIN_ROOT}/templates/...`, `<repo-root>/docs/workflow/...`, or `$HOME` where genuinely user-machine).
- **R9 — team-execute citations:** replace with inline explanation of the cited doctrine (worktree race condition, audit-log pattern) — no dependency on files outside the plugin.
- **R10 — Governance doctrine:** self-edit surface is now THIS repo via git commits/PRs; `.bak` snapshot doctrine for `~/.claude` files is retired in plugin context.
- **R11 — Codex adapters:** `scripts/install-codex.sh` must NOT symlink adapters into `~/.claude/skills` (fact 12 — would pollute every Claude project as bare skills). Instead: convert `~/.agents/skills` from a symlink into a real directory containing (a) per-entry symlinks to every existing `~/.claude/skills/<name>` and (b) 5 symlinks for `codex-idc-*` pointing into the installed plugin. Verify Codex resolves two-hop links; `/idc:doctor` checks link integrity. Adapter skill bodies must avoid `${CLAUDE_PLUGIN_ROOT}` (Codex reads raw text, no substitution) — use relative references within the skill dir or install-time path substitution.
