---
name: idc-skill-canonical-admission-audit
description: 'Use when IDC Engineer admission needs a verdict on canonical-chain compliance before document or implementation work proceeds.'
---
# IDC Skill — Canonical Admission Audit (`idc:idc-skill-canonical-admission-audit`)

CUSTOM. Engineer's binding governance audit — consolidated. The skill walks the canonical chain, classifies the proposed admission, builds the binding obligations table, and inventories every architectural-fitness fence the admission would trigger (`mode: verdict`); runs the 7-anti-pattern lint pass against the Engineer's emitted scratch drafts or the open-PR diff (`mode: anti-pattern-lint`); and emits the durable role-specific admission-audit artifact (`mode: audit-write`). The 4-value verdict plus obligations table plus fence inventory comprise the operator-facing evidence the parent orchestrator surfaces at the Engineer-Gate pre-drafting prompt. The lint pass gates ER-1's Phase 5 stand-down. The audit emit lands BEFORE the admission PR opens (separate commit on the admission branch) so the audit is part of the PR diff.

This skill is the consolidated entry point for what was previously three separate Engineer-admission skills:
- ES-2 `idc:idc-skill-canonical-admission-audit` (verdict packet — original target file)
- ES-5 `idc-skill-engineer-anti-pattern-check` (7-anti-pattern lint pass — folded into `mode: anti-pattern-lint`) <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->
- ES-4 `idc-skill-engineering-admission-audit-write` (role-specific audit emit — folded into `mode: audit-write`) <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->

Every load-bearing rule from the three source skills is preserved verbatim under the per-mode sections below.

## When to invoke

- **`mode: verdict`** — inside the orchestrator inline (substrate: `idc:idc-skill-canonical-admission-audit`) Phase 4 when `mode: engineer`. Also callable from the Engineer parent orchestrator's Phase 1 governance-auditor step if CR-10 is not in use. Single-process — one verdict packet per admission run.
- **`mode: anti-pattern-lint`** — inside ER-1 the orchestrator inline (substrate: `idc:idc-skill-canonical-doc-authoring`) Phase 5 with `lint_mode: pre-pr-scratch` against scratch drafts (mandatory before SendMessage telegram). Also inside the Engineer parent orchestrator's pre-merge step with `lint_mode: pre-merge` against the admission-PR diff (gh pr diff captured to scratch).
- **`mode: audit-write`** — inside the Engineer parent orchestrator's Phase 3 step, after Phase 3 review clears AND before Phase 4 PR opens. Single-process — one audit per admission run.

## Top-level input shape

Every call carries:

- `mode` — exactly one of `verdict | anti-pattern-lint | audit-write`.
- Plus the per-mode sub-packet documented under each mode's section below.

The skill validates `mode` first, then routes to the per-mode procedure below. There is no cross-mode bleed — each mode's input/output contract is self-contained.

---

## Mode A — `verdict`

### Input shape

Caller passes a single packet with:

- `codebase_context_packet_path` — absolute path to CR-1's emitted packet (`<scratch_dir>/codebase-context-packet.md`).
- `considerations_paths[]` — list of considerations files cited as Ready by CR-11's cohort.
- `proposed_edit_paths[]` — list of canonical-doc paths the admission targets (subset of `{docs/prd/prd.md, docs/specs/master-architectural-spec.md, docs/plans/master-implementation-plan.md}`).
- `canonical_hierarchy_anchors` — map naming the specific anchors per target doc (PRD section, arch-spec section, master-plan §Domain/§Phase IDs).
- `arch_fitness_inventory_path` — absolute path to the inventory of `tests/test_arch_*.py` fences. Caller composes from `tests/CLAUDE.md §Fence inventory` (or equivalent).
- `output_path` — absolute scratch path for the verdict packet (defaults to `<scratch_dir>/admission-audit-engineer.md`).

### Output shape

Single verdict packet written to disk plus a small return packet:

- **File** at `output_path`. YAML frontmatter + structured body (see "Verdict packet shape" below).
- **Return packet:** `{verdict, obligations_count, fence_triggers_count, ripple_required, operator_approvals_required[]}`.

### Verdict packet shape

```yaml
---
audit_kind: canonical-admission-audit
role: engineer
verdict: COMPLIANT | CONDITIONAL | BLOCKED | TOP_LEVEL_REPLAN_REQUIRED
pipeline: codebase | governance
highest_affected_layer: prd | architecture-spec | master-plan | subphase | pillar | matrix | tracker | governance-fence | claude-md-tree | source
ripple_required: true | false
considerations_admitted_count: <N>
obligations_count: <N>
fence_triggers_count: <N>
operator_approvals_required: [<list>]
---

# Canonical admission audit — engineer role — <slug>

## 1. Verdict + rationale

(One paragraph naming verdict, highest-affected layer, and rationale.)

## 2. Binding obligations table

| # | Obligation | Source rule | Required plan section | Required execution action | Blocking? |
|---|------------|-------------|----------------------|---------------------------|-----------|
| 1 | <e.g. "Include §Fitness fences declaration"> | <e.g. "root CLAUDE.md §Architectural Fitness"> | <e.g. "PR body §Architectural-fitness obligations"> | <e.g. "Engineer flags; Build authors fence in same PR cycle"> | yes/no |
| ... |

## 3. Architectural-fitness fence-trigger inventory

| Fence | Reason it triggers | New or Updated | Surface anchor (file:line) |
|-------|---------------------|----------------|----------------------------|
| `tests/test_arch_<name>.py::<test>` | <one-line reason> | new \| updated | <file:line> |
| ... |

## 4. Trace-back evidence (per layer)

(Per layer in the canonical chain that the proposed edits touch: cite the upstream-change OR the explicit "no higher-layer implication" declaration. Verbatim quotes from canonical anchors.)

## 5. Recommended next action

(One paragraph: what the parent should do based on the verdict — proceed to drafting, escalate to Ripple, route to Think for re-scoping, etc.)

## 6. Operator approvals required (Engineer Gate)

- <list with one-line rationale per approval>
```

### Procedure

1. **Read** all inputs end-to-end: CR-1's packet, every considerations file in `considerations_paths[]`, every doc named in `proposed_edit_paths[]`, the arch-fitness inventory, root `CLAUDE.md §Canonical Document Hierarchy` + `§IDC role authority` + `§Architectural Fitness`.
2. **Classify pipeline:** apply the surface-based classification rule from `docs/workflow/canonical-chain.md §Pipeline classification`. Engineer admissions are typically `codebase` (PRD / arch-spec / master-plan are codebase pipeline targets); admissions whose admitted scope is governance-only (purely `${CLAUDE_PLUGIN_ROOT}/agents/`, root CLAUDE.md, or `docs/workflow/`) classify as `governance` and route through Ripple, not Engineer.
3. **Determine highest affected layer:** walk PRD → arch-spec → master-plan → subphase → pillar → matrix → TRACKER → governance-fence → claude-md-tree → source ladder. The highest layer named in `proposed_edit_paths[]` (or implied by the considerations content) is the answer.
4. **Compute the verdict:**
   - `COMPLIANT` — proposed admission is fully traceable, governance obligations are addressable in the same PR, no upstream contradiction detected, considerations are Ready cohort.
   - `CONDITIONAL` — proceedable IF specific obligations are met (operator-deferred Minor/Nit findings file as side-jobs; missing-but-recoverable trace declarations are in-scope for the drafter).
   - `BLOCKED` — at least one Blocker-class obligation cannot be met inside this admission run (e.g. an admitted consideration contradicts current PRD; a fitness fence would need to be authored by Build before the admission can proceed). Surface the operator decision required.
   - `TOP_LEVEL_REPLAN_REQUIRED` — the admission would require editing a layer above PRD (no such layer exists in this hierarchy), OR the admission proves the canonical hierarchy itself needs revision. Routes the operator to file Ripple or run a pre-canonical Think pass.
5. **Build the binding obligations table:** for each governance rule that applies (CLAUDE.md tree obligations, Ripple obligations, fitness-fence obligations, operator-gate obligations, considerations-citation obligations), emit one row. Every row names its source rule (verbatim quote from a canonical anchor), the plan section it must land in, the execution action required, and the blocking flag.
6. **Inventory fitness fences:** for each `tests/test_arch_*.py` triggered by the proposed admission per `tests/CLAUDE.md §Fence-add policy`, emit one row in §3. Include "no fence trigger" with rationale when the admission is purely additive prose with no new auth surface / Cloud Run image / per-corpus embed pipeline / observability surface.
7. **Compute trace-back evidence:** for every layer the admission touches, cite the upstream-change anchor OR the explicit "no higher-layer implication" declaration the drafter must include.
8. **Compute operator approvals required:** Engineer Gate is dual-gated for PRD/arch-spec (pre-drafting AND pre-merge); single-gated for master-plan (pre-merge only). Append CS-5's gate-mode obligations.
9. **Write the verdict packet** at `output_path` per the shape above.
10. **Return** the small return packet.

### Banlist (verdict mode)

Load-bearing forbiddens:

- **No edits to canonical docs.** Read-only audit.
- **No mode crossover.** Verdict mode is Engineer-mode only. Build's pre-merge mode lives in CR-10's Build branch (no sibling skill — implemented inline). Ripple's 4-value verdict lives in `idc:idc-skill-ripple-verdict`.
- **No verdict downsizing to escape a halt.** When evidence supports `BLOCKED`, never emit `CONDITIONAL`. When evidence supports `TOP_LEVEL_REPLAN_REQUIRED`, never emit `BLOCKED`.
- **No skipping the fence inventory.** Even when the verdict is `COMPLIANT` and no fence triggers, the §3 table renders explicitly with the "no fence trigger" rationale. Future drift becomes detectable.
- **No skipping the trace-back evidence.** Every layer the admission touches gets a §4 entry — empty entries are not allowed. If a layer has no implication, that's stated explicitly with rationale.
- **No silent ripple flag.** When `ripple_required: true`, the §5 recommended next action explicitly names "file Ripple change order via `idc:idc-ripple` for downstream sync" and the parent surfaces it.
- **No considerations re-litigation.** Considerations admitted by CR-11's Ready cohort are accepted as-is at this skill; this skill never re-classifies considerations. If the admission would need to demote an admitted consideration to Reject-out-of-scope, halt with `BLOCKED — considerations gate disagreement` and route back through CR-11.

---

## Mode B — `anti-pattern-lint`

Engineer-specific lint pass. Inspects emitted scratch drafts + the orchestrator's scratch state for the 7 anti-patterns Engineer's banlist enumerates (per `${CLAUDE_PLUGIN_ROOT}/agents/idc-plan.md §Anti-patterns` and root `CLAUDE.md §IDC role authority`). The `lint_mode` parameter selects the inspection surface — `pre-pr-scratch` (called from inside ER-1 step 5 against scratch drafts) or `pre-merge` (called from the parent orchestrator before merge against the open PR's diff). Generalize-able: future IDC roles wanting the same lint pass adopt this skill (or a renamed cross-IDC variant if the partition rule promotes it).

### Input shape

Caller passes a single packet with:

- `draft_paths[]` — list of scratch draft paths (`pre-pr-scratch` lint_mode) OR list of PR-diff paths (`pre-merge` lint_mode).
- `scratch_dir` — absolute path to the calling roleplayer's scratch dir (used for inspecting orchestrator scratch state for anti-patterns b, c, d, g).
- `lint_mode` — exactly one of `pre-pr-scratch | pre-merge`.
- `output_path` — absolute path for the lint report (defaults to `<scratch_dir>/anti-pattern-check.md`).

### Output shape

Single lint report written to disk plus a small return packet:

- **File** at `output_path` — structured lint report.
- **Return packet:** `{verdict, anti_pattern_findings_count, findings_by_severity, fail_anti_patterns[]}`.

### Lint report shape

```yaml
---
lint_kind: engineer-anti-pattern-check
lint_mode: pre-pr-scratch | pre-merge
verdict: PASS | FAIL
draft_paths_count: <N>
findings_total: <N>
fail_anti_patterns: [<list of letters that fired FAIL>]
---

# Engineer anti-pattern check — <verdict>

## 1. Per-anti-pattern verdicts

| # | Anti-pattern | Surface | Verdict | Findings |
|---|--------------|---------|---------|----------|
| a | `handoffs/` vs `hand-offs/` path spelling | git-diff-checkable | PASS \| FAIL | <count + first 3 anchors> |
| b | Task-subagent dispatch language | scratch-state-checkable | PASS \| FAIL | <count + first 3 anchors> |
| c | Intermediate "lead" reference | scratch-state-checkable | PASS \| FAIL | <count + first 3 anchors> |
| d | Inline brief > 30 lines in TeamCreate prompt | scratch-state-checkable | PASS \| FAIL | <count + first 3 anchors> |
| e | Subphase or pillar plan edits in diff | git-diff-checkable | PASS \| FAIL | <count + first 3 anchors> |
| f | Source / test edits in diff | git-diff-checkable | PASS \| FAIL | <count + first 3 anchors> |
| g | Missing audit artifact reference | scratch-state-checkable | PASS \| FAIL | <count + first 3 anchors> |

## 2. Findings detail

(For each FAIL anti-pattern, list every finding with `<file>:<line>` anchor + verbatim quote + remediation hint.)

## 3. Recommended remediation

(One paragraph naming which anti-patterns to fix and the recommended next step — typically: "fix and re-invoke this skill" for FAIL verdicts; "ER-1 stand-down clear" for PASS.)
```

### Procedure

1. **Validate inputs:** every `draft_paths[]` entry exists and is readable; `scratch_dir` exists; `lint_mode` ∈ allowed enum.
2. **Run anti-pattern (a) — `handoffs/` vs `hand-offs/` path spelling:**
   - Diff-checkable. `grep -nE 'hand-offs?/' <draft_paths>` and similar. Any match = FAIL with the anchor list.
   - The only permitted spelling is `handoffs/` (no hyphen). Per `${CLAUDE_PLUGIN_ROOT}/agents/idc-plan.md §Anti-patterns` (the Engineer role was collapsed into Plan per Phase 2 PR-4) and root `CLAUDE.md`.
3. **Run anti-pattern (b) — Task-subagent dispatch language:**
   - Scratch-state-checkable. `grep -nE 'subagent_type:|Agent\(.*subagent_type' <scratch_dir>` for any reference inside a draft suggesting Task-subagent dispatch of an IDC role orchestrator.
   - Specifically forbidden: text suggesting Engineer's workflow could run as a Task subagent. The orchestrator IS a parent session.
4. **Run anti-pattern (c) — Intermediate "lead" reference:**
   - Scratch-state-checkable. `grep -niE 'team-lead|coordinator|meta-orchestrator' <scratch_dir>` for any reference suggesting an intermediate lead between orchestrator and writer.
   - Operator-is-lead invariant. Only the parent orchestrator spawns teammates.
5. **Run anti-pattern (d) — Inline brief > 30 lines in TeamCreate prompt:**
   - Scratch-state-checkable. Inspect any `TeamCreate(...)` or `Agent(...)` literal in scratch drafts; if the `prompt` argument body exceeds 30 lines, FAIL. CS-3 `idc:idc-skill-planning-substrate` enforces brief-on-disk discipline.
6. **Run anti-pattern (e) — Subphase or pillar plan edits in diff:**
   - Diff-checkable. `grep -lE '^\+\+\+ .*docs/plans/(subphases|pillars)/' <draft_paths>`. Any match = FAIL.
   - Engineer authority stops at master plan; subphase/pillar plan edits route through Develop / Deconflict respectively.
7. **Run anti-pattern (f) — Source / test edits in diff:**
   - Diff-checkable. `grep -lE '^\+\+\+ .*(<source-dir>/|tests/|scripts/)' <draft_paths>` — substitute the governed repo's source dirs (per `WORKFLOW-config.yaml`, e.g. `services/|web/`). Any match = FAIL.
   - Engineer flags fitness-fence obligations but never authors the test code; source code edits are entirely Build's authority.
8. **Run anti-pattern (g) — Missing audit artifact reference:**
   - Scratch-state-checkable. Verify the orchestrator's scratch state references the engineering-admission-audit (`docs/workflow/audits/<YYYY-MM-DD>-<slug>-engineering-admission-audit.md`) AND the role-run-audit (`docs/workflow/audits/<YYYY-MM-DD-HHMM>-engineer-run-audit.md`). At least one expected audit pointer should exist either in `scratch_dir/run-ledger.md` or in the draft's §9 Cross-references section.
   - `pre-pr-scratch` lint_mode is permissive on (g) since the audits land BEFORE PR open and may not have been written yet at lint time. The skill issues PASS for (g) in `pre-pr-scratch` mode IF the run-ledger references the planned audit paths. `pre-merge` mode is strict — PR diff must reference the engineering-admission-audit verbatim.
9. **Compute the overall verdict:**
   - `PASS` — all 7 anti-pattern checks return PASS.
   - `FAIL` — at least one anti-pattern returns FAIL.
10. **Render the lint report** at `output_path` per the shape above.
11. **Return** the small return packet.

### Banlist (anti-pattern-lint mode)

Load-bearing forbiddens — for the lint pass itself:

- **No edits to scratch drafts.** Read-only lint pass; the caller (ER-1 or the parent orchestrator) decides whether to fix.
- **No auto-fix.** This mode detects + reports; remediation is the caller's responsibility. Auto-fix would re-author scope which is out of scope for a lint pass.
- **No verdict downsizing.** When evidence supports FAIL, never emit PASS to "smooth the workflow." A FAIL verdict halts the calling roleplayer; that's the contract.
- **No silent severity.** Every FAIL anti-pattern surfaces by letter (a..g) so the caller's remediation can target.
- **No mode crossover.** `pre-pr-scratch` and `pre-merge` have different surfaces (scratch drafts vs PR diff) and different (g) tolerance.
- **No skipping anti-patterns.** All 7 always execute even if early ones fail.

### Generalization path

This lint surface is generalize-able cross-IDC if other roles want the same pass. Future cross-IDC promotion would parameterize the per-role banlist (Engineer's 7 anti-patterns become a `lint_persona: engineer` partition; Develop / Deconflict / Sequence / Build / Ripple modes layer their own per-role anti-patterns). Until promoted, this mode stays Engineer-mode and Engineer-specific.

---

## Mode C — `audit-write`

Engineer's role-specific admission audit emit. Writes `docs/workflow/audits/<YYYY-MM-DD>-<slug>-engineering-admission-audit.md` with full canonical-doc diffs verbatim + reviewer findings + dispositions + ripple-stub list + operator gates exercised. Lands BEFORE the admission PR opens (separate commit on the admission branch) so the audit is part of the PR diff. Distinct from cross-IDC `idc-skill-run-audit` — Engineer drops BOTH (this role-specific audit AND the uniform run-audit per-run). Per audit Q-cross-1, the role-specific audit ships first; the uniform run-audit is added by ER-1's closeout flow at run-end. <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->

### Input shape

Caller passes a single packet with:

- `slug` — kebab-case slug for the admission (e.g. `compile-pipeline-source-dedupe-2026-05-07`).
- `run_id` — `<YYYY-MM-DD-HHMM-tag>`; matches the run-ledger and the eventual run-audit's `run_id`.
- `scratch_dir` — absolute path to the run's scratch dir (`/tmp/idc-plan/<run-id>/`; the path was `/tmp/idc-engineer/<run_id>/` before the PR-4 Engineer→Plan collapse).
- `output_path` — absolute path under `<repo_root>/docs/workflow/audits/<YYYY-MM-DD>-<slug>-engineering-admission-audit.md`.
- `drafts_paths[]` — list of final scratch draft paths (e.g. `<scratch_dir>/draft-prd.md`, `<scratch_dir>/draft-spec.md`, `<scratch_dir>/draft-master.md`). The skill embeds each as a verbatim diff section.
- `ripple_targets_paths[]` — list of ER-1's emitted ripple-targets side-files (one per target_doc).
- `fitness_fences_paths[]` — list of ER-1's emitted fitness-fences side-files.
- `wd_1_review_path` — absolute path to WD-1's adversarial-review report.
- `ws_8_review_path` — absolute path to ES-8 / WD-2a's canonical-doc-review report.
- `fixer_dispositions[]` — per-loop fixer outcome rows: `{loop_index, blocker_count_in, major_count_in, blocker_count_out, major_count_out, draft_path_out}`.
- `ripple_stubs[]` — list of ripple-target stubs filed with `idc:idc-ripple` (or "filed in same PR" / "no implication" declarations); empty list acceptable when the admission is fully self-contained.
- `operator_gates_exercised[]` — append-only list of gates: `{gate_name (e.g. pre-drafting), gate_mode (engineer), action (drafting), operator_response (approved | declined | deferred), iso_timestamp}`.
- `considerations_absorbed[]` — list of considerations file paths absorbed by this admission (from CR-11's Ready cohort).
- `verdict_packet_path` — absolute path to this skill's `mode: verdict` output (the binding obligations table — formerly known as the ES-2 verdict packet).

### Output shape

Single audit file written to disk plus a small return packet:

- **File** at `output_path` — the canonical-shape audit body.
- **Return packet:** `{audit_path, slug, lands_in_pr_branch: true, drafts_count, reviewer_findings_count, ripple_stubs_count, gates_exercised_count}`.

### File shape (verbatim contract)

```yaml
---
audit_kind: engineering-admission-audit
role: engineer
run_id: <YYYY-MM-DD-HHMM-tag>
slug: <kebab-case>
audit_date: <YYYY-MM-DD>
authored_in_branch: admission/<slug>
lands_in_pr_branch: true
considerations_absorbed_count: <N>
drafts_count: <N>
reviewer_findings_total: <Blocker_total + Major_total + Minor_total + Nit_total>
fixer_loops_run: <0..3>
ripple_stubs_count: <N>
operator_gates_exercised_count: <N>
---

# Engineering admission audit — <slug>

## 1. Run inputs

- run_id: <run-id>
- considerations absorbed:
  - <abs path 1>
  - <abs path 2>
- proposed canonical edits:
  - PRD: <yes/no — section anchors>
  - Master architectural spec: <yes/no — section anchors>
  - Master implementation plan: <yes/no — §Domain/§Phase admission targets>

## 2. Governance verdict (from `mode: verdict`)

(Embed the full body of the verdict packet at `verdict_packet_path` — verdict + obligations table + fence-trigger inventory + trace-back evidence + recommended next action + operator approvals required. Verbatim.)

## 3. Drafted diffs (verbatim)

### 3a. PRD diff
(If applicable — embed the full body of `<scratch_dir>/draft-prd.md`. Verbatim.)

### 3b. Master architectural spec diff
(If applicable — embed `<scratch_dir>/draft-spec.md`. Verbatim.)

### 3c. Master implementation plan diff
(If applicable — embed `<scratch_dir>/draft-master.md`. Verbatim.)

## 4. Reviewer findings

### 4a. Codex adversarial-review (WD-1)
(Embed the full body of `wd_1_review_path` — IDC-bucketed by Blocker/Major/Minor/Nit per Q-cross-2. Verbatim.)

### 4b. Custom admission review (ES-8 / WD-2a)
(Embed the full body of `ws_8_review_path`. Verbatim.)

## 5. Fixer dispositions (per loop)

| Loop | Blocker in | Major in | Blocker out | Major out | Draft path out |
|------|------------|----------|--------------|-----------|----------------|
| 1 | <N> | <N> | <N> | <N> | <abs path> |
| 2 | <N> | <N> | <N> | <N> | <abs path> |
| 3 | <N> | <N> | <N> | <N> | <abs path> |

(Empty rows omitted when fewer than 3 loops ran. If 3 loops ran and Blocker/Major remained, the run halted — surface here verbatim.)

## 6. Ripple-downstream obligations identified

| # | Affected layer | Affected doc | Disposition (same-PR / separate Ripple / no implication) | Ripple change-order pointer (if separate) |
|---|----------------|--------------|----------------------------------------------------------|--------------------------------------------|
| 1 | <e.g. master-plan> | `docs/plans/master-implementation-plan.md` | same-PR | n/a |
| ... |

## 7. Architectural-fitness fences flagged

(Embed the full body of every `fitness_fences_paths[]` entry. Verbatim.)

## 8. Operator gates exercised

| Gate | Mode | Action | Operator response | ISO timestamp |
|------|------|--------|--------------------|----------------|
| <e.g. Engineer Gate pre-drafting> | engineer | drafting | approved | <ISO-8601> |
| <e.g. Engineer Gate pre-merge> | engineer | pre_merge | <pending — captured at merge time> | <ISO-8601 or "pending"> |

## 9. Cross-references

- Run-audit (CS-1, separate file, drops at run close): `docs/workflow/audits/<YYYY-MM-DD-HHMM>-engineer-run-audit.md`
- Handoff (CS-2, separate file, drops at run close): `docs/workflow/handoffs/phases/<YYYY-MM-DD-HHMM>-<slug>.md`
- Run ledger: `<scratch_dir>/run-ledger.md`
- Verdict packet (`mode: verdict` output): `<verdict_packet_path>`
```

### Procedure

1. **Validate inputs:** every required path exists and is readable. The `slug` is kebab-case; `run_id` matches `<YYYY-MM-DD-HHMM-tag>` shape; `output_path` lands under `<repo_root>/docs/workflow/audits/`.
2. **Compose §1 Run inputs** — list `considerations_absorbed[]` paths verbatim; classify which canonical-doc edits are in scope based on `drafts_paths[]` (presence of `draft-prd.md` → PRD-yes, etc.).
3. **Embed §2 Governance verdict** — read `verdict_packet_path` end-to-end and embed the full body verbatim under §2.
4. **Embed §3 Drafted diffs** — for each path in `drafts_paths[]`, embed the full body verbatim under the appropriate sub-section (3a / 3b / 3c). NEVER paraphrase, summarize, or truncate the diffs.
5. **Embed §4 Reviewer findings** — read `wd_1_review_path` and `ws_8_review_path` end-to-end and embed verbatim. The IDC bucket vocabulary is `Blocker | Major | Minor | Nit` per Q-cross-2 — if WD-1 used legacy `critical | high | medium | low`, the embedded body keeps WD-1's mapping comment but the §4a heading reads "(IDC-mapped: critical→Blocker; high→Major; medium→Minor; low→Nit)".
6. **Render §5 Fixer dispositions** as the table rows — one row per loop that ran; empty rows omitted.
7. **Render §6 Ripple-downstream obligations** — read each `ripple_targets_paths[]` file and consolidate into the table; cross-reference each row to a `ripple_stubs[]` entry (filing pointer or "no implication" declaration).
8. **Embed §7 Architectural-fitness fences** — read each `fitness_fences_paths[]` file and embed verbatim.
9. **Render §8 Operator gates exercised** — one row per `operator_gates_exercised[]` entry. The pre-merge gate row may have `operator_response: pending` and `iso_timestamp: pending` at the time this audit lands (since the audit lands BEFORE PR open and merge); the parent orchestrator updates this row at merge time via a follow-up commit on the same branch.
10. **Render §9 Cross-references** — pointers only; never embed bodies of CS-1 / CS-2 (those are separate canonical files).
11. **Write** the audit to `output_path`.
12. **Return** the small return packet.

### Banlist (audit-write mode)

Load-bearing forbiddens:

- **No paraphrased diffs.** Drafts embed verbatim from `drafts_paths[]`. The audit is the durable trace artifact — paraphrase defeats the contract.
- **No paraphrased reviewer findings.** WD-1 + ES-8 reports embed verbatim under §4. If severity vocab differs from Q-cross-2 (`Blocker | Major | Minor | Nit`), the embedded body keeps the source's mapping comment but the §4 heading flags the mapping.
- **No edits to canonical docs.** This mode writes ONE file at `output_path` and nothing else. Source code, tests, TRACKER, CLAUDE.md tree, AGENTS.md untouched.
- **No skipping the §6 ripple table.** Even when the admission has no ripple implications, the §6 table renders with explicit "no implication" declarations per affected layer.
- **No skipping the §7 fence body.** Even when no fences trigger, the §7 body renders with "no fence trigger" rationale.
- **No silent gate omission.** Every operator gate the orchestrator surfaced renders as a §8 row, regardless of operator response.
- **No `hand-off` / `hand-offs/` / `handoff` typo.** The §9 cross-reference uses `handoffs/` (no hyphen) verbatim.

---

## Single-process confirmation

Single-input → single-output per call: caller hands one packet (`mode` + per-mode sub-packet), skill writes one report at the configured path and returns one return packet. There is no internal multi-step orchestration, no spawning of teammates / Task subagents, no state across invocations. Each mode is independently invocable; orchestrators that need all three call the skill three times in sequence (typically: `verdict` → adversarial review → fixer loops → `anti-pattern-lint` → `audit-write`).

## Codex parity note

Loaded via the Skill tool by `${CLAUDE_PLUGIN_ROOT}/skills/codex-idc-plan/SKILL.md` (after substrate-redirection sweep; the Codex sibling for the Engineer role was renamed `codex-idc-engineer` → `idc:codex-idc-plan` per Phase 2 PR-4) inside the codex `governance-auditor` step (`mode: verdict`), the codex `pre-pr-scratch lint` step (`mode: anti-pattern-lint`), and the codex `planning-admission-auditor` step (`mode: audit-write`) — closes Codex parity gap (idc:codex-idc-plan's existing flow has neither a governance-auditor subagent nor an anti-pattern lint pass nor an audit-shape contract). The Codex parent invokes the skill identically; the verdict packet shape, lint report shape, and audit body shape are byte-compatible across runtimes. Anti-pattern (a) `hand-offs/` is one of the codex-drift items resolved by the consolidated codex-drift Ripple sweep — running `mode: anti-pattern-lint` from inside Codex catches the regression at lint time, not at merge time. After audit-write lands, the Codex parent then invokes `idc-skill-run-audit` for the uniform run-audit drop, paralleling Claude side. <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->

## See also

- CR-10 the orchestrator inline (PR-5 fold; substrate: `idc:idc-skill-canonical-admission-audit`) — mode-parameterized roleplayer that wraps this skill (`mode: verdict` Engineer branch), `idc:idc-skill-ripple-verdict` (Ripple branch), and Build's inline pre-merge shape.
- ER-1 the orchestrator inline (PR-5 fold; substrate: `idc:idc-skill-canonical-doc-authoring`) — Phase 5 caller for `mode: anti-pattern-lint` (`pre-pr-scratch`).
- Engineer parent orchestrator pre-merge step — caller for `mode: anti-pattern-lint` (`pre-merge`).
- Engineer parent orchestrator Phase 3 step — caller for `mode: audit-write` (after Phase 3 review clears AND before Phase 4 PR opens).
- `idc:idc-skill-ripple-verdict` — companion read-only classifier; `mode: verdict` consumes its `{pipeline, verdict, highest_affected_layer, arch_fitness_obligations[]}` packet as input pre-flight.
- `idc:idc-skill-planning-substrate` — composes the `operator_approvals_required[]` list `mode: verdict` emits; anti-pattern (d) source authority for `mode: anti-pattern-lint`.
- `idc:idc-skill-canonical-doc-authoring` — drafter consumer; the obligations table from `mode: verdict` flows into the drafter's `evidence_anchor_citations[]` input. Produces the drafts `mode: anti-pattern-lint` lints and `mode: audit-write` embeds verbatim.
- `idc:idc-skill-plan-adversarial-review` — produces the §4a body embedded by `mode: audit-write`.
- `idc:idc-skill-plan-review` (mode=admission) — produces the §4b body embedded by `mode: audit-write`.
- `idc-skill-run-audit` — separate uniform run-audit; drops at run close. Distinct artifact. <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->
- `idc-skill-role-handoff` — separate handoff; drops at run close. <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->
- `idc:idc-skill-plan-patch-from-findings` — produces the §5 fixer disposition rows (one per loop) consumed by `mode: audit-write`.
- `${CLAUDE_PLUGIN_ROOT}/agents/idc-plan.md §Anti-patterns` — verbatim anti-pattern list source for `mode: anti-pattern-lint` (the Engineer role was collapsed into Plan per Phase 2 PR-4).
- root `CLAUDE.md §Canonical Document Hierarchy`, `§IDC role authority`, `§Architectural Fitness` — source authority for verdict + obligations + fences.
- `docs/workflow/canonical-chain.md §Pipeline classification` — pipeline classifier rule.
- `tests/CLAUDE.md` — fence inventory + fence-add policy source.
- `docs/workflow/CLAUDE.md §TRACKER discipline` — full diffs/audits/analyses go here, NOT inline in TRACKER.
