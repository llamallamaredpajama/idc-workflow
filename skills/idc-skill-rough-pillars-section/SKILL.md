---
name: idc-skill-rough-pillars-section
description: 'Use when drafting or validating the Rough Pillars section of an IDC subphase plan.'
---
# idc:idc-skill-rough-pillars-section (DS-3)

Fenced-schema substrate skill encoding the canonical shape of the **`## §Rough Pillars`** section. The section is embedded inline in every canonical subphase plan at `docs/plans/subphases/<domain>-phase-<n>-subphase-<n>-<slug>-plan.md` per the Recursive Fractal Distillation (RFD) principle (root `CLAUDE.md §Recursive Fractal Distillation (RFD) principle`). It is **the** authoritative handoff from Develop to Deconflict — Deconflict polishes these rough pillars into canonical pillar plans at `docs/plans/pillars/`.

This skill is the immutable shape contract — validates the schema and emits the fixed-format section. Never decides scope (DR-1's drafting work); never invents pillar candidates (operator + DR-1 drafter authority); never absorbs file-surface bodies (only path + role declarations).

## Why this skill exists (load-bearing rationale)

The folded `idc-develop` orchestrator (consolidated into `idc:idc-plan`), anti-pattern line 252: *"Skip the `§Rough Pillars` section. It is the canonical RFD handoff to Deconflict; without it the subphase plan is non-canonical and Deconflict has no authoritative input to polish."*

The skill exists so that no matter who edits DR-1 later, the §Rough Pillars section keeps emitting in the canonical shape. It also fences the `(rough_scope, file_surfaces, dependencies, parallel_safety_hints)` four-field schema downstream readers (Deconflict's KR-1 + Sequence's QR-3 via the §Wave-Orchestrator Handoff Work Units table) rely on. Per Q-dev-1 (binding), this skill stays separate from DS-1 and DS-2 — those have different output schemas and live in Phase 1 read-only territory; DS-3 is the Phase 2 RFD-emission contract.

## Input contract

| Field | Shape |
|-------|-------|
| `subphase_id` | the subphase trace key (matches the canonical subphase plan's filename stem without `-plan` suffix, e.g. `domain-x-phase-2-subphase-1-foo`) |
| `candidate_pillars` | array of objects, one per candidate pillar (see "Pillar entry schema" below). MUST be non-empty — a subphase with zero candidate pillars is an admission-shape error, not a §Rough Pillars edge case |
| `output_path` | absolute path where the schema-validated section is written. Typically `<scratch_dir>/rough-pillars-section.md` for splice-into-draft OR `<scratch_dir>/draft-subphase-rough-pillars-block.md` for return-as-string composition |
| `mode` | `validate-and-emit` (default) \| `validate-only` (returns validation result without writing) |

### Pillar entry schema (load-bearing — every entry MUST have all four fields)

| Field | Type | Constraint |
|-------|------|------------|
| `pillar_slug` | string | kebab-case identifier unique within the subphase. The downstream polished pillar trace key will be `<subphase_id>-pillar-<n>-<pillar_slug>` (Deconflict assigns the `-pillar-<n>-` ordinal during polish; DS-3 emits only the slug). Allowed chars: `[a-z0-9-]+`; no leading/trailing dash; ≤ 48 chars |
| `rough_scope` | string | 1–3 sentences. Describes the pillar's goal + acceptance criteria at rough fidelity. Concrete enough that Deconflict can polish into a pillar-plan body; loose enough that Deconflict still owns the polished detail. **Banlist:** never just "(implement X)" — must name acceptance |
| `file_surfaces` | array of objects | one entry per write-path the pillar will touch. Each object: `{path: <relative repo path>, role: exclusive \| shared, co_owners: <list of pillar_slugs if shared, omit if exclusive>}`. **Path-only declaration** — never absorb file body. **Parity rule:** every `shared` entry MUST list every co-owning sibling pillar by `pillar_slug` (mirrors WM-1's parity rule downstream) |
| `dependencies` | object | `{within_subphase: [pillar_slug, ...], cross_subphase: [<subphase trace key>:<pillar_slug>, ...]}`. Each list MAY be empty (use empty list `[]`, never the string `"none"`). Within-subphase entries reference sibling `pillar_slug`s in the same `candidate_pillars` array; cross-subphase entries reference canonical landed subphase trace keys + their declared pillar slugs |
| `parallel_safety_hints` | string | concrete sentence(s) citing the file surfaces that determine parallel-safety (e.g. "safe-with-pillar-foo because file surfaces don't overlap; serializes after pillar-bar because both write to `web/src/auth/middleware.ts`"). **Banlist:** never the bare word `"safe"` or `"parallel-safe"`; must cite concrete file-surface or dependency reasoning |

### Optional fields per pillar entry

| Field | Type | Notes |
|-------|------|-------|
| `notes` | string | free-text rationale or open question to surface to Deconflict (≤ 200 words). Appended below the pillar block as an italicized aside |
| `ripple_flags` | array of strings | each string is a `Ripple-required: <one-line evidence>` flag if the rough scope implies upstream PRD/spec/master-plan/sibling-subphase change. Forwarded to the §Wave-Orchestrator Handoff `### Canonical Ripple Notes` sub-section by DR-1. **Do NOT decide whether to file Ripple — that's DR-1 → CR-8 territory** |

## Output contract — section shape (verbatim)

The emitted section is a single H2 block (`## §Rough Pillars`) with one H3 subsection per candidate pillar. Caller embeds the entire block in the subphase plan body (typically immediately before `## Wave-Orchestrator Handoff`).

```markdown
## §Rough Pillars

> Recursive Fractal Distillation handoff — Deconflict polishes each subsection into a canonical pillar plan at `docs/plans/pillars/<subphase_id>-pillar-<n>-<pillar_slug>-plan.md`. Rough pillars live INLINE in this subphase plan; never as separate files. Per the folded `idc-develop` orchestrator (now `idc:idc-plan`) anti-pattern line 252, omitting this section makes the subphase plan non-canonical.

### <pillar_slug>

**Rough scope:** <rough_scope text — 1–3 sentences>

**File surfaces (write paths):**

| Path | Role | Co-owners |
|------|------|-----------|
| <relative repo path> | exclusive \| shared | <comma-sep pillar_slugs if shared, `(n/a)` if exclusive> |
| ... | ... | ... |

**Dependencies:**

- Within-subphase: <comma-sep pillar_slugs, or `(none)` if empty list>
- Cross-subphase: <comma-sep `<subphase-trace-key>:<pillar_slug>` entries, or `(none)` if empty list>

**Parallel-safety hints:** <concrete sentence(s) citing file surfaces / dependencies>

<optional italicized notes block>

<optional `Ripple-required: ...` lines, one per ripple_flag, immediately before next H3>

### <next pillar_slug>

...
```

The H2 anchor `## §Rough Pillars` is **load-bearing** — Deconflict's KR-1 polishes by anchor lookup; the §Wave-Orchestrator Handoff `### Work Units` table cross-references each `pillar_slug` H3; downstream readers parse by these anchors. Do NOT rename, reorder, or omit anchors.

## Procedure

1. **Validate inputs**:
   - `subphase_id` is a non-empty string matching the subphase trace-key shape (`<domain>-phase-<n>-subphase-<n>-<slug>`).
   - `candidate_pillars` is a non-empty array. Empty array → `BLOCKED — candidate_pillars empty (subphase admission-shape error, not a DS-3 emit case)`.
   - `output_path` (if `mode = validate-and-emit`) is an absolute path; parent directory exists.
2. **Validate each pillar entry** — for each entry at index `i`:
   - All four required fields present (`pillar_slug`, `rough_scope`, `file_surfaces`, `dependencies`, `parallel_safety_hints`). Missing → `BLOCKED — pillar <i>: missing field <name>`.
   - `pillar_slug` is unique within the array. Duplicate → `BLOCKED — pillar <i>: pillar_slug <slug> duplicates pillar <j>`.
   - `pillar_slug` matches `^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$` and is ≤ 48 chars. Mismatch → `BLOCKED — pillar <i>: pillar_slug shape invalid`.
   - `rough_scope` is non-empty AND not the literal string `"(implement X)"` or `"TBD"` placeholder. Empty/placeholder → `BLOCKED — pillar <i>: rough_scope missing or placeholder`.
   - `file_surfaces` is a non-empty array. Empty → `BLOCKED — pillar <i>: file_surfaces empty`.
   - `dependencies.within_subphase` and `dependencies.cross_subphase` are both arrays (may be empty). Wrong type → `BLOCKED — pillar <i>: dependencies type invalid`.
   - `parallel_safety_hints` is non-empty AND is not the bare word `"safe"` / `"parallel-safe"` / `"none"`. Bare-word → `BLOCKED — pillar <i>: parallel_safety_hints lacks concrete reasoning`.
3. **Validate file_surfaces parity** — for each pillar entry, for each file_surface row:
   - `path` is a non-empty relative repo path (no leading `/`, no `~/`).
   - `role` ∈ `{exclusive, shared}`. Out-of-enum → `BLOCKED — pillar <i> surface <j>: role out-of-enum`.
   - If `role = shared`, `co_owners` is a non-empty list. Each entry MUST be a valid `pillar_slug` referenced elsewhere in `candidate_pillars` OR an external trace key in the form `<subphase-trace-key>:<pillar_slug>` (cross-subphase shared ownership). Missing/empty → `BLOCKED — pillar <i> surface <j>: shared row missing co_owners`.
   - If `role = exclusive`, `co_owners` is omitted/empty (exclusive rows have no co-owners). Present-non-empty → `BLOCKED — pillar <i> surface <j>: exclusive row has co_owners`.
4. **Validate intra-pillar uniqueness**: within a single pillar's `file_surfaces`, no two rows have identical `path`. Duplicate → `BLOCKED — pillar <i> surface <j>: duplicate path with surface <k>`.
5. **Validate within-subphase dependency references**: every `pillar_slug` in `dependencies.within_subphase` MUST exist in the `candidate_pillars` array. Dangling → `BLOCKED — pillar <i>: within-subphase dep <slug> references non-existent pillar`.
6. **Emit the section** to `output_path` per the section shape above. Render `(none)` for empty within/cross dependency lists; render `(n/a)` for the `Co-owners` cell on exclusive rows. Append optional `notes` as `> <text>` italicized blockquote; append `ripple_flags` as plain `Ripple-required: <evidence>` lines below the dependencies block.
7. **Return** `{output_path, pillar_count, exclusive_surface_count, shared_surface_count, ripple_flag_count, validation: "PASS"}` to caller.

In `validate-only` mode, skip step 6 — return `{validation: "PASS"}` only.

## Halt conditions

| Halt | When |
|------|------|
| `BLOCKED — subphase_id missing/empty` | step 1 |
| `BLOCKED — candidate_pillars empty (subphase admission-shape error, not a DS-3 emit case)` | step 1 |
| `BLOCKED — output_path missing or parent dir absent` | step 1 |
| `BLOCKED — pillar <i>: missing field <name>` | step 2 |
| `BLOCKED — pillar <i>: pillar_slug <slug> duplicates pillar <j>` | step 2 |
| `BLOCKED — pillar <i>: pillar_slug shape invalid` | step 2 |
| `BLOCKED — pillar <i>: rough_scope missing or placeholder` | step 2 |
| `BLOCKED — pillar <i>: file_surfaces empty` | step 2 |
| `BLOCKED — pillar <i>: dependencies type invalid` | step 2 |
| `BLOCKED — pillar <i>: parallel_safety_hints lacks concrete reasoning` | step 2 |
| `BLOCKED — pillar <i> surface <j>: role out-of-enum` | step 3 |
| `BLOCKED — pillar <i> surface <j>: shared row missing co_owners` | step 3 |
| `BLOCKED — pillar <i> surface <j>: exclusive row has co_owners` | step 3 |
| `BLOCKED — pillar <i> surface <j>: duplicate path with surface <k>` | step 4 |
| `BLOCKED — pillar <i>: within-subphase dep <slug> references non-existent pillar` | step 5 |

On halt, NO file is written; caller's DR-1 fix-loop or Develop parent orchestrator decides next step (typically: re-prompt the operator for the missing/invalid field, or re-spawn DR-1 with corrected `candidate_pillars`).

## Banlist

- **Do NOT decide scope.** DR-1 (informed by codebase-context-curator + DS-1 governance trace + DS-2 prior-art) drafts `rough_scope`; this skill validates + emits.
- **Do NOT invent pillar candidates.** If `candidate_pillars` is empty, halt — that's a subphase admission-shape error that routes back to DR-1 / Develop parent.
- **Do NOT auto-elevate `shared` to `exclusive` or vice versa.** Ownership type is DR-1's call.
- **Do NOT absorb file-surface bodies.** Only `path` + `role` + `co_owners` are recorded. The actual file content lives in the codebase-context-curator packet (Phase 1) — never inlined into §Rough Pillars.
- **Do NOT widen the `role` enum** beyond `{exclusive, shared}`. New ownership values require a Ripple change order touching the matching downstream WM-1 (`idc:idc-skill-pillar-resource-ownership`) enum + `tests/test_arch_pillar_matrix.py`.
- **Do NOT write to canonical subphase plan paths directly.** This skill writes to scratch shards OR returns the section block as a string for DR-1 to splice into the subphase draft body — never touches `docs/plans/subphases/` directly. The canonical subphase landing happens only after DR-1 Phase 3 review clears, via the Develop orchestrator's PR.
- **Do NOT generalize for `§Rough Subphases`.** Per Q-dev-2 (recommendation: keep Develop-only for now), DS-3 stays scoped to subphase-level rough emission. Master-plan-layer rough emission (if RFD doctrine ever adds it) needs a sibling skill, not a widened DS-3.

## Cross-references

- DR-1 caller: the orchestrator inline (PR-5 fold; substrate: `idc:idc-skill-rough-pillars-section`) step 4 (per-pillar emission loop)
- Downstream consumers:
  - KR-1 the orchestrator inline (PR-5 fold; pillar-polishing substrate: `idc:idc-skill-pillar-plan-shape` + `idc:idc-skill-plan-review`) (Deconflict polishes each `### <pillar_slug>` H3 into a canonical pillar plan)
  - WM-1 `idc:idc-skill-pillar-resource-ownership/` (Deconflict's polished per-pillar Ownership table inherits the `(role, co_owners)` shape from §Rough Pillars file_surfaces — same parity rule)
  - CR-4 the orchestrator inline (PR-5 fold; Wave-Orchestrator Handoff step) emit mode (cross-references each `pillar_slug` from §Rough Pillars when authoring `### Work Units`)
- WD-2b reader: `idc:idc-skill-plan-review/` (Develop's Phase 3 reviewer dimension 5 enforces the same `(role, co_owners)` parity at review time)
- Source authority: root `CLAUDE.md §Recursive Fractal Distillation (RFD) principle`; the folded `idc-develop` orchestrator (now `idc:idc-plan`) anti-pattern line 252; `docs/CLAUDE.md §Subphase / pillar plan filename conventions`
- Schema fences (downstream): `tests/test_arch_idc_workflow.py::test_subphase_and_pillar_trace_headers_exist`
