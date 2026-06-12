---
name: idc-skill-pillar-plan-shape
description: 'Use when drafting or reviewing the canonical structure of an IDC pillar plan.'
---
# idc:idc-skill-pillar-plan-shape (KS-4 — Deconflict)

CUSTOM. The immutable shape contract for canonical pillar plans at `docs/plans/pillars/`. Every polished pillar plan MUST conform to this schema; any pillar that fails the trace-triple gate or work-packet-ID-format gate cannot land (Blocker, no exceptions per the folded `idc-deconflict` role's §Required trace (now `idc:idc-plan`) line 126).

This skill is the **schema validator + emitter** — KR-1's drafter assembles the per-pillar fields then hands them to this skill, which validates the immutable contract and emits the fixed-format markdown body. The Pillar Resource Ownership table is delegated to WM-1 `idc:idc-skill-pillar-resource-ownership` (sibling — referenced in the body, emitted by WM-1). This skill does NOT decide scope, invent work packets, or polish-vs-originate — those are KR-1's reasoning.

## When to invoke

- the orchestrator inline (substrate: `idc:idc-skill-pillar-plan-shape` + `idc:idc-skill-plan-review` + `idc:idc-skill-pillar-clash-analysis`) Phase 2 step 1 — drafter calls this skill once per candidate pillar with the assembled field set.
- the orchestrator inline (substrate: `idc:idc-skill-pillar-matrix-synth` (all three views)) step 4/5/6 (read-only mode) — when validating that a landed pillar plan body conforms to the schema before extracting the WM-1 ownership table.

Do NOT invoke from Engineer (different layer), Develop (subphase-shape, not pillar-shape — see `idc:idc-skill-rough-pillars-section` for Develop's RFD-emission), Sequence (pillar plan bodies are read-only post-polish), or Build (pillar plan bodies are runtime input, not authored from Build).

## Input contract

Caller hands the skill a packet with all 15 fields (`admission_status` is optional-with-default). Missing any required field → halt.

| Field | Shape |
|-------|-------|
| `pillar_id` | trace key matching the polished pillar plan's filename stem without `-plan` suffix (e.g. `kchain-phase-3-subphase-2-pillar-1-foo`) |
| `trace_triple` | object with three required keys: `upstream_subphase` (absolute path to the subphase plan), `upstream_master_plan_domain_phase` (string copied verbatim from subphase header), `rough_pillars_source` (anchor identifier inside the upstream subphase's §Rough Pillars section — heading text or sub-section ID) |
| `goal` | 1-paragraph description of the pillar's goal (max 500 chars) |
| `scope` | bulleted list of in-scope items (markdown body) |
| `non_scope` | bulleted list of explicitly out-of-scope items (markdown body) |
| `work_packets` | array of objects each with `{id, title, description, file_surfaces[], test_targets[], acceptance_criteria}` — `id` MUST match `^[A-Z0-9-]+\.[A-Z0-9-]+(\.[A-Z0-9-]+)?$` (dispatch-grade work-unit ID format from sibling-pillar precedent or `<pillar-slug>-task-<n>` fallback) |
| `dependencies` | object with `{within_pillar[], cross_pillar[], cross_subphase[]}` arrays — each entry references a pillar trace key OR an external dependency identifier |
| `parallel_safety_markers` | array of marker strings (e.g. `parallel-safe-with: <pillar-id>`, `serial-after: <pillar-id>`, `union-with: <pillar-id>`) — MUST align with the Pillar Resource Ownership table's `Parallel-safe with` column (caller's KR-1 cross-checks before calling this skill) |
| `test_obligations` | array of test target paths (e.g. `tests/test_arch_<area>.py`, `functions/<fn>/test_<fn>.py`) OR explicit `no-test-added: <rationale>` strings per work packet |
| `operator_gates` | array of operator-gate descriptors (e.g. `operator approval before merge`, `operator clears BLOCKING todo before resume`) — empty array allowed |
| `exit_criteria` | bulleted list of what success looks like (markdown body) — non-empty required |
| `dispatch_grade_work_unit_ids` | array of work-unit IDs from `work_packets[].id` flattened — must equal length of `work_packets` (no duplicates allowed, ID-format gate applies) |
| `conflict_resolution_refs` | array of objects each `{paired_pillar_id, clash_evidence_path, resolution}` — `clash_evidence_path` MUST match `docs/workflow/pillar-conflicts/<pillar-a>-<pillar-b>-pillar-conflicts.md` (canonically ordered pair); `resolution ∈ {serialize, union, ripple-required}` |
| `pillar_resource_ownership_table_block` | the WM-1 emission output (string of the full `## Pillar Resource Ownership` block, including heading + table + Blocks-on/Wave directives). Caller invokes WM-1 first, then passes the emitted block here for splicing |
| `output_path` | absolute path where the validated pillar plan body is written (typically `<scratch_dir>/draft-pillar-<pillar_id>.md`); KR-1 stages this file then opens the canonical-path PR separately |
| `mode` | `validate-and-emit` (default) \| `validate-only` |
| `admission_status` | OPTIONAL admission-readiness marker emitted into the header. One of `ready` \| `paused: <reason>` \| `parked-ripple: <reason>` \| `intentionally-deferred: <reason>`. Defaults to `ready` when omitted (a freshly polished pillar is ready-to-admit by construction). Non-`ready` values MUST carry a non-empty reason. Mirrors the planning-manifest status vocabulary; consumed by Sequence's unsequenced-ready discovery surface (`WORKFLOW.md §5.3`) and fence-pinned by `tests/test_arch_pillar_queue.py::test_non_archived_pillars_carry_admission_status`. |

## Output contract — pillar plan body shape (verbatim)

```markdown
# <pillar_id>

**Upstream Subphase:** `<trace_triple.upstream_subphase>`
**Upstream Master Plan Domain/Phase:** <trace_triple.upstream_master_plan_domain_phase>
**§Rough Pillars Source:** <trace_triple.rough_pillars_source>
**Highest Affected Layer:** pillar
**Tracker Trace Key:** <pillar_id>
**No Higher-Layer Impact Rationale:** <auto-derived 1-sentence — "Pillar polish derives from admitted §Rough Pillars entry; no PRD/spec/master-plan/subphase edits required.">
**Admission Status:** <admission_status — defaults to `ready`>

## Goal

<goal verbatim>

## Scope

<scope verbatim>

## Non-scope

<non_scope verbatim>

## Work Packets

### <work_packets[0].id> — <work_packets[0].title>

<work_packets[0].description>

**File surfaces:** <comma-separated `work_packets[0].file_surfaces`>
**Test targets:** <comma-separated `work_packets[0].test_targets`>
**Acceptance criteria:** <work_packets[0].acceptance_criteria>

### <work_packets[1].id> — <work_packets[1].title>

<...>

## Dependencies

**Within-pillar:** <bulleted list of `dependencies.within_pillar`>
**Cross-pillar:** <bulleted list of `dependencies.cross_pillar`>
**Cross-subphase:** <bulleted list of `dependencies.cross_subphase`>

## Parallel-safety markers

<bulleted list of `parallel_safety_markers`>

<verbatim splice of `pillar_resource_ownership_table_block` — the complete WM-1 emission>

## Test obligations

<bulleted list of `test_obligations`>

## Operator gates

<bulleted list of `operator_gates` — or "(none)" if empty>

## Exit criteria

<exit_criteria verbatim>

## Conflict Resolution

<For every entry in `conflict_resolution_refs`:>
- **Paired pillar:** `<paired_pillar_id>`
  **Clash evidence:** `<clash_evidence_path>`
  **Resolution:** `<resolution>`

## Dispatch-grade work-unit IDs

<flat bulleted list of `dispatch_grade_work_unit_ids` — these are the items Sequence's TRACKER ordering admits as discrete units>
```

The `## Pillar Resource Ownership` block is spliced verbatim from WM-1's emission (heading included). The caller's KR-1 invokes WM-1 first, then passes the emitted block string in `pillar_resource_ownership_table_block`. This skill does NOT call WM-1 itself — single-responsibility split avoids re-validation loops.

## Procedure

1. **Validate inputs**:
   - `pillar_id` matches the trace-key shape `<domain>-phase-<n>-subphase-<n>-pillar-<n>-<slug>`. Mismatch → `BLOCKED — pillar_id malformed`.
   - `output_path` is absolute, parent directory exists.
   - `admission_status` (if provided) — prefix MUST be one of `ready` / `paused` / `parked-ripple` / `intentionally-deferred`; any non-`ready` prefix MUST be followed by a non-empty `: <reason>`. Omitted → default `ready`. Malformed → `BLOCKED — admission_status invalid`.
2. **Trace-triple gate (Blocker per the folded `idc-deconflict` role's §Required trace (now `idc:idc-plan`) line 126)**:
   - All three fields in `trace_triple` are non-empty.
   - `upstream_subphase` exists on disk and matches `docs/plans/subphases/.*-plan.md`.
   - `upstream_master_plan_domain_phase` is a non-empty string (caller's KS-1 ingestion already verified existence in master plan).
   - `rough_pillars_source` is a non-empty anchor.
   - Missing or empty any of the three → `BLOCKED — trace_triple incomplete (<which field>) — pillar non-canonical and MUST NOT land`.
3. **Work-packet ID-format gate (Blocker)**:
   - Every `work_packets[].id` matches `^[A-Z0-9-]+\.[A-Z0-9-]+(\.[A-Z0-9-]+)?$` OR `^<pillar-slug>-task-\d+$`.
   - No duplicate IDs across the array.
   - Mismatch → `BLOCKED — work_packets[<i>].id malformed: "<id>"`.
   - Duplicate → `BLOCKED — duplicate work_packet id: "<id>"`.
4. **Ownership-table presence gate (Blocker)**:
   - `pillar_resource_ownership_table_block` is non-empty AND starts with `## Pillar Resource Ownership` heading line.
   - Empty or wrong heading → `BLOCKED — pillar_resource_ownership_table_block missing or wrong heading (caller must invoke WM-1 first)`.
5. **Exit-criteria gate (Blocker for empty, MAJOR for prose-only, MAJOR for missing `[CONSTRAINTS]`)**:
   - `exit_criteria` non-empty. Empty → `BLOCKED — exit_criteria empty (pillar lands without success definition)`.
   - At least one `exit_criteria` entry references a runnable command, test path, or fence path (regex match: `(pytest|pnpm|uv run|npm|cargo|go test|tests/test_arch_)` OR ends in `exits 0` / `passes` / `clean`). Prose-only criteria → `MAJOR — exit_criteria are prose-only (Build /goal cannot verify; see idc-plan.md §Phase 2 TDD-shaped exit criteria)`.
   - `exit_criteria` carries an explicit **`[CONSTRAINTS]` don't-regress line** — a clause naming what must NOT regress (e.g. existing suite stays green, no new deps, no out-of-contract public-API change, named neighbors preserved). This feeds the Build `/goal` recipe's `[CONSTRAINTS]` element mechanically (see `${CLAUDE_PLUGIN_ROOT}/agents/idc-build-runbook.md §`/goal` recipe template`); without it Build must invent the don't-regress line downhill, which is the real drift hazard. Missing → `MAJOR — exit_criteria missing a [CONSTRAINTS] don't-regress line (Build /goal cannot map [CONSTRAINTS]; add an explicit don't-regress clause)`.
6. **Conflict-resolution-refs gate (Major, not Blocker)**:
   - For every `conflict_resolution_refs[i]`:
     - `clash_evidence_path` matches `^docs/workflow/pillar-conflicts/.*-pillar-conflicts\.md$`.
     - `resolution ∈ {serialize, union, ripple-required}`. Out-of-enum → `BLOCKED — conflict_resolution_refs[<i>].resolution out-of-enum: "<value>"` (this IS Blocker — enum is fence-pinned).
   - Path-format mismatch → `MAJOR — conflict_resolution_refs[<i>].clash_evidence_path malformed`. Caller can correct; not a Blocker because the file may exist with the right content despite a path-spelling typo, but downstream WM-2 emission will catch it.
7. **Parallel-safety alignment gate (Major)**:
   - `parallel_safety_markers` is consistent with the WM-1 ownership-table block (every `parallel-safe-with:` marker is a `shared` row's co-owner; every `serial-after:` aligns with a `Blocks on:` directive).
   - Mismatch → `MAJOR — parallel_safety_markers inconsistent with ownership table`. Caller's KR-1 reconciles.
8. **Emit the pillar plan body** to `output_path` per the body shape above.
9. **Return** `{output_path, work_packet_count, conflict_resolution_count, validation: "PASS" | "PASS-WITH-MAJOR-FINDINGS" | "BLOCKED-...", findings: [...]}`.

In `validate-only` mode, skip step 8 — return validation only.

## Halt conditions

| Halt | When |
|------|------|
| `BLOCKED — pillar_id malformed` | step 1 |
| `BLOCKED — output_path missing or parent dir absent` | step 1 |
| `BLOCKED — trace_triple incomplete (<field>)` | step 2 — pinned by §Required trace line 126 |
| `BLOCKED — upstream_subphase does not exist on disk` | step 2 |
| `BLOCKED — work_packets[<i>].id malformed: "<id>"` | step 3 |
| `BLOCKED — duplicate work_packet id: "<id>"` | step 3 |
| `BLOCKED — pillar_resource_ownership_table_block missing or wrong heading` | step 4 |
| `BLOCKED — exit_criteria empty` | step 5 |
| `MAJOR — exit_criteria are prose-only (Build /goal cannot verify; see idc-plan.md §Phase 2 TDD-shaped exit criteria)` | step 5 |
| `MAJOR — exit_criteria missing a [CONSTRAINTS] don't-regress line` | step 5 |
| `BLOCKED — conflict_resolution_refs[<i>].resolution out-of-enum: "<value>"` | step 6 |

`MAJOR` findings (steps 6 path-format + step 7 parallel-safety alignment) do NOT halt — they return in the `findings[]` array for KR-1's reviewer loop to address. KR-1's Phase 3 review (WD-2c `idc:idc-skill-plan-review`) will catch any uncorrected Major before landing.

## Banlist

- **Do NOT lower the trace-triple gate.** Pinned by the folded `idc-deconflict` role's §Required trace (now `idc:idc-plan`) line 126: "Pillars without all three traces are non-canonical and MUST NOT land." Severity-downsizing is forbidden.
- **Do NOT widen the `resolution` enum.** `{serialize, union, ripple-required}` is fence-pinned by WM-2 + the folded `idc-deconflict` role's §Clash Evidence Schema (now `idc:idc-plan`). New values require a Ripple change order touching `tests/test_arch_pillar_matrix.py`.
- **Do NOT invent work packets.** Every entry in `work_packets[]` must be passed by the caller; this skill validates + emits.
- **Do NOT call WM-1 from this skill.** Caller's KR-1 invokes WM-1 first to emit the ownership-table block, then hands the block string here. Single-responsibility split.
- **Do NOT call WM-2 from this skill.** Caller's KR-1 invokes WM-2 separately for each clash-evidence file emission; this skill only consumes `clash_evidence_path` references for path-format validation.
- **Do NOT modify `docs/plans/pillars/` or `docs/workflow/pillar-conflicts/` directly.** Emit-only to `output_path` (typically a scratch path); KR-1 stages the canonical path via PR.
- **Do NOT include matrix synthesis or wave-ordering content.** Those belong in `<phase-tag>-matrix.yaml` (Sequence's QR-3 polish), not in pillar plan bodies. Pillar plans carry per-pillar parallel-safety markers; matrix-level constraints live in the matrix.
- **Do NOT auto-fill `non_scope` if empty.** If KR-1 passes empty `non_scope`, emit `(none — see Goal + Scope above)` placeholder. The caller's KR-1 review may flag missing non-scope as a quality issue (Minor) but this skill does not auto-fill content.

## Cross-references

- KR-1 caller: the orchestrator inline (PR-5 fold; see substrate skills) (Phase 2 step 1 — drafter assembles fields, calls this skill)
- WM-1 sibling (called BEFORE this skill): `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-pillar-resource-ownership/SKILL.md` (emits the ownership-table block; passed in here as `pillar_resource_ownership_table_block`)
- WM-2 sibling (called separately by KR-1 for each clash-evidence file): `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-clash-evidence/SKILL.md`
- Downstream consumers:
  - QR-3 the orchestrator inline (PR-5 fold; see substrate skills) (read-only — uses landed pillar plan headers + ownership table for matrix synthesis)
  - WD-2c `idc:idc-skill-plan-review` (review pass against the emitted body)
- Authority sources:
  - the folded `idc-deconflict` role's §Required trace (now `idc:idc-plan`) line 126 (trace-triple Blocker invariant)
  - the folded `idc-deconflict` role's §Pillar Resource Ownership (now `idc:idc-plan`) lines 67-88 (ownership-table fence)
  - the folded `idc-deconflict` role's §Clash Evidence Schema (now `idc:idc-plan`) lines 90-117 (resolution enum)
  - per-role audit `deconflict.md §KS-4`
- Schema fences: `tests/test_arch_idc_workflow.py::test_subphase_and_pillar_trace_headers_exist`, `tests/test_arch_pillar_matrix.py`
