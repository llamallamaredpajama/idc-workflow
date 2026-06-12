---
name: idc-skill-ripple-verdict
description: 'Use when IDC Ripple needs a structured verdict on drift, canonical impact, or downstream repair.'
---
# IDC Skill — Ripple Verdict (`idc:idc-skill-ripple-verdict`)

CONSOLIDATED. Single Ripple-side classifier that absorbs three formerly-separate verdict skills behind one call. Single-process — the caller passes one input packet covering the proposed edit, citation fields, fence state, BLOCKING delta, and (optionally) the repo root for tree audit; the skill returns one consolidated verdict tuple. The internal pipeline is structured as three sub-procedures (`pipeline-classify`, `tree-audit-when-claude-md`, `verdict-classify`) but the caller never sees the sub-procedure boundaries — the return tuple is single-shape.

## Largest shared callsite shape

Caller-visible surface — one packet in, one packet out, optional one drift-report file out:

- **Input:** `{proposed_edit_paths[], edit_summary, citation_fields, arch_fitness_state, blocking_todo_delta, repo_root, scratch_dir, output_path?, pipeline_hint?, tree_audit_only?, binary_verdict_only?}`
- **Output (return packet):** `{verdict, pipeline, highest_affected_layer, downstream_sync_map, arch_fitness_obligations[], claude_md_tree_drift_findings[], scope_classification_violations[], operator_approvals_required[], ledger_destination?, governance_verdict, pipeline_hint_disagreed?, rationale, report_path?}`
- **Output (file, when `output_path` is set AND any proposed_edit_path touches a CLAUDE.md surface):** drift report at `output_path`.

When the caller is a non-Ripple role that just needs the binary verdict (CS-4 surface), it passes `binary_verdict_only: true` — the skill returns `{verdict ∈ {tracker-only, ripple-required}, pipeline, highest_affected_layer, arch_fitness_obligations[], rationale}` and skips Ripple-internal computation. When the caller is the CLAUDE.md tree auditor (RS-3 surface), it passes `tree_audit_only: true` — the skill returns `{governance_verdict, claude_md_tree_drift_findings[], scope_classification_violations[], required_pre_drafting_gates[], required_pre_merge_gates[], rationale, report_path}` and writes the drift report. The default call (no flags) returns the full consolidated tuple.

## When to invoke

Inside any IDC role at every canonical-doc-edit decision point:

- **Plan pre-drafting / master-plan-section-admitted check / clash-vs-Ripple decision** — call with `binary_verdict_only: true` for the binary `tracker-only` vs `ripple-required` decision (formerly CS-4 surface).
- **Sequence tracker-only-vs-Ripple** — call with `binary_verdict_only: true`.
- **Build pre-PR Ripple Audit** — call with `binary_verdict_only: true` against the implementation diff.
- **Ripple parent orchestrator (`${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md` Phase 1)** — call with the default flags (no `binary_verdict_only`, no `tree_audit_only`) for the full 4-value verdict + tree-audit + downstream-sync map.
- **PR-1 `idc:idc-role-change-order-author` Phase 1+2** — call with default flags so the change-order author has the full consolidated tuple to feed into RS-4 `idc:idc-skill-change-order-shape`.
- **the orchestrator inline (substrate: `idc:idc-skill-canonical-admission-audit`) mode=`ripple` Phase 4** — call with default flags.
- **CS-5 `canonical-gate-enforcement` `gate_mode: ripple`** — caller passes this skill's `verdict` as `ripple_verdict` input so CS-5 emits the right `operator_approvals_required[]` list.
- **`idc-deconflict` (now `idc:idc-plan`) / `idc-build` orchestrator Ripple-trigger pre-classification** — call with `tree_audit_only: true` when a Ripple-trigger proposal touches a CLAUDE.md surface.

## Input shape

Caller passes a single packet with:

- `proposed_edit_paths[]` — list of repo-relative paths the proposed change order would touch.
- `edit_summary` — one-paragraph free-form description of the intended change (used to disambiguate semantic-vs-status changes and scope-classification — e.g. "add cross-cutting Firestore-canonical rule" vs "add Cloud Run Dockerfile package path").
- `citation_fields` — an explicit citation block:
  - `master_plan_section` — string (codebase pipeline). Value `<not touched>` or `<no semantic change to §X.Y>` indicates no upstream-parent intent change. Field absent → fall back to GATED.
  - `affected_role_skill_authority` — string (governance pipeline). Value `<not touched>` or `<no semantic change to §X.Y>` indicates no upstream-parent intent change. Field absent → fall back to GATED.
- `arch_fitness_state` — `{any_fence_triggered: bool, triggered_fences[]}`. Composed from this skill's own `arch_fitness_obligations` (re-derived per call) plus a green/red status check on each by the caller.
- `blocking_todo_delta` — `{blocking_added: int, blocking_removed: int}`. Counts of operator-todo BLOCKING items the proposed Ripple would add or remove (typically zero; non-zero forces fall-back to GATED).
- `repo_root` — absolute path to the repo root (e.g. `<governed-repo>`). Required for the tree-audit sub-procedure when CLAUDE.md surfaces are touched.
- `scratch_dir` — absolute path to the caller's scratch dir.
- `output_path?` — optional. Absolute path where the drift report writes (typically `<scratch_dir>/claude-md-tree-audit.md`). Required when `tree_audit_only: true` OR any proposed_edit_path touches a CLAUDE.md surface.
- `pipeline_hint?` — optional caller assertion of `governance | codebase`. The skill computes its own verdict from `proposed_edit_paths[]`; if the hint disagrees with the computed pipeline, the response includes a `pipeline_hint_disagreed: true` flag so the caller can halt and re-route.
- `tree_audit_only?` — optional bool; default `false`. When `true`, only the tree-audit sub-procedure runs.
- `binary_verdict_only?` — optional bool; default `false`. When `true`, only the pipeline-classify sub-procedure runs (binary `tracker-only` vs `ripple-required`).

## Output shape

A single response packet (and a drift-report file when CLAUDE.md surfaces are touched):

```yaml
verdict: NO_RIPPLE | MINOR_AUTONOMOUS | GATED | MAJOR_GATED   # OR tracker-only | ripple-required when binary_verdict_only
pipeline: governance | codebase
highest_affected_layer: <one of the layer enum values below>
downstream_sync_map:
  - layer: <one of {prd, architecture-spec, master-plan, subphase, pillar, tracker, governance-fence, root-claude-md, subdir-claude-md, agents-md}>
    sync_required: true | false
    sections_affected: [<list of section anchors or file paths>]
    one_line_change: <verbatim one-line description>
arch_fitness_obligations:
  - fence: tests/test_arch_<name>.py::<test or n/a>
    new_or_updated: new | updated
    reason: <why this fence applies>
claude_md_tree_drift_findings:
  - signature: root_vs_subdir_contradiction | stale_domain_index_coverage | root_subdir_rule_duplication | dangling_cross_reference
    severity: blocker | major | minor
    files: [<list of CLAUDE.md paths>]
    description: <verbatim quote of the contradicting / duplicating / dangling content>
    proposed_resolution: <one-line recommendation>
scope_classification_violations:
  - rule: cross_cutting_to_root | domain_specific_to_subdir | add_remove_rename_subdir | move_rule_relocate_not_duplicate
    description: <how the proposed edit violates the rule>
    proposed_resolution: <one-line recommendation>
operator_approvals_required: []   # zero, one, or two entries from {"pre-drafting", "pre-merge"}
ledger_destination?: <docs/workflow/ledgers/<YYYY-MM-DD>-ripple-autonomous-ledger.md, only when verdict == MINOR_AUTONOMOUS>
governance_verdict: COMPLIANT | CONDITIONAL | BLOCKED   # only when CLAUDE.md surfaces are touched
required_pre_drafting_gates: []   # only when CLAUDE.md surfaces are touched
required_pre_merge_gates: []      # only when CLAUDE.md surfaces are touched
pipeline_hint_disagreed?: true | false   # only when pipeline_hint was passed
report_path?: <abs path the drift report wrote to>   # only when output_path was set AND CLAUDE.md surfaces touched
rationale: <one short paragraph: surface match + verdict reasoning + four-condition outcome if MINOR_AUTONOMOUS + tree-audit findings if any>
```

### Verdict enum (default 4-value)

| Verdict | Meaning |
|---------|---------|
| `NO_RIPPLE` | No canonical drift detected; the original drift signal was a false positive. No PR opens. |
| `MINOR_AUTONOMOUS` | All four conditions in §"MINOR_AUTONOMOUS path — four-condition gate (verbatim)" hold. Auto-merge the change-order PR; append one line to the autonomous ledger. |
| `GATED` | Operator approval required BEFORE merge. Master plan / subphase / pillar / root CLAUDE.md / `docs/workflow/CLAUDE.md` / governance fence scope. |
| `MAJOR_GATED` | Operator approval required BEFORE drafting AND BEFORE merge. PRD / arch-spec scope. |

### Verdict enum (`binary_verdict_only` mode)

| Verdict | Meaning |
|---------|---------|
| `tracker-only` | Status / order / wave-queue change only on TRACKER. No Ripple required. |
| `ripple-required` | Anything else. Caller files Ripple via PR-1 `idc:idc-role-change-order-author`; Ripple's parent orchestrator then re-invokes this skill with default flags for the full 4-value verdict + downstream-sync map. |

### Layer enum

| Layer value | When emitted |
|-------------|--------------|
| `prd` | Edit touches `docs/prd/prd.md` OR product/user-need behavior changes elsewhere |
| `architecture-spec` | Edit touches `docs/specs/master-architectural-spec.md` OR an architecture / schema / runtime / security contract changes |
| `master-plan` | Edit touches `docs/plans/master-implementation-plan.md` OR domain/phase decomposition changes |
| `subphase` | Edit touches `docs/plans/subphases/<...>.md` |
| `pillar` | Edit touches `docs/plans/pillars/<...>.md` |
| `tracker-only` | Edit touches `TRACKER.md` only AND `edit_summary` indicates status/order/wave-queue update without scope change |
| `root-claude-md` | Edit touches `CLAUDE.md` (root) — cross-cutting rule applies repo-wide |
| `subdir-claude-md` | Edit touches a per-directory `CLAUDE.md` listed in root §Domain Index — domain-specific rule applies inside one subdir |
| `claude-md-tree-restructure` | Edit adds / removes / renames a subdir `CLAUDE.md`, or moves a rule between root and subdir |
| `agent-file` | Edit touches an agent body in the workflow-definition surface — the idc-workflow plugin repo's `agents/` (an orchestrator `idc-*.md` or a role agent file), edited via plugin-repo PRs, never the installed plugin copy |
| `skill-file` | Edit touches a skill `SKILL.md` body in the workflow-definition surface (the idc-workflow plugin repo's `skills/`), edited via plugin-repo PRs |
| `governance-fence` | Edit touches `tests/test_arch_*.py` whose source surfaces are governance per the surface-based fence rule |
| `code-fence` | Edit touches `tests/test_arch_*.py` whose source surfaces are codebase |
| `runtime-code` | Edit touches product / runtime code (the governed repo's source dirs per `WORKFLOW-config.yaml` — e.g. `services/`, `web/`, `scripts/`) or runtime config (e.g. database rules / index definitions) |
| `hooks` | Edit touches `~/.claude/hooks/` |

## Sub-procedure 1 — Pipeline classification (formerly CS-4)

Every canonical-edit pipeline gates through Ripple. The pipeline is determined by **surface of truth** — the kind of file being edited — per `docs/workflow/canonical-chain.md §Pipeline classification`.

### Pipeline = `governance`

Drift surface is one of:
- the workflow-definition surfaces: the idc-workflow plugin repo's `agents/` and `skills/` (edited via plugin-repo PRs, never the installed plugin copy)
- root `CLAUDE.md` + per-directory CLAUDE.md tree (per root §Domain Index)
- governance directories under `docs/workflow/` (audits, code-reviews, ledgers, ripple, handoffs, operator-todos, plans, pillar-conflicts)
- governance fences (any `tests/test_arch_*.py` whose source surfaces include the workflow-definition surfaces, `~/.claude/hooks/`, any `CLAUDE.md`, governance directories under `docs/workflow/`, or `TRACKER.md`)
- `~/.claude/hooks/`

Lighter `Audit → Plan → PR` path; this skill plus Ripple are the canonical-edit guard at the PR boundary.

### Pipeline = `codebase`

Drift surface is product / runtime code, canonical specs, planning docs, and non-governance fences:
- the governed repo's source dirs per `WORKFLOW-config.yaml` (e.g. `services/`, `web/`, `scripts/`)
- `docs/prd/`, `docs/specs/`
- `docs/plans/master-implementation-plan.md`, `docs/plans/subphases/`, `docs/plans/pillars/`, `docs/plans/<YYYY-MM-DD>-*.md`
- `firestore.{rules,indexes.json}`
- `pyproject.toml`, `firebase.json`, `web/` package files
- non-governance fences

Full IDC chain (`Think → Plan → Sequence → Build`) with Ripple as canonical-edit guard.

### Surface-based fence rule

A `tests/test_arch_*.py` fence is **governance** iff its source surfaces include any of: the workflow-definition surfaces (the idc-workflow plugin repo's `agents/` / `skills/` / `commands/`), `~/.claude/hooks/`, any `CLAUDE.md`, `docs/workflow/`, or `TRACKER.md`. Else it is **codebase**. Mechanical — recoverable by inspection of the fence's source surfaces.

### Highest Affected Layer Rules (Codebase pipeline)

- Product/user-need change → `prd` and downhill.
- Architecture/schema/runtime/security contract change → `architecture-spec` and downhill, plus `prd` if user-facing behavior changes.
- Domain/phase decomposition change → `master-plan` and downhill.
- Subphase strategy/dependency change → `subphase` and downhill unless master-plan domain/phase boundaries change.
- Pillar implementation detail change → `pillar` and tracker only unless subphase acceptance/dependency changes.
- Status/order-only change → `tracker-only`.

### Highest Affected Layer Rules (Governance pipeline)

- Cross-cutting CLAUDE.md change → `root-claude-md`.
- Domain-specific CLAUDE.md change → `subdir-claude-md`.
- Add / remove / rename a subdir `CLAUDE.md`, or move a rule between root and subdir → `claude-md-tree-restructure`.
- Agent file body / authority boundary change → `agent-file`.
- Skill body / contract change → `skill-file`.
- Governance fence change → `governance-fence`.
- Hook script change → `hooks`.

### Binary-verdict computation (closed-form predicate)

Compute in this order:

1. If `highest_affected_layer == tracker-only` AND `edit_summary` indicates ONLY status/order/wave-queue change → `binary verdict: tracker-only`.
2. Else → `binary verdict: ripple-required`. (Anything that touches PRD, architecture spec, master plan, subphase, pillar, root CLAUDE.md, subdir CLAUDE.md, CLAUDE.md tree restructure, agent file, skill file, governance fence, hooks, or runtime code is `ripple-required`.)

### Architectural-fitness obligations enumeration

The skill enumerates which `tests/test_arch_*.py` fences are triggered by `proposed_edit_paths[]` so the caller can declare them up-front in the change order or PR body. Mechanical lookup against the fence-surface mapping (e.g. an edit to `${CLAUDE_PLUGIN_ROOT}/agents/idc-think.md` triggers `tests/test_arch_idc_agents.py` and `tests/test_arch_idc_workflow.py`; an edit to root `CLAUDE.md` may trigger `tests/test_arch_idc_workflow.py` + `tests/test_arch_idc_role_audits.py` + others).

When `binary_verdict_only: true` is passed, the skill returns after this sub-procedure with `{verdict ∈ {tracker-only, ripple-required}, pipeline, highest_affected_layer, arch_fitness_obligations[], rationale, pipeline_hint_disagreed?}` and skips sub-procedures 2 and 3.

## Sub-procedure 2 — CLAUDE.md tree audit (formerly RS-3)

Runs when any path in `proposed_edit_paths[]` touches a CLAUDE.md surface (root, per-directory listed in §Domain Index, or `AGENTS.md`) OR when `tree_audit_only: true`.

### Tree-drift signatures (the 4 detection patterns)

This skill detects four CLAUDE.md tree drift signatures (per `${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md §Phase 1 governance-auditor` returns description):

#### 1. Root-vs-subdir contradiction

**Detection:** root CLAUDE.md says "X" about a subdir's domain; the subdir's own CLAUDE.md says "Y" (where X and Y are mutually exclusive).

**Severity:** Blocker (per root CLAUDE.md authority rule: "subdir CLAUDE.md wins inside its subdir; flag conflicts").

**Resolution:** Relocate the rule to its correct layer (cross-cutting → root; domain-specific → subdir). Never silently pick one side.

#### 2. Stale §Domain Index coverage

**Detection:** root CLAUDE.md §Domain Index lists a subdir whose CLAUDE.md no longer exists, OR omits a subdir CLAUDE.md that does exist, OR the per-row "covers" summary no longer matches the subdir CLAUDE.md's actual scope.

**Severity:** Major (governance fence — root §Domain Index is the authoritative inventory).

**Resolution:** Update root §Domain Index to match the actual file inventory in the same PR.

#### 3. Root↔subdir rule duplication

**Detection:** the same rule appears verbatim (or near-verbatim) in both root CLAUDE.md and a subdir CLAUDE.md.

**Severity:** Major (anti-redundancy invariant — the same rule MUST NOT live in two CLAUDE.mds at once; when the change-order author finds duplication, the Ripple consolidates rather than letting both copies drift).

**Resolution:** Relocate the rule to the correct layer; remove the duplicate copy. Cross-cutting rule belongs in root only; domain-specific rule belongs in subdir only.

#### 4. Dangling cross-reference

**Detection:** root CLAUDE.md (or a subdir CLAUDE.md) contains a pointer like "see `<other-dir>/CLAUDE.md` for X" that no longer resolves to the named section (the section was removed, renamed, or the target file was deleted).

**Severity:** Minor (does not block landing the Ripple but should be fixed in the same PR when in scope).

**Resolution:** Update the cross-reference to point at the correct anchor, OR remove the pointer if the cited content moved layer.

### Scope-classification rules — VERBATIM (Q-rip-3)

**Per Q-rip-3 binding decision, the four scope-classification rules live in this skill body verbatim.** `${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md §"CLAUDE.md tree maintenance"` cites this skill rather than restating the rules. Anti-redundancy invariant: rules cannot live in 2 places at once.

The four rules apply when authoring a Ripple that touches CLAUDE.md:

#### Rule 1 — Cross-cutting → root

**Cross-cutting rule** (applies repo-wide, e.g. dual-LLM split, Firestore-canonical invariant): edit root `CLAUDE.md`; do NOT also paste the same rule into a subdir CLAUDE.md.

#### Rule 2 — Domain-specific → subdir

**Domain-specific rule** (applies inside one subdir only, e.g. Cloud Functions Eventarc binding, Cloud Run Dockerfile package path): edit that domain's subdir `CLAUDE.md`; if root CLAUDE.md §Domain Index coverage summary for that subdir is now stale, update the summary in the same PR.

#### Rule 3 — Adding / removing / renaming a subdir CLAUDE.md

**Adding / removing / renaming a subdir CLAUDE.md:** root CLAUDE.md §Domain Index gets a new / removed / renamed row in the same PR; the subdir CLAUDE.md's scope claim aligns with the table summary.

#### Rule 4 — Moving a rule between root and subdir (relocate, never duplicate)

**Moving a rule between root and subdir** (relocation, never duplication): edit both files in the same PR. The change order's CLAUDE.md tree impact bullet states "no duplication remains" explicitly.

#### Authority rule (companion)

**From root CLAUDE.md verbatim:** "subdir CLAUDE.md wins inside its subdir; flag conflicts." Auto-load discipline: every per-directory `CLAUDE.md` auto-loads when any file in that directory is read; reach across directory boundaries by reading the relevant subdir CLAUDE.md explicitly.

### Tree-audit procedure

1. **Read the root `CLAUDE.md` §Domain Index table.** This is the authoritative inventory of subdir CLAUDE.md files. The table has columns `Directory | CLAUDE.md covers`. Parse every listed directory.

2. **Verify each listed subdir CLAUDE.md exists.** For every row in §Domain Index, check that `<repo_root>/<Directory>/CLAUDE.md` exists. Missing → signature 2 (stale §Domain Index coverage), severity Major.

3. **Discover unlisted subdir CLAUDE.md files.** Walk the repo for any `CLAUDE.md` files NOT in §Domain Index. Each unlisted file is signature 2 (stale §Domain Index coverage), severity Major.

4. **Read every listed subdir CLAUDE.md.** For each, compare the scope claim (top of file) against the §Domain Index "covers" summary. Mismatch → signature 2, severity Major.

5. **Read AGENTS.md** if present. AGENTS.md is the Codex-facing entry point per root `CLAUDE.md §Key Docs`; verify any cross-references to CLAUDE.md tree resolve correctly (signature 4 detection).

6. **Read the proposed-edit-paths CLAUDE.md files.** For each proposed edit, read the current content (before-state) and the `edit_summary` (after-state intent).

7. **Cross-check rule duplication (signature 3).** For every proposed edit body, scan the OTHER CLAUDE.md files for duplicate or near-duplicate rule text. Threshold: any 3+ consecutive rule sentences appearing verbatim or near-verbatim in two locations is duplication. Hit → signature 3, severity Major.

8. **Cross-check rule contradictions (signature 1).** For root vs each affected subdir, compare claims about overlapping concerns (e.g. root says "no service accounts for family sync" while subdir says "use service account"). Hit → signature 1, severity Blocker.

9. **Cross-check cross-references (signature 4).** Walk every "see `<path>/CLAUDE.md` for X" pointer in root + subdirs + AGENTS.md. Verify the named section still exists at the cited location. Miss → signature 4, severity Minor.

10. **Apply scope-classification rules (Rules 1–4 above).** For the proposed edit:
    - If edit is cross-cutting (per `edit_summary`) but goes into a subdir → violation of Rule 1.
    - If edit is domain-specific but goes into root → violation of Rule 2.
    - If edit adds/removes/renames a subdir CLAUDE.md but does NOT update root §Domain Index in the same PR → violation of Rule 3.
    - If edit moves a rule between root and subdir but leaves the original copy in place → violation of Rule 4.

11. **Compute `governance_verdict`.** `BLOCKED` if any Blocker-severity finding OR any Rule violation that the change order does not explicitly resolve. `CONDITIONAL` if Major or Minor findings exist but are resolvable in the same PR. `COMPLIANT` if no findings.

12. **Compute required gates.** For governance pipeline edits to root CLAUDE.md or `docs/workflow/CLAUDE.md`, `required_pre_merge_gates` includes `["operator-approval-pre-merge"]`. PRD / arch-spec implications surface as `required_pre_drafting_gates`.

13. **Write the drift report** to `output_path`.

### Governance verdict enum

| Verdict | Meaning |
|---------|---------|
| `COMPLIANT` | Tree is internally consistent; proposed edit conforms to the four scope-classification rules; no drift findings. |
| `CONDITIONAL` | Tree is internally consistent OR has only minor drift, but the proposed edit requires additional coordinated edits in the same PR (e.g. root §Domain Index update for a new subdir). The change order MUST enumerate the coordinated edits in its "CLAUDE.md tree impact" section. |
| `BLOCKED` | Tree has Blocker-severity drift (root-vs-subdir contradiction, scope-rule violation, or rule-duplication that the proposed edit would compound). The change order MUST resolve the drift in the same PR; halt to operator if the resolution exceeds the change order's stated scope. |

### Drift report shape (verbatim)

```markdown
# CLAUDE.md tree audit — <run-id or change-order-slug>

## Verdict
- governance_verdict: <COMPLIANT | CONDITIONAL | BLOCKED>

## Inventory
- Root CLAUDE.md path: <abs path>
- Subdir CLAUDE.md count (per §Domain Index): <N>
- Listed subdir CLAUDE.mds verified present: <N/N>
- Unlisted subdir CLAUDE.mds discovered: <N> (each is signature 2)
- AGENTS.md present: yes | no

## Drift findings
(Per finding: signature, severity, files, verbatim description, proposed_resolution.)

## Scope-classification rule check
(Per Rule 1–4: applied / not applied; violation if any.)

## Required gates
- pre-drafting: <list>
- pre-merge: <list>

## Rationale
<one-paragraph synthesis of verdict + findings + gate requirements>
```

When `tree_audit_only: true` is passed, the skill returns after this sub-procedure with `{governance_verdict, claude_md_tree_drift_findings[], scope_classification_violations[], required_pre_drafting_gates[], required_pre_merge_gates[], rationale, report_path}` and skips sub-procedure 3.

## Sub-procedure 3 — 4-value Ripple verdict + downstream-sync map (formerly RS-2)

### MINOR_AUTONOMOUS path — four-condition gate (verbatim)

This subsection is **fence-pinned by `tests/test_arch_idc_ripple.py::test_minor_autonomous_path_exists`** — the four conditions appear here verbatim from source plan §R1 (`docs/workflow/plans/workflow-changes/2026-05-01-idc-alignment-remediation-plan.md` §"Item R1 — Wire autonomous-minor Ripple path"). **Do NOT paraphrase.**

`canonical-impact-analyst` returns `MINOR_AUTONOMOUS` when ALL FOUR of the following conditions hold:

1. Highest affected layer is **subphase or pillar only** (codebase) OR **agent-file body or skill body** (governance) — never master plan, arch spec, PRD, root CLAUDE.md, docs/workflow/CLAUDE.md, or any governance fence.
2. The change does not alter the upstream parent's intent — change-order MUST cite an explicit `Master Plan Section:` (codebase) or `Affected Role/Skill Authority:` (governance) field with value `<not touched>` or `<no semantic change to §X.Y>`. Field absent → fall back to GATED.
3. Architectural-fitness fences are not triggered.
4. No operator-todo BLOCKING is added or removed.

If any of the four conditions fail, the verdict falls back to `GATED` (or `MAJOR_GATED` for PRD / arch-spec scope). The four-condition gate is the primary path to autonomous merge;
the only other path is the mechanical doc-sync class (mirror section below).
There is no kill switch (operator declined per source plan §R1 Q3); the four-condition gate plus the autonomous ledger as post-hoc audit channel is the safety net. No new TRACKER status code is introduced (per §R1 Q4 — autonomous Ripples by definition do not pause).

In `MINOR_AUTONOMOUS` mode, Ripple drafts and merges the change order without operator pre-merge gating, files the change-order doc as the durable record, AND appends a one-line entry to `docs/workflow/ledgers/<YYYY-MM-DD>-ripple-autonomous-ledger.md`. The upstream Build session (codebase pipeline) or upstream `Audit → Plan` flow (governance pipeline) resumes without halt. PRD / arch-spec edits stay dual-gated; master-plan edits + root CLAUDE.md / docs/workflow/CLAUDE.md / governance fence edits stay pre-merge-gated (except the §10.8 mechanical doc-sync class below, which reaches master-plan-layer files only).

### Mechanical doc-sync class (WORKFLOW.md §10.8 mirror)

This subsection is **fence-pinned by `tests/test_arch_idc_ripple.py::test_mechanical_doc_sync_class_pinned`** (operator-approved 2026-06-10, retrospective on Build run `autowave-20260609-202157`). **Do NOT paraphrase.** Canonical declaration: `WORKFLOW.md §10.8 Mechanical doc-sync class`.

A change order whose EVERY item falls inside the closed-form list below, with zero semantic delta, may take `MINOR_AUTONOMOUS` even when the highest affected layer is a master-plan-layer file (master implementation plan, subphase plan, or pillar plan).
PRD and arch-spec scope stay gated — never eligible for this class.

Closed-form list (exactly these three shapes):

1. Verb-tense status flips — where the referenced work has verifiably landed (e.g. "will add" → "added" after the PR merged).
2. Cross-reference repointing — where the target anchor exists at the new location.
3. Enumeration-count corrections — matching a mechanical count of the enumerated items.

Safety rails — ALL required for the class to apply:

- Per-item before/after quotes in the change order.
- Architectural-fitness fences green at land time.
- No operator-todo BLOCKING delta.
- The autonomous ledger line is tagged `class: doc-sync`.

Any item outside the closed-form list, or any rail unmet, disqualifies the WHOLE change order from this class — the verdict falls back to `GATED` (or `MAJOR_GATED` for PRD / arch-spec scope).

### Ledger location and format (verbatim)

One file per day, rolling, append-only:

```text
docs/workflow/ledgers/<YYYY-MM-DD>-ripple-autonomous-ledger.md
```

Each autonomous Ripple merge appends a single line in this exact format:

```text
<HH:MM> <change-order-slug> | <pipeline:governance|codebase> | <highest-layer> | <pr-num> | <merge-sha>
```

The ledger entry is written as part of the merge step (immediately after `gh pr merge` reports success and before §A6 handoff), so a successful autonomous merge that fails to append the ledger line is a regression — the merge step is not complete until the ledger entry exists.

### 4-value verdict computation (closed-form predicate)

Compute in this order:

1. **NO_RIPPLE check.** If `proposed_edit_paths[]` is empty AND `edit_summary` describes a false-positive trigger (e.g. canonical doc and repo reality already agree, or RS-1's drift evidence resolves to "no contradiction") → `verdict: NO_RIPPLE`. Skip downstream-sync map (empty list).

2. **MAJOR_GATED check.** If `highest_affected_layer ∈ {prd, architecture-spec}` (per layer enum) → `verdict: MAJOR_GATED`. PRD and arch-spec are dual-gated regardless of the four-condition outcome.

3. **MINOR_AUTONOMOUS four-condition gate** (per §"MINOR_AUTONOMOUS path — four-condition gate" verbatim above). Each condition evaluates against the input packet:
   - **Condition 1** ↔ `highest_affected_layer ∈ {subphase, pillar}` (codebase) OR `highest_affected_layer ∈ {agent-file, skill-file}` (governance).
   - **Condition 2** ↔ `citation_fields.master_plan_section` (codebase) OR `citation_fields.affected_role_skill_authority` (governance) is present AND value matches `<not touched>` or `<no semantic change to §X.Y>`.
   - **Condition 3** ↔ `arch_fitness_state.any_fence_triggered == false`.
   - **Condition 4** ↔ `blocking_todo_delta.blocking_added == 0` AND `blocking_todo_delta.blocking_removed == 0`.
   - All four → `verdict: MINOR_AUTONOMOUS`. Set `ledger_destination` to `docs/workflow/ledgers/<YYYY-MM-DD>-ripple-autonomous-ledger.md`.

3.5. **Mechanical doc-sync class check** (per §"Mechanical doc-sync class (WORKFLOW.md §10.8 mirror)" above; evaluated only when step 3 failed on Condition 1 with `highest_affected_layer ∈ {master-plan, subphase, pillar}`): if EVERY change-order item falls inside the closed-form list (verb-tense status flip / cross-reference repoint / enumeration-count correction) with zero semantic delta AND all four safety rails hold → `verdict: MINOR_AUTONOMOUS` with the ledger line tagged `class: doc-sync`. PRD / arch-spec scope never reaches this check (step 2 already returned `MAJOR_GATED`).

4. **GATED fallback.** Anything else (master plan / subphase / pillar / root CLAUDE.md / `docs/workflow/CLAUDE.md` / governance fence / agent-file / skill-file scope where the four-condition gate failed) → `verdict: GATED`.

The closed-form predicate is byte-compatible across runtimes; both Claude-side and Codex-side invocations of this skill produce identical verdicts for identical input packets.

### Verdict-to-approvals mapping

The skill returns `operator_approvals_required[]` for the caller's convenience. Mapping:

| Verdict | `operator_approvals_required[]` |
|---------|----------------------------------|
| `NO_RIPPLE` | `[]` (no PR opens) |
| `MINOR_AUTONOMOUS` | `[]` (autonomous-merge path) |
| `GATED` | `["pre-merge"]` |
| `MAJOR_GATED` | `["pre-drafting", "pre-merge"]` |

The caller then passes this list (or `verdict` directly as `ripple_verdict`) to CS-5 `canonical-gate-enforcement` for `boundary_language` + `mode_specific_banlist[]` emit at the operator-gate boundary.

### Downstream-sync map computation (collapsed `downstream-sync-mapper`)

Per Q-rip-2, the Codex sibling's separate `downstream-sync-mapper` subagent COLLAPSES into this skill's `downstream_sync_map` return field. The mapping walks the canonical-chain ladder downstream from `highest_affected_layer`:

```
PRD → master architectural spec → master implementation plan → subphase plan → pillar plan → matrix YAML → TRACKER → governance fence → CLAUDE.md tree → source code
```

For each layer **strictly below** `highest_affected_layer` per the ladder, emit a `downstream_sync_map` row:

- `layer` — the layer's enum value.
- `sync_required` — `true` if the proposed canonical edit at the highest layer implies a coordinated edit at this layer (per `${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md §Required analysis` rule 4: "Downstream docs to synchronize in the same PR — every layer below the highest affected layer that must be touched in the same PR"). `false` only when the layer is genuinely unaffected by the upstream change (e.g. a master-plan §Phase split that does not change phase scope leaves subphase plans untouched).
- `sections_affected` — list of section anchors (e.g. `master-implementation-plan.md §Phase 7d.2`) or file paths (e.g. `docs/plans/subphases/agentic-chat-phase-7d-subphase-2-plan.md`).
- `one_line_change` — verbatim description of the coordinated edit needed.

**Anti-pattern**: deferring downstream sync to a follow-up PR is forbidden per `${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md §Anti-patterns`. Same-PR ripple is required (chain-ordered commits acceptable; deferral is non-compliant).

For governance pipeline (`pipeline: governance`), the ladder is:

```
agent-file body / skill-file body → governance-fence → root CLAUDE.md → subdir CLAUDE.md (per root §Domain Index) → AGENTS.md → governance directories under docs/workflow/
```

Layer ordering per `docs/workflow/canonical-chain.md §Pipeline classification` (governance pipeline section). The tree-audit sub-procedure (sub-procedure 2) pre-computes the CLAUDE.md tree drift findings; this sub-procedure consumes those findings from the same skill invocation to enrich `sections_affected` for `root-claude-md` / `subdir-claude-md` rows.

## Procedure (full call, default flags)

1. Run sub-procedure 1 (Pipeline classification) — compute `pipeline`, `highest_affected_layer`, `arch_fitness_obligations[]`, binary verdict.
2. If `binary_verdict_only: true` → return after step 1 with the binary-verdict shape.
3. If any path in `proposed_edit_paths[]` touches a CLAUDE.md surface OR `tree_audit_only: true` → run sub-procedure 2 (CLAUDE.md tree audit) — populate `governance_verdict`, `claude_md_tree_drift_findings[]`, `scope_classification_violations[]`, `required_pre_drafting_gates[]`, `required_pre_merge_gates[]`, `report_path`.
4. If `tree_audit_only: true` → return after step 3 with the tree-audit shape.
5. Run sub-procedure 3 (4-value Ripple verdict + downstream-sync map) — populate `verdict ∈ {NO_RIPPLE, MINOR_AUTONOMOUS, GATED, MAJOR_GATED}`, `downstream_sync_map`, `operator_approvals_required[]`, `ledger_destination?`.
6. Compose the consolidated rationale (one paragraph: surface match + verdict reasoning + four-condition outcome if MINOR_AUTONOMOUS + tree-audit findings if any).
7. Return the full consolidated tuple.

## Single-process confirmation

This skill is single-input → single-output: one packet in, one packet out, with exactly one optional file written (the tree-audit drift report when CLAUDE.md surfaces are touched and `output_path` is set). No multi-step orchestration, no spawning of teammates / Task subagents, no state across invocations. Each call is independent. Multi-step gating (compute verdict → if MAJOR_GATED, surface pre-drafting gate → if MINOR_AUTONOMOUS, autonomous-merge → if GATED, surface pre-merge gate → if NO_RIPPLE, no PR) is the responsibility of `${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md` (or PR-1 wrapping); this skill is the consolidated closed-form-predicate single-process emit.

## Banlist

Load-bearing forbiddens:

- **Read+report-only.** This skill never edits canonical files (PRD, arch spec, master plan, subphase plans, pillar plans, TRACKER, root CLAUDE.md, subdir CLAUDE.md, AGENTS.md, agent files, skill files, governance fences, source code). The drift report at `output_path` is scratch — under the caller's per-run scratch dir, NOT a canonical path.
- **No paraphrasing the four-condition `MINOR_AUTONOMOUS` gate.** §"MINOR_AUTONOMOUS path — four-condition gate (verbatim)" is fence-pinned by `tests/test_arch_idc_ripple.py::test_minor_autonomous_path_exists` — copy-edit drift breaks the fence.
- **No paraphrasing the four scope-classification rules.** §"Scope-classification rules — VERBATIM (Q-rip-3)" carries the rules from donor — anti-redundancy invariant means the rules cannot also live in `${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md` body.
- **No silent rule-duplication acceptance.** Signature 3 (root↔subdir rule duplication) is always Major-or-higher. Do NOT downsize because "the duplicate is harmless" — the anti-redundancy invariant forbids the same rule living in two places at once regardless of harm.
- **No silent §Domain Index drift.** Signature 2 (stale §Domain Index coverage) is always Major. Adding a subdir CLAUDE.md without updating §Domain Index in the same PR is non-compliant per Rule 3.
- **No four-condition-gate evasion.** When any condition fails, return `GATED` (or `MAJOR_GATED` for PRD/arch-spec). Do NOT silently downgrade to `MINOR_AUTONOMOUS` because "the operator probably already approved" or "it's a small change."
- **Pipeline-hint override.** When `pipeline_hint` disagrees with computed pipeline, set `pipeline_hint_disagreed: true` and return the COMPUTED pipeline. Never silently honor a wrong hint.
- **No `downstream-sync-mapper` split.** Per Q-rip-2, the Codex sibling's separate subagent COLLAPSES into this skill's return field. Do NOT introduce a separate subagent or skill for downstream-sync mapping.
- **Binary verdict stays binary.** When `binary_verdict_only: true`, return only `{tracker-only, ripple-required}`. Do NOT leak the 4-value enum into a binary-mode call (other roles use binary mode and never need the full Ripple verdict).
- **No source-code authoring.** This skill never writes source / tests / TRACKER scope. Per parent role banlist.
- **No verdict softening on operator-todo BLOCKING delta.** This skill reports the tree drift; whether the proposed Ripple is `MINOR_AUTONOMOUS` or `GATED` is computed by sub-procedure 3 based on `blocking_todo_delta`. Never silently downgrade.

## Codex parity note (Q-rip-4 asymmetry — declared verbatim)

Loaded via the Skill tool by `${CLAUDE_PLUGIN_ROOT}/skills/codex-idc-ripple/SKILL.md` after the Codex parent reaches `canonical-impact-analyst` step. Per Q-rip-2, the Codex sibling's separate `downstream-sync-mapper` subagent is removed; the Codex parent invokes this single classifier and consumes `downstream_sync_map` as a return field. The four scope-classification rules + the four tree-drift signatures are byte-compatible across runtimes.

**Q-rip-4 asymmetry — declared verbatim:** The `MINOR_AUTONOMOUS` four-condition gate logic this skill carries IS portable to Codex, but the **autonomous-merge step itself** (post-verdict) is NOT supported on the Codex side in v2. The Claude-Teams-only worktree-merge single-shot pattern (`cd "$MAIN" && gh pr merge "$PR_NUM" --squash --delete-branch && ...` per `docs/workflow/CLAUDE.md §Worktree merge — single-shot pattern`) relies on `TeamDelete` semantics that the Codex runtime lacks. Therefore: when `verdict: MINOR_AUTONOMOUS` returns to a Codex-parent invocation, the Codex parent MUST surface the verdict + ledger-destination to the operator and stop, rather than auto-merging. The four-condition gate result is byte-compatible across runtimes; only the merge-execution step is asymmetric. Future enhancement deferred.

Per `appendices/codex-drift-ripple.md`, every Codex adapter skill currently lacks this surface-classification check; adopting this skill is the largest cross-codex parity uplift (every Codex adapter skill needs a pre-edit gate). The Codex parent invokes the skill identically — same input packet, same response shape — so the verdict is byte-compatible across runtimes.

## See also

- CS-5 `canonical-gate-enforcement` (now `idc:idc-skill-planning-substrate` mode=`enforce-gate` per Phase 2D PR-6) — companion gate-enforcement skill; this skill's `verdict` feeds the gate skill's `ripple_verdict` input.
- RS-1 `idc:idc-skill-drift-evidence` — upstream evidence-shape skill; PR-1 reads RS-1's drift summary before invoking this skill.
- RS-4 `idc:idc-skill-change-order-shape` — downstream consumer; RS-4 reads this skill's full response packet to populate the change-order template.
- RS-5 `correctness-review` (now `idc:idc-skill-plan-review` mode=`ripple` per Phase 2D PR-6) — Phase 3 review skill; reviewer cross-checks `Verdict:` field in change-order draft against this skill's verdict output.
- PR-1 `idc:idc-role-change-order-author` — multi-step composition workflow wrapping RS-1 + this skill + RS-4.
- the orchestrator inline (substrate: `idc:idc-skill-ripple-verdict` + `idc:idc-skill-drift-evidence`) — per-role drift-trigger roleplayer that may consume this skill for a recommended-verdict hint.
- the orchestrator inline (substrate: `idc:idc-skill-canonical-admission-audit`) mode=`ripple` — cross-IDC admission auditor invokes this skill in Phase 4.
- `${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md` — parent orchestrator; cites this skill rather than restating the verdict logic or the tree-audit rules.
- `docs/workflow/plans/workflow-changes/2026-05-01-idc-alignment-remediation-plan.md §R1` — source plan for the four-condition gate.
- `docs/workflow/canonical-chain.md §Pipeline classification` — the surface-based rule's canonical home in the host repo.
- `docs/workflow/CLAUDE.md §Pipeline classification` — operator-canonical articulation.
- `tests/test_arch_idc_ripple.py::test_minor_autonomous_path_exists` — the fence pinning the four-condition gate verbatim.
- `tests/test_arch_governance_pipeline.py` — fence pinning the `Pipeline:` field in change orders.
- root `CLAUDE.md §Domain Index` — authoritative inventory of subdir CLAUDE.md files.
- `tests/test_arch_idc_workflow.py` — fences the "CLAUDE.md tree impact" declaration requirement on every Ripple change order.
