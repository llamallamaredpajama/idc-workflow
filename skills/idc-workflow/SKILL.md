---
name: idc-workflow
description: Use for IDC workflow routing from Think through Ripple, especially in Codex or other non-pane environments.
---

# IDC Workflow

Use this skill when a project invokes IDC roles or asks for the canonical
Think -> Engineer -> Develop -> Deconflict -> Sequence -> Build -> Ripple route.

## Authority Chain

`PRD -> master architectural spec -> master implementation plan -> subphase plans -> pillar plans -> TRACKER.md`

`docs/considerations/` is pre-canonical input. `docs/workflow/ripple/` is a
change-order inbox until a gated PR lands.

## Pipeline classification

Two canonical-edit pipelines route through Ripple as the shared canonical-edit guard:

- **Codebase pipeline** — the chain above (`Think -> Engineer -> Develop -> Deconflict -> Sequence -> Build`), used for changes whose surface-of-truth is product / runtime code, canonical specs, planning docs, and non-governance fences. Originates from PRD-driven user need / feature work.
- **Governance pipeline** — lighter `Audit -> Plan -> PR` path, used for changes whose surface-of-truth is governance: agent files, skill bodies, the CLAUDE.md tree (root + per-directory tree per root §Domain Index), `docs/workflow/`, governance fences, hooks. Originates from audits / operator-experienced friction / drift detection.

**Surface-based classification rule:** a `tests/test_arch_*.py` fence is *governance* iff it reads the workflow-definition surfaces (the idc-workflow plugin repo's `agents/` / `skills/` / `commands/`), `~/.claude/hooks/`, any `CLAUDE.md`, `docs/workflow/`, or `TRACKER.md`; else codebase. Mechanical — recoverable by inspection of the fence's source surfaces.

Every Ripple change order at `docs/workflow/ripple/<slug>-ripple.md` declares a `Pipeline:` field (`governance` or `codebase`); see RS-2 `idc:idc-skill-ripple-verdict` (full 4-value Ripple verdict + four-condition `MINOR_AUTONOMOUS` gate) and CS-4 `idc:idc-skill-ripple-verdict` (binary `tracker-only` / `ripple-required` verdict + pipeline annotation). Hand-back branches on pipeline: governance → resume the upstream `Audit -> Plan` flow that filed the Ripple; codebase → resume the upstream IDC role that filed the Ripple. Use the lighter governance pipeline for governance-surface drift; use the codebase pipeline for product / runtime drift.

## Role Routing And Write Authority

- Think writes only `docs/considerations/`.
- Engineer writes gated PRD/spec/master-plan PRs.
- Develop writes subphase plans.
- Deconflict writes pillar plans and conflict evidence.
- Sequence writes TRACKER ordering/status by polished pillar.
- Build writes code/tests and implementation artifacts only.
- Ripple owns change orders and gated doc synchronization.

## Codex Adapter Skills

In Codex or any non-pane runtime, prefer the role-specific adapter skills:

- `idc:codex-idc-think`
- `idc:codex-idc-plan` (covers the Engineer / Develop / Deconflict cognitive surfaces)
- `idc:codex-idc-sequence`
- `idc:codex-idc-build`
- `idc:codex-idc-ripple`

These skills preserve IDC write authority while replacing Claude Teams teammates
with bounded Codex subagents where appropriate. Do not port the Claude Teams
agent markdown files directly into Codex TOML.

## Non-Pane Fallback

When Claude Teams or pane-based teammates are unavailable, run the same logical
roles in one session or with native subagents. Preserve write boundaries exactly;
do not let fallback mode collapse Think/Engineer/Develop/Deconflict/Sequence/Build/Ripple
into one actor with broader write authority.

## Required Trace

- Subphase plans must include `Upstream Master Plan Domain/Phase`.
- Pillar plans must include `Upstream Subphase` and `Tracker Trace Key`.
- TRACKER edits must cite existing polished pillar-derived work.

When a lower role discovers higher-layer drift, stop that role and file Ripple.
