# Engineer authority-boundary injects (shared between ES-1 + ES-8)

This reference file contains the verbatim authority-boundary language that BOTH `idc:idc-skill-canonical-doc-authoring` (ES-1, drafter substrate consumed by ER-1) AND `idc:idc-skill-plan-review` (ES-8 / WD-2a, reviewer substrate) must inject into their respective outputs. Per audit Q-eng-1 (recommendation: keep ES-1 and ES-8 split; share boundary language via this file), every Engineer-authored or Engineer-reviewed canonical-doc artifact carries the same boundary contract — drafter writes it into the diff context, reviewer checks for it in the diff context.

These strings are **load-bearing** — they trace to the IDC role authority table in root `CLAUDE.md §IDC role authority` (fence-pinned by `tests/test_arch_idc_workflow.py::test_role_boundaries_are_documented`). When the upstream table changes, this reference file updates in the same Ripple PR.

## INJECT 1 — RFD §Phase boundary (master plan only)

> **Master-plan admission scope (RFD).** Per the Recursive Fractal Distillation principle in root `CLAUDE.md §Recursive Fractal Distillation (RFD) principle`, the master implementation plan admits §Domain + §Phase sections only. A §Phase is the *rough seed* that `idc-develop` polishes into subphase plans. This admission **does NOT** scaffold subphase subsections inside the §Phase block; **does NOT** name candidate pillars at the master-plan layer; and **stops at the §Phase boundary**. Subphase decomposition is Develop's authority; rough pillars live inline in subphase plans (Develop emits `§Rough Pillars`); polished pillar plans live under `docs/plans/pillars/` (Deconflict's authority).

## INJECT 2 — Engineer-only write surface

> **Engineer write surface.** This admission edits ONLY: `docs/prd/prd.md` (PRD), `docs/specs/master-architectural-spec.md` (master architectural spec), `docs/plans/master-implementation-plan.md` (master implementation plan §Domain/§Phase admission), `docs/workflow/audits/<YYYY-MM-DD>-<slug>-engineering-admission-audit.md` (the admission audit), and `docs/workflow/handoffs/phases/<YYYY-MM-DD-HHMM>-<tag>.md` (the handoff). Engineer **does NOT** write source code, tests, TRACKER ordering, subphase plans (`docs/plans/subphases/`), pillar plans (`docs/plans/pillars/`), root `CLAUDE.md`, per-directory `CLAUDE.md`, AGENTS.md, or `firestore.rules` / `firestore.indexes.json`. CLAUDE.md tree edits + governance fences route through Ripple. Source/test edits route through Build (Engineer flags fitness-fence obligations but does not author the test).

## INJECT 3 — Ripple obligation (downstream sync)

> **Ripple obligation.** Per `CLAUDE.md §Canonical Document Hierarchy`, every upstream canonical change MUST ripple downstream within the same PR (one commit ideal; chain-ordered commits acceptable when one would be unreviewable). PRD changes ripple to arch spec → master plan → subphase plans → pillar plans → TRACKER. Arch-spec changes ripple to master plan → subphase plans → pillar plans → TRACKER. Master-plan changes ripple to affected subphase/pillar plans → TRACKER. If the ripple touches subphase or pillar plans, file a Ripple change order via `idc:idc-ripple` for the downstream sync — do NOT write subphase/pillar plans from Engineer. Drafter MUST emit a `ripple-targets-{prd,spec,master}.md` side-file enumerating every implicated downstream doc; reviewer MUST verify that side-file exists and that every implicated downstream doc is named (or the diff explicitly declares `no higher-layer implication`).

## INJECT 4 — Architectural-fitness fences

> **Architectural-fitness fence obligation.** Per root `CLAUDE.md §Architectural Fitness`, when a PR edits a load-bearing root-CLAUDE.md or subdir-CLAUDE.md directive OR adds a new auth surface / Cloud Run image / per-corpus embed pipeline / observability surface, add or update a `tests/test_arch_*.py` in the same commit. Reviewer-enforced; no pre-commit hook. Drafter emits a `fitness-fences-{prd,spec,master}.md` side-file naming every fence the diff would trigger. Reviewer verifies the side-file exists and that every triggered fence is either added/updated in the diff (Build's authority for the actual test code; Engineer flags the obligation) OR explicitly declared `no fence trigger` with rationale.

## INJECT 5 — Engineer Gate (operator approval)

> **Engineer Gate.** PRD and master-architectural-spec edits require operator approval BEFORE drafting AND BEFORE merge. Master implementation plan edits require operator approval BEFORE merge. The drafter's run begins only after the parent orchestrator has invoked CS-5 `idc:idc-skill-planning-substrate` with `gate_mode=engineer, action=drafting` and captured pre-drafting approval (when applicable). The pre-merge gate fires after Phase 3 review clears; merge does not proceed until the operator approves the admission PR explicitly. **No silent escalation suppression** — when the gate predicate says ESCALATE, the orchestrator surfaces; the drafter never quietly proceeds without confirmation.

## INJECT 6 — No-interview discipline (operator-leads)

> **No-interview discipline.** The drafter does NOT interview the operator about content or scope decisions during admission drafting. Every load-bearing decision flows from the supplied evidence (CR-1 codebase-context-curator packet + CR-11 considerations-triage cohort + CR-10 canonical-admission-auditor verdict + the considerations files cited as Ready). If evidence is silent on a load-bearing decision, halt with `BLOCKED: blocker: evidence_silent_on_load_bearing_decision` and surface to the parent orchestrator — do NOT phrase as a question to ask the operator from inside the draft. Adapted from `mattpocock/to-prd` no-interview pattern; reinforces the operator-leads invariant (the Engineer mirror of the same Think-captures-not-recommends invariant).

## INJECT 7 — Authority-table cross-reference

> **Source authority.** This admission is written under the Engineer authority surface defined verbatim in root `CLAUDE.md §IDC role authority` (fence-pinned by `tests/test_arch_idc_workflow.py::test_role_boundaries_are_documented`). Boundary language above is sourced from that table; if any line in INJECTs 1–6 disagrees with the table, the table is canonical and a Ripple change order updates this reference file in the same PR.

## How to inject

- **ES-1 drafter** (initial mode): inject INJECTs 1–7 verbatim into `<scratch_dir>/draft-disposition-log.md` §"Operator gates exercised" + §"Authority boundaries" subsections, AND into the admission-PR body via the parent's PR composition step.
- **ES-1 drafter** (fix-loop mode): inject INJECTs 1–7 as comments at the top of `<scratch_dir>/draft-{doc}-vN.md` if not already present from v(N-1); preserve byte-for-byte from prior version otherwise.
- **ES-8 reviewer** (custom-admission-reviewer): probe each injection in the dimension table (RFD §Phase boundary → INJECT 1; Authority boundaries → INJECT 2 & 7; Ripple targets → INJECT 3; Fitness fences → INJECT 4; Engineer Gate → INJECT 5; No-interview discipline → INJECT 6). Missing or paraphrased injection language at confidence ≥ 80 fires Major.
- **ES-2 admission audit** + the **`mode: audit-write`** emit (formerly ES-4 / `idc-skill-engineering-admission-audit-write`; folded inline per Phase 2D PR-7) — both modes of `idc:idc-skill-canonical-admission-audit`: cross-reference these injects when emitting the binding obligations table; the table's "Source rule" column cites this file by absolute path. <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->

## Versioning

This reference file is referenced by absolute path from ES-1, ES-8, ES-2, and the `mode: audit-write` emit (formerly ES-4; folded inline per Phase 2D PR-7). When the IDC role authority table updates, file a Ripple change order that updates this reference file + every callsite in the same PR (CLAUDE.md tree impact: typically `none`, since the reference file is cross-cutting governance not a per-directory rule).
