---
name: idc-skill-change-order-shape
description: Templated single-process change-order document shape — emits a change-order draft at a scratch path with the full required field list in fixed order. Caller hands the skill an assembled-fields packet (typically composed by PR-1 from RS-1 drift evidence + RS-2 verdict + RS-3 tree audit + Phase 2 proposed canonical edits + downstream-sync map); the skill validates schema (required fields present, `Pipeline:` ∈ {governance, codebase}, `Verdict:` ∈ {NO_RIPPLE, MINOR_AUTONOMOUS, GATED, MAJOR_GATED}, both citation fields present, CLAUDE.md tree impact present) and emits the fixed-format change-order markdown to `output_path`. Read+validate+emit-only — never edits canonical paths, never decides verdict, never re-authors scope. Use ONLY when invoked from inside PR-1 `idc:idc-role-change-order-author` Phase 4 (templated emit step) OR from `${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md` Phase 2 change-order-author surface.
---

# IDC Skill — Change-Order Shape (`idc:idc-skill-change-order-shape`)

ADAPT (umbrella-split child per `appendices/existing-idc-ripple-retirement.md`). Origin: the retired `idc-ripple` umbrella skill (not shipped with this plugin) §"Required Output" (lines 12–25). The donor's bullet list is single-process / templated; this skill is the canonical emitter. `${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md §Phase 2 change-order template` cites this skill rather than restating the field list.

## When to invoke

Inside PR-1 `idc:idc-role-change-order-author` Phase 4 (templated emit step), AFTER PR-1 has assembled the field packet from upstream skill outputs (RS-1 drift summary, RS-2 verdict + downstream-sync map, RS-3 CLAUDE.md tree audit, plus PR-1's own Phase 2 proposed canonical edits text). Also invoked by:

- `${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md` Phase 2 change-order-author surface — when the parent orchestrator dispatches the templated emit directly without going through PR-1 (e.g. on `/idc:ripple --resume` after PR-1 has already shipped a draft and only the templated emit is being re-run after a fix loop).
- the orchestrator inline (substrate: `idc:idc-skill-plan-patch-from-findings`) Phase 4 patch step — when applying review findings to a Ripple change-order draft, the patch skill (WD-3) typically rewrites the existing draft in-place rather than re-invoking this skill, but this skill is invoked when the patch necessitates re-emission of a templated section.

## Input shape

Caller passes a single packet with all assembled fields. Required fields (validation halts if any absent):

```yaml
output_path: <abs path; typically <scratch_dir>/draft-ripple.md or <scratch_dir>/draft-ripple-vN.md>
slug: <kebab-case change-order slug>
trigger: <one paragraph: source of drift verbatim from RS-1>
pipeline: governance | codebase
verdict: NO_RIPPLE | MINOR_AUTONOMOUS | GATED | MAJOR_GATED
master_plan_section: <string; for codebase pipeline value cites §X.Y or "<not touched>" or "<no semantic change to §X.Y>"; for governance pipeline value is "<not applicable — governance pipeline>">
affected_role_skill_authority: <string; for governance pipeline value cites the upstream agent role / skill section; for codebase pipeline value is "<not applicable — codebase pipeline>">
highest_affected_layer: <CS-4 layer enum value>
no_higher_layer_impact_rationale: <one paragraph: why higher layers do or do not change>
proposed_canonical_edits:
  - file_path: <repo-relative path>
    section: <section anchor or line range>
    diff_or_description: <verbatim diff or one-paragraph description of the edit>
downstream_sync_plan:
  - layer: <ladder enum>
    sections_affected: [<list>]
    one_line_change: <verbatim one-liner>
architectural_fitness_obligations:
  - fence: tests/test_arch_<name>.py::<test or n/a>
    new_or_updated: new | updated
    reason: <one line>
claude_md_tree_impact: <"none" with one-line rationale OR enumerated block per RS-3 finding>
operator_gates:
  - kind: pre-drafting | pre-merge | none
    rationale: <one line>
hand_back_instructions: <one paragraph branched on pipeline — codebase: name the IDC role + the artifact they resume; governance: name the audit/plan that filed the Ripple>
```

Optional fields:

- `ledger_destination?` — required only when `verdict == MINOR_AUTONOMOUS`. Value is `docs/workflow/ledgers/<YYYY-MM-DD>-ripple-autonomous-ledger.md`.
- `prior_versions[]?` — when emitting `draft-ripple-vN.md` after a fix loop, list of `{version, path, summary_of_changes}` for evidence trail.

## Output shape

Single file written to `output_path` PLUS a small return packet:

```yaml
output_path: <abs path written>
schema_validation: PASSED | FAILED
validation_errors: [<list, empty when PASSED>]
field_count: <N>
```

The skill writes the change-order markdown verbatim to `output_path`. Caller reads `schema_validation` to gate downstream PR-opening. `FAILED` validation halts PR-1's emit step; PR-1 re-invokes this skill after fixing the input packet.

## Required-field schema (verbatim)

The change-order shape MUST include the following fields in fixed order. Per `${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md §Phase 2 change-order template`, donor §"Required Output" (lines 12–25), and ripple template at `docs/workflow/ripple/README.md`:

1. **Trigger** — verbatim evidence from the upstream IDC role.
2. **`Pipeline:` field** — `governance` or `codebase`. Fenced by `tests/test_arch_governance_pipeline.py`.
3. **`Verdict:` field** — one of `{NO_RIPPLE, MINOR_AUTONOMOUS, GATED, MAJOR_GATED}`. Fenced by `tests/test_arch_idc_ripple.py::test_minor_autonomous_path_exists`.
4. **Required citation fields** for `MINOR_AUTONOMOUS` eligibility. Both fields are required regardless of pipeline; the field that does not apply to the active pipeline carries value `<not applicable — <other> pipeline>`. Fenced by `tests/test_arch_idc_ripple.py::test_change_order_template_has_required_citation_fields`:
   - `Master Plan Section:` (codebase pipeline) — value `<not touched>` or `<no semantic change to §X.Y>` citing the upstream master-plan section.
   - `Affected Role/Skill Authority:` (governance pipeline) — value `<not touched>` or `<no semantic change to §X.Y>` citing the upstream agent role or skill section.
5. **Highest affected layer** — per CS-4 layer enum.
6. **No higher-layer impact rationale** — one paragraph: why higher layers do or do not change. If `highest_affected_layer == master-plan`, declare why PRD and arch spec are NOT affected (or, if they are, escalate to PRD/arch-spec scope and add the pre-drafting gate).
7. **Proposed canonical edits** — full diff against live docs, scoped to the highest affected layer. Chain-ordered when single PR would be unreviewable.
8. **Downstream sync ripple plan** — per affected layer below the highest: which sections, which lines, what change.
9. **Architectural-fitness obligations** — named `tests/test_arch_*.py` files for `idc:idc-build`. List every triggered fence; declare `none` only when truly none.
10. **CLAUDE.md tree impact** — required for every change order; declare `none` with one-line rationale when no `CLAUDE.md` is touched. When any `CLAUDE.md` IS touched, enumerate per RS-3's tree-audit findings: (a) which files (root + which subdirs from §Domain Index), (b) whether root CLAUDE.md §Domain Index needs an update, (c) whether content is being moved between layers, (d) cross-reference health. Fenced by `tests/test_arch_idc_workflow.py`.
11. **Operator gates needed** — none for `MINOR_AUTONOMOUS`; pre-merge for `GATED`; pre-drafting AND pre-merge for `MAJOR_GATED`. Per CS-5 `idc:idc-skill-planning-substrate` `gate_mode: ripple` operator-approvals-required output.
12. **Hand-back instructions** — branched on `Pipeline:` per `${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md §A6 handoff protocol`:
    - **Codebase pipeline** → exact next action for the upstream IDC role that filed the Ripple.
    - **Governance pipeline** → exact next action for the upstream `Audit → Plan` flow that filed the Ripple.

For `MINOR_AUTONOMOUS` verdict ONLY, the skill ALSO emits the autonomous-merge ledger format reminder:

```text
Ledger entry (autonomous-merge): docs/workflow/ledgers/<YYYY-MM-DD>-ripple-autonomous-ledger.md
Format: <HH:MM> <change-order-slug> | <pipeline:governance|codebase> | <highest-layer> | <pr-num> | <merge-sha>
```

## Templated output (verbatim shape — do not deviate)

The skill emits the change-order markdown verbatim in this shape. Field order is load-bearing:

```markdown
# Ripple change order — <slug>

> Pipeline: <governance | codebase>
> Verdict: <NO_RIPPLE | MINOR_AUTONOMOUS | GATED | MAJOR_GATED>
> Highest affected layer: <CS-4 layer enum value>

## Trigger

<paragraph from `trigger` input>

## Citation fields

- **Master Plan Section:** <value from `master_plan_section`>
- **Affected Role/Skill Authority:** <value from `affected_role_skill_authority`>

## Highest affected layer

<value from `highest_affected_layer`>

### No higher-layer impact rationale

<paragraph from `no_higher_layer_impact_rationale`>

## Proposed canonical edits

(For each entry in `proposed_canonical_edits`:)

### `<file_path>` §<section>

<diff_or_description>

## Downstream sync ripple plan

| Layer | Sections affected | One-line change |
|-------|-------------------|-----------------|
| <layer> | <sections_affected joined> | <one_line_change> |
| ... | ... | ... |

## Architectural-fitness obligations

| Fence | New or updated | Reason |
|-------|----------------|--------|
| <fence> | <new \| updated> | <reason> |
| ... | ... | ... |

(If empty: "None — change does not trigger any `tests/test_arch_*.py` fence.")

## CLAUDE.md tree impact

<value from `claude_md_tree_impact` — either "none" with one-line rationale OR enumerated block>

## Operator gates

(For each entry in `operator_gates`:)

- **<kind>** — <rationale>

## Hand-back instructions

<paragraph from `hand_back_instructions`>

(IF verdict == MINOR_AUTONOMOUS, append:)

## Autonomous-merge ledger entry

This change order auto-merges per the four-condition gate (RS-2 `idc:idc-skill-ripple-verdict`). Append one line on merge to:

`docs/workflow/ledgers/<YYYY-MM-DD>-ripple-autonomous-ledger.md`

Format: `<HH:MM> <change-order-slug> | <pipeline:governance|codebase> | <highest-layer> | <pr-num> | <merge-sha>`

(IF prior_versions present, append:)

## Prior versions

| Version | Path | Summary of changes |
|---------|------|--------------------|
| <version> | <path> | <summary_of_changes> |
```

## Schema validation

Before emitting, the skill validates:

1. **All required fields present.** Empty / null / missing → `validation_errors[]` includes `missing_field: <name>`.
2. **`pipeline` ∈ `{governance, codebase}`.** Out-of-enum → `validation_errors[]` includes `pipeline_out_of_enum: <value>`.
3. **`verdict` ∈ `{NO_RIPPLE, MINOR_AUTONOMOUS, GATED, MAJOR_GATED}`.** Out-of-enum → `validation_errors[]` includes `verdict_out_of_enum: <value>`.
4. **Both citation fields present.** Empty `master_plan_section` or `affected_role_skill_authority` → `validation_errors[]` includes `citation_field_missing: <name>`.
5. **Citation field consistency with pipeline.** When `pipeline == codebase`, `master_plan_section` MUST cite a section anchor or `<not touched>`; `affected_role_skill_authority` MUST be `<not applicable — codebase pipeline>`. Mirrored when `pipeline == governance`.
6. **CLAUDE.md tree impact present.** Empty → `validation_errors[]` includes `claude_md_tree_impact_missing`.
7. **`MINOR_AUTONOMOUS` requires `ledger_destination`.** When `verdict == MINOR_AUTONOMOUS` AND `ledger_destination` absent → `validation_errors[]` includes `ledger_destination_required_for_autonomous`.
8. **`MAJOR_GATED` requires both pre-drafting AND pre-merge gates.** When `verdict == MAJOR_GATED` AND `operator_gates[]` does not list both kinds → `validation_errors[]` includes `major_gated_missing_dual_gate`.
9. **`GATED` requires pre-merge gate.** When `verdict == GATED` AND `operator_gates[]` does not include `pre-merge` → `validation_errors[]` includes `gated_missing_pre_merge`.
10. **`MINOR_AUTONOMOUS` requires no operator gate.** When `verdict == MINOR_AUTONOMOUS` AND `operator_gates[]` lists any non-`none` kind → `validation_errors[]` includes `autonomous_should_have_no_gate`.

`validation_errors[]` empty → `schema_validation: PASSED` and the skill writes the file. Non-empty → `schema_validation: FAILED` and the skill does NOT write; caller fixes the packet and re-invokes.

## Single-process confirmation

This skill is single-input → single-output: caller hands one packet (assembled fields), skill validates schema and (on PASSED) writes one file to `output_path` and returns `{output_path, schema_validation, validation_errors[], field_count}`. Read+validate+emit-only — never reads canonical docs (the caller pre-assembled everything from upstream skills), never spawns teammates / Task subagents, no state across invocations.

## Banlist

Load-bearing forbiddens:

- **No verdict authoring.** This skill never decides `verdict` value — that's RS-2's authority. The caller passes `verdict` verbatim from RS-2's output.
- **No downstream-sync mapping.** The `downstream_sync_plan` field is pre-computed by RS-2 (`downstream_sync_map`); this skill emits it verbatim.
- **No CLAUDE.md tree drift detection.** The `claude_md_tree_impact` field is pre-computed by RS-3; this skill emits it verbatim. If RS-3 was not invoked (e.g. because no CLAUDE.md surface is touched), the caller passes `none` with rationale.
- **No canonical-doc edits.** The `output_path` MUST be a scratch path (typically under `<scratch_dir>/`); this skill never writes to canonical paths under `docs/workflow/ripple/<slug>-ripple.md`. The canonical move happens at PR-opening time after the operator gate clears (or autonomously for `MINOR_AUTONOMOUS`).
- **No silent schema downgrade.** When validation fails, return `schema_validation: FAILED` and DO NOT write the file. Never silently drop a missing field or coerce an out-of-enum value to a default.
- **No source-code authoring.** Per donor banlist line 64.
- **No paraphrasing the donor field list.** Items 1–12 above are donor verbatim from `idc-ripple/SKILL.md` §"Required Output" lines 12–25; field-name drift breaks the change-order shape that PR-opening tooling expects.

## Codex parity note

Loaded via the Skill tool by `${CLAUDE_PLUGIN_ROOT}/skills/codex-idc-ripple/SKILL.md` after the Codex parent has assembled the field packet (Codex parent invokes RS-1 → RS-2 → RS-3 → this skill in the same procedural order as Claude side). Schema validation is byte-compatible across runtimes — same input packet shape produces same `schema_validation` outcome. Per `appendices/codex-drift-ripple.md`, the codex sibling currently lacks a templated change-order emitter; adopting this skill closes the gap. The `MINOR_AUTONOMOUS` ledger-entry reminder is portable; only the merge-execution step itself is asymmetric (per Q-rip-4 — Codex stops at "verdict + ledger destination surfaced to operator" rather than auto-merging).

## See also

- RS-1 `idc:idc-skill-drift-evidence` — provides the `trigger` field input.
- RS-2 `idc:idc-skill-ripple-verdict` — provides `verdict`, `pipeline`, `highest_affected_layer`, `downstream_sync_plan`, `architectural_fitness_obligations`, `operator_gates` (via CS-5).
- RS-3 `idc:idc-skill-ripple-verdict` — provides `claude_md_tree_impact` (when CLAUDE.md surface is touched).
- RS-5 `idc:idc-skill-plan-review` — Phase 3 reviewer; cross-checks every emitted field against the verdict and the canonical anchors.
- PR-1 `idc:idc-role-change-order-author` — multi-step composition workflow; this skill is PR-1's Phase 4 emit step.
- CS-5 `idc:idc-skill-planning-substrate` — provides `operator_gates` content (boundary_language + operator_approvals_required[]).
- `${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md §Phase 2 change-order template` — parent orchestrator boundary; cites this skill rather than restating the field list.
- `docs/workflow/ripple/README.md` — repo-side ripple template; field shape MUST match this skill's output.
- `tests/test_arch_governance_pipeline.py`, `tests/test_arch_idc_ripple.py::test_minor_autonomous_path_exists`, `tests/test_arch_idc_ripple.py::test_change_order_template_has_required_citation_fields`, `tests/test_arch_idc_workflow.py` — fences this skill's output must satisfy.
- The retired `idc-ripple` umbrella skill — donor (umbrella retired per Q-rip-1; not shipped with this plugin; this skill carries the donor §"Required Output" field list).
