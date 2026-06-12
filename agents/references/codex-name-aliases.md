# Codex name aliases for `idc:idc-role-think-investigator`

Cross-runtime alias map for `idc:idc-role-think-investigator` subtypes. The investigator file is one shared body; Claude side uses `subtype` parameter; Codex side has historically named subagents differently. This file is the canonical translation table.

(File paths in this document are relative to this file's own location inside the idc-workflow plugin — this map is read as raw text by Codex, where plugin-root variables do not substitute.)

## Mapping table

| Claude subtype | Codex name | Notes |
|---|---|---|
| `research-investigator` | `source-investigator` | External-source SOTA / domain survey. Same shape; same output-contract discipline. |
| `scoping-investigator` | `orientation-grounder` (when first-pass at run start) OR `scope-mapper` (when mid-session new anchor doc surfaces) | Codex's `orientation-grounder` is broader — combines Claude's `scoping-investigator` + first-pass `codebase-grounder`. When Codex parent dispatches `orientation-grounder`, treat it as a combined dispatch and synthesize both sub-questions in one findings file. |
| `codebase-grounder` | `codebase-grounder` | Same name; same shape. |
| `paragraph-verifier` | (no direct Codex equivalent; absorb into `codebase-grounder` with a verification-flavored question) | Codex parent should phrase the question as "verify this claim against current repo state: <claim>" — investigator returns yes/no plus file:line evidence. |
| `design-explorer` | (no direct Codex equivalent today; absorb into `source-investigator` with a design-pattern-flavored question) | Codex parent should phrase the question as "what design patterns does <named external system> use for X?" — `source-investigator` returns external pattern catalog. |
| `qa-watcher` | (no direct Codex equivalent today; spawn as `codebase-grounder` with edge-case-flavored question) | Future Codex addition flagged in audit. |
| `prep-extractor` | (no direct Codex equivalent today; spawn as `source-investigator` with `Read` against `docs/considerations/` + `docs/workflow/handoffs/`) | Future Codex addition flagged in audit. |
| `resume-drift-investigator` | `handoff-resumer` | Same shape; reads prior handoff + git log against governance commits since prior HEAD; returns one-line conclusion + commit IDs. |
| (no Claude equivalent) | `domain-split-reviewer` | Codex-specific subtype that challenges the proposed domain partition mid-session. Claude side handles this via the orchestrator inline (substrate: `idc:idc-skill-think-reconciliation`) at synthesis (different lifecycle); Codex parent may dispatch `domain-split-reviewer` mid-session for a quick partition challenge. When Codex inline-reads `../idc-role-think-investigator.md` for `domain-split-reviewer`, treat the question as "do these N tags actually represent N domains, or are some collapsible?" and return a plain-language answer. |

## Translation rules

When the Codex parent dispatches a Codex-named subagent, translate via this table to the Claude `subtype` value, then load `../idc-role-think-investigator.md` as the orientation prompt. Set the brief's `subtype` field to the Claude name (e.g. `subtype: research-investigator` even when Codex called it `source-investigator`).

The findings file path on Codex side uses the Codex name (e.g. `<scratch>/findings/source-investigator-1.md`) so Codex parent's followup reads work — but the file body uses the Claude subtype name in §"# <Investigator subtype> — <id>" header for cross-runtime audit consistency.

## When this map needs updating

- New Claude subtype admitted by audit / Ripple → add row with `(no direct Codex equivalent; ...)` Codex-side fallback.
- Codex plugin adds a roleplayer-loader feature (architecture.md Option 3) → this map retires; native Codex `subagent_type` resolution replaces alias translation.
- Operator surfaces a new investigator pattern → audit-Engineer-Develop chain admits the new subtype to TR-5 §2 and updates this map.

## See also

- `../idc-role-think-investigator.md` — the parent file this map serves.
- `docs/workflow/audits/2026-05-07-idc-role-skill-coverage/per-role/think.md` §Codex parity notes — origin of the divergence.
- `docs/workflow/audits/2026-05-07-idc-role-skill-coverage/architecture.md §Cross-runtime substrate model` — Option 2 inline-read pattern this map supports.
