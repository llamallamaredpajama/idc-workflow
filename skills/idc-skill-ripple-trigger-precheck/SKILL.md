---
name: idc-skill-ripple-trigger-precheck
description: 'Use when IDC deconflict work needs to decide whether a clash should trigger Ripple.'
---
# idc:idc-skill-ripple-trigger-precheck (KS-5 — Deconflict)

ADAPT. Wraps CS-4 + RS-2 (and optionally RS-3 for CLAUDE.md-tree-touching clashes) to perform Deconflict's **pre-check** when KS-2 returns a `ripple-required` clash. The skill stages a Ripple-proposal scratch artifact and surfaces the precheck verdict; final Ripple authoring (the canonical change order at `docs/workflow/ripple/<slug>-ripple.md`) is `idc-ripple`'s authority — KS-5 just stages the proposal so the operator has a one-click handoff to invoke `/idc:ripple`.

Per per-role audit `deconflict.md §KS-5`: this skill is **ADAPT (wrapper section in RS-2 OR sibling skill that delegates verdict authority to RS-2)**. We implement the sibling-skill form — RS-2 is the verdict authority; this skill composes RS-2's output with Deconflict's clash-register schema to produce the staged proposal.

Per Q-decon-1 (latent) recommendation: when the clash touches a CLAUDE.md surface (`${CLAUDE_PLUGIN_ROOT}/agents/`, `${CLAUDE_PLUGIN_ROOT}/skills/`, root `CLAUDE.md`, per-directory `CLAUDE.md`, `AGENTS.md`), KS-5 also invokes RS-3 `idc:idc-skill-ripple-verdict` so the staged proposal carries the four scope-classification rules verbatim (anti-redundancy invariant).

## When to invoke

- the orchestrator inline (substrate: `idc:idc-skill-pillar-plan-shape` + `idc:idc-skill-plan-review` + `idc:idc-skill-pillar-clash-analysis`) Phase 1 step 4 — after KS-2 returns a `ripple-required` clash entry, KR-1 calls KS-5 once per such entry.
- KR-1 Phase 1 step 4 (alternate path) — after KS-3 returns a cross-RUN clash flag (landed sibling pillar is immutable; resolution is necessarily Ripple or skip).
- Deconflict parent orchestrator's pre-KR-1 step when triaging whether a multi-subphase polish run can proceed at all (if every candidate pillar is parked on Ripple, halt the run early).

Do NOT invoke from any other IDC role — Engineer/Develop/Sequence/Build all have their own paths into RS-2 (or via the pre-existing canonical-impact-analyst surface) and don't need Deconflict's pre-check shape.

## Input contract

| Field | Shape |
|-------|-------|
| `clash_register_entry` | one row from KS-2's `clash_register` table (or one cross-RUN flag from KS-3's table). Required keys: `pillar_a`, `pillar_b`, `kind` (`ripple-required` only — pre-checking other kinds is out of scope), `resource_kind`, `resource_id`, `evidence`, `proposed_resolution` |
| `paired_pillar_paths` | absolute paths to the candidate pillar plans (or scratch drafts) for `pillar_a` + `pillar_b` — used for context when staging the Ripple proposal body |
| `scratch_dir` | absolute path to the Deconflict run's per-run scratch dir (typically `/tmp/idc-deconflict/<run-id>/`) |
| `output_filename` | basename for the staged Ripple proposal (caller-supplied; defaults to `ripple-proposal-<pillar-a>-<pillar-b>-<slug>.md`) |
| `claude_md_surface_hint` | optional bool — caller's KR-1 sets `true` when the clash touches a CLAUDE.md / agent / skill governance surface; KS-5 invokes RS-3 if true |
| `mode` | `full` (default — stage proposal + return verdict) \| `verdict-only` (return verdict packet without staging proposal artifact) |

## Output contract

The skill returns a structured packet AND (in `full` mode) writes the Ripple-proposal scratch artifact at `<scratch_dir>/<output_filename>`.

### Returned packet

```json
{
  "precheck_verdict": "MINOR_AUTONOMOUS_CANDIDATE | GATED_CANDIDATE | MAJOR_GATED_CANDIDATE | NO_RIPPLE",
  "ripple_proposal_scratch_path": "<absolute path or null in verdict-only mode>",
  "highest_affected_layer": "subphase | master-plan | arch-spec | prd | governance",
  "pipeline": "codebase | governance",
  "downstream_sync_hints": ["<doc-path>", "..."],
  "architectural_fitness_obligations": ["<test-module-path>", "..."],
  "claude_md_tree_findings": ["<RS-3 finding>", "..."]  // present only when claude_md_surface_hint=true
  "rationale": "<1-paragraph explanation>",
  "delegated_to_rs2": true,
  "delegated_to_rs3": true | false
}
```

The verdict suffix `_CANDIDATE` is intentional — KS-5 surfaces the LIKELY classification but the binding 4-value verdict is RS-2's authority on Ripple's side. KR-1's brief to the operator says: *"Deconflict pre-checked this as `<verdict>_CANDIDATE`; Ripple's `idc:idc-skill-ripple-verdict` makes the final call when `/idc:ripple` runs."* Severity-downsizing the candidate verdict is a banlist violation.

### Staged Ripple proposal artifact (verbatim shape)

```markdown
# Ripple proposal (Deconflict pre-check) — `<pillar_a>` ↔ `<pillar_b>`

**Source clash:** KS-2 (intra-RUN) | KS-3 (cross-RUN)
**Proposed pipeline:** `<pipeline>` (Deconflict pre-classification — RS-2 final)
**Highest affected layer (pre-check):** `<highest_affected_layer>` (RS-2 final)
**Verdict candidate:** `<precheck_verdict>` (RS-2 final)

## Source clash entry

| Pillar A | Pillar B | Kind | Resource Kind | Resource ID | Proposed Resolution |
|----------|----------|------|---------------|-------------|---------------------|
| `<pillar_a>` | `<pillar_b>` | `<kind>` | `<resource_kind>` | `<resource_id>` | `<proposed_resolution>` |

## Evidence

<verbatim copy of `clash_register_entry.evidence` — multi-paragraph quote of the conflicting acceptance criteria, file-surface declarations, dependency edges, etc. Cite line numbers in pillar plans / subphase plans / master-plan section.>

## Why upstream is wrong (pre-check rationale)

<1-2 paragraphs naming the highest affected canonical layer (subphase | master-plan | arch-spec | prd) and the upstream doc that needs repair. This is Deconflict's pre-check rationale; Ripple's `canonical-impact-analyst` re-evaluates with full RS-2 logic on the Ripple side.>

## Downstream-sync hints (pre-check)

<bulleted list of canonical docs that likely need synchronization — RS-2's `downstream_sync_map` is authoritative; this is Deconflict's hint shaped from the clash evidence.>

## Architectural-fitness obligations

<bulleted list of `tests/test_arch_*.py` modules that may need updates if the upstream doc lands the proposed correction. Example: a clash that proves the §IDC role authority table omits a banned action would touch `tests/test_arch_idc_workflow.py::test_role_boundaries_are_documented`.>

## CLAUDE.md tree findings (RS-3, if invoked)

<verbatim splice of RS-3 `tree_drift_findings[]` — present only if `claude_md_surface_hint=true`. Else omit this section.>

## Operator handoff

To finalize: `/idc:ripple` with this proposal as input. Ripple's Phase 1 will:
1. Run CS-4 binary classification (likely confirms `pipeline = <pipeline>`).
2. Run RS-2 4-value classification + downstream-sync map (binding).
3. Decide gate path:
   - `MINOR_AUTONOMOUS` → autonomous merge per the four-condition gate.
   - `GATED` / `MAJOR_GATED` → operator approval before merge.
   - `NO_RIPPLE` → Ripple bounces; clash returns to Deconflict for in-pillar reconciliation.
4. Author the canonical change order at `docs/workflow/ripple/<slug>-ripple.md`.

## Affected pillars (parked until Ripple lands)

- `<pillar_a>` — paused at scratch path `<paired_pillar_paths[0]>`
- `<pillar_b>` — paused at scratch path `<paired_pillar_paths[1]>`

KR-1 continues polishing non-clashing pillars per "don't stop the train" — these two return to polish after Ripple closes.
```

## Procedure

1. **Validate inputs**:
   - `clash_register_entry.kind` MUST be `ripple-required` OR `clash_register_entry.proposed_resolution` MUST be `ripple-required`. Other clash kinds → `BLOCKED — clash kind/resolution is not ripple-required (caller routed to KS-5 by mistake)`.
   - `paired_pillar_paths` has exactly 2 entries (cross-RUN flags from KS-3 may have only 1 candidate-side path; the landed sibling has its `docs/plans/pillars/...` path — both still required).
   - `scratch_dir` writable.
2. **Compose CS-4 input**: derive `proposed_edit_paths[]` = the upstream canonical-doc paths the clash points at (subphase plan, master-plan section, arch-spec section, PRD section, OR governance surface like the folded `idc-deconflict` orchestrator's agent body (now `idc:idc-plan`)). Construct `edit_summary` = 1-line description from `clash_register_entry.evidence`.
3. **Invoke CS-4 `idc:idc-skill-ripple-verdict`** with the composed input. Capture `{pipeline, verdict, highest_affected_layer, arch_fitness_obligations}`.
4. **Map CS-4 verdict**:
   - If CS-4 returns `verdict: tracker-only` → `precheck_verdict = NO_RIPPLE`, return immediately. Caller's KR-1 routes the clash back to KS-2's in-pillar-resolution path (the caller mis-classified the clash as `ripple-required` when it was actually reconcilable in-pillar).
   - If CS-4 returns `verdict: ripple-required` → continue to step 5.
5. **Invoke RS-2 `idc:idc-skill-ripple-verdict`** with composed input from CS-4 output + the clash-evidence block as `citation_fields`. Capture `{verdict, highest_affected_layer, pipeline, downstream_sync_map, architectural_fitness_obligations, rationale}`.
   - Note: KS-5 INVOKES RS-2 for pre-check classification; the binding final classification still runs inside `idc-ripple` Phase 1. KS-5's call to RS-2 here is for "what would Ripple likely say?" — the answer becomes the candidate verdict.
6. **Map RS-2 verdict to candidate**:
   - RS-2 `NO_RIPPLE` → `NO_RIPPLE` (same — clash bounces back to in-pillar reconciliation).
   - RS-2 `MINOR_AUTONOMOUS` → `MINOR_AUTONOMOUS_CANDIDATE` (the four-condition gate is RS-2's logic; KS-5 reports the candidate, never overrides).
   - RS-2 `GATED` → `GATED_CANDIDATE`.
   - RS-2 `MAJOR_GATED` → `MAJOR_GATED_CANDIDATE`.
7. **Optionally invoke RS-3 `idc:idc-skill-ripple-verdict`** if `claude_md_surface_hint=true` OR if any path in `proposed_edit_paths[]` is under `${CLAUDE_PLUGIN_ROOT}/agents/`, `${CLAUDE_PLUGIN_ROOT}/skills/`, root `CLAUDE.md`, or matches the per-directory CLAUDE.md tree. Capture `tree_drift_findings[]` for the proposal artifact.
8. **Stage the Ripple proposal** at `<scratch_dir>/<output_filename>` per the artifact shape above.
9. **Return** the structured packet per the output contract.

In `verdict-only` mode, skip step 8 — return packet only.

## Halt conditions

| Halt | When |
|------|------|
| `BLOCKED — clash kind/resolution is not ripple-required` | step 1 — caller routed by mistake |
| `BLOCKED — paired_pillar_paths must have exactly 2 entries` | step 1 |
| `BLOCKED — scratch_dir not writable` | step 1 |
| `BLOCKED — CS-4 invocation failed: <reason>` | step 3 |
| `BLOCKED — RS-2 invocation failed: <reason>` | step 5 |
| `BLOCKED — RS-3 invocation failed: <reason>` | step 7 (only when claude_md_surface_hint=true) |

KS-5 does NOT halt on `precheck_verdict = NO_RIPPLE` — that's a normal return path indicating the clash should bounce back to in-pillar reconciliation. Caller decides next step.

## Banlist

- **Do NOT author the canonical Ripple change order at `docs/workflow/ripple/<slug>-ripple.md`.** That is `idc-ripple`'s authority. KS-5 stages a SCRATCH proposal at `<scratch_dir>/ripple-proposal-*.md`; the operator invokes `/idc:ripple` to author the canonical version.
- **Do NOT override RS-2's verdict.** KS-5 maps RS-2's verdict to a `_CANDIDATE` suffix and surfaces it for operator handoff. Severity-downsizing or upgrading the candidate is forbidden — RS-2 is the verdict authority.
- **Do NOT classify into `MINOR_AUTONOMOUS` directly.** Per CS-4's banlist (and the catalog description): "the 4-value Ripple verdict + the four-condition `MINOR_AUTONOMOUS` gate live in RS-2 (Ripple-internal). Do not classify into `MINOR_AUTONOMOUS` etc. from this skill." KS-5 obeys by delegating to RS-2.
- **Do NOT call RS-2 for non-Ripple-required clashes.** KS-5's input contract enforces — `kind/resolution` must be `ripple-required` or pre-check halts. KS-2's other clash kinds resolve in-pillar via WM-2 + KR-1 reasoning, not via RS-2.
- **Do NOT modify any canonical doc.** Read CS-4 / RS-2 / RS-3 outputs only; emit-only to `<scratch_dir>`.
- **Do NOT bypass CS-4 → RS-2 chain.** The two-step delegation is the load-bearing contract — CS-4 produces the binary pipeline classification, RS-2 layers the 4-value verdict. Skipping CS-4 means losing the pipeline annotation that Ripple's surface-based classification rule depends on.
- **Do NOT delete the staged proposal scratch artifact.** Caller's KR-1 closeout (or operator handoff) decides whether to commit to a canonical Ripple PR or discard. KS-5 emits and returns; lifecycle is the caller's concern.
- **Do NOT call `idc-ripple` directly from this skill.** The Ripple invocation is the operator's act per the operator-is-lead invariant. KS-5 stages; operator decides.

## Cross-references

- **Composes:**
  - CS-4 `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-ripple-verdict/SKILL.md` (binary classification)
  - RS-2 `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-ripple-verdict/SKILL.md` (4-value verdict + downstream-sync map)
  - RS-3 `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-ripple-verdict/SKILL.md` (optional, when CLAUDE.md surface touched)
- **KR-1 caller:** the orchestrator inline (PR-5 fold; see substrate skills) (Phase 1 step 4 — invoked once per `ripple-required` clash entry from KS-2 or cross-RUN flag from KS-3)
- **Upstream sources:**
  - KS-2 `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-pillar-clash-analysis/SKILL.md` (intra-RUN clashes — `ripple-required` entries route here)
  - KS-3 `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-sibling-pillar-precedent-review/SKILL.md` (cross-RUN clashes — landed siblings are immutable, route here)
- **Authority sources:**
  - the folded `idc-deconflict` orchestrator (now `idc:idc-plan`) §Ripple trigger (lines 128-138)
  - per-role audit `deconflict.md §KS-5`
  - audit appendix `open-questions.md §Q-decon-1` (CLAUDE.md-tree-audit composition rationale)
- **Operator handoff target:** `/idc:ripple` slash command → `${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md` Phase 1
