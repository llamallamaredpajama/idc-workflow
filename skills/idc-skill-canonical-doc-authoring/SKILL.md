---
name: idc-skill-canonical-doc-authoring
description: 'Use when an IDC role needs to draft or update canonical PRD, architecture, plan, or tracker documentation.'
---
# IDC Skill — Canonical Doc Authoring (`idc:idc-skill-canonical-doc-authoring`)

CUSTOM. Engineer's drafter substrate. The skill emits the per-target-doc diff scaffolding plus the two mandatory side-files (ripple-targets, fitness-fences) so the caller (ER-1) can compose the admission packet. Skill body enforces the authority-boundary contract verbatim from `references/authority-boundary-injects.md`; the caller (ER-1) injects the same contract into the parent orchestrator's prompt and PR body.

## When to invoke

Inside ER-1 the orchestrator inline (substrate: `idc:idc-skill-canonical-doc-authoring`) step 3 (initial mode AND fix-loop mode). Also callable from the Engineer parent orchestrator's drafter step if ER-1 is not in use (compatibility path). Single-process per target doc — the caller invokes once per `target_doc ∈ {prd, architecture-spec, master-plan}`.

## Input shape

Caller passes a single packet with:

- `target_doc` — exactly one of `prd | architecture-spec | master-plan`. Selects the canonical-path under audit (`docs/prd/prd.md` / `docs/specs/master-architectural-spec.md` / `docs/plans/master-implementation-plan.md`).
- `mode` — exactly one of `initial | fix-loop`. Selects whether the skill produces a fresh draft scaffold or applies a narrow fix-loop patch.
- `target_section_anchors[]` — list of anchors in the target doc the diff edits (H1/H2 headings, line-range tuples for in-section edits). Caller composes from CR-1's packet + CR-10's binding obligations table.
- `edit_kind_per_anchor` — map from anchor → `additive | refinement | reorganization`.
- `evidence_anchor_citations[]` — list of source citations from CR-1's packet + considerations files; one per `target_section_anchors[]` entry. Drafter prose REQUIRES every section to trace to at least one citation.
- `boundary_language_path` — absolute path to `references/authority-boundary-injects.md` (this skill's companion). The skill reads the file and renders the 7 INJECT blocks into the disposition log + the diff context.
- `output_path` — absolute scratch path for the emitted diff. In initial mode: `<scratch_dir>/draft-{prd,spec,master}.md`. In fix-loop mode: `<scratch_dir>/draft-{prd,spec,master}-vN.md`.
- **Initial mode only:** `considerations_paths[]` (admitted considerations cited as Ready by CR-11's cohort).
- **Fix-loop mode only:** `findings_to_apply[]` — subset of CR-2's findings_union_json filtered to this `target_doc`; `prior_draft_path` — the v(N-1) draft being patched; `required_trace_declarations[]` — verbatim strings to preserve byte-for-byte.

## Output shape

Three files written to disk plus a small return packet:

- **Primary diff** at `output_path`. Format: unified-diff or section-replacement (caller-tolerant; the audit consumes the diff later).
- **Ripple-targets side-file** at `<output_path's directory>/ripple-targets-{doc}.md`. Enumerates every downstream doc the diff implies sync for (subphase plans, pillar plans, TRACKER, governance fences, CLAUDE.md tree). Empty list is acceptable when `mode == fix-loop` AND no fix touched a section that requires re-rippling, but the file MUST exist (with explicit "no new ripple targets in this loop" line).
- **Fitness-fences side-file** at `<output_path's directory>/fitness-fences-{doc}.md`. Enumerates every `tests/test_arch_*.py` that must be added or updated by Build (Engineer flags; Build authors).
- **Return packet:** `{output_path, ripple_targets_path, fitness_fences_path, sections_edited_count, mode_specific_metadata}`.

## Procedure

1. **Read** `boundary_language_path` and capture the 7 INJECT blocks. The 7 injects are load-bearing — the skill REFUSES to emit a draft if any are missing from the reference file.
2. **Validate inputs:**
   - `target_doc` ∈ allowed enum; canonical path resolves on disk.
   - `target_section_anchors[]` non-empty; every anchor resolves in the live canonical doc.
   - `edit_kind_per_anchor` non-empty; every anchor mapped.
   - `evidence_anchor_citations[]` covers every anchor (no orphan sections).
   - Initial mode: `considerations_paths[]` non-empty AND every path resolves on disk.
   - Fix-loop mode: `findings_to_apply[]` non-empty; `prior_draft_path` resolves; `required_trace_declarations[]` non-empty.
3. **RFD discipline check (master-plan only):** scan `target_section_anchors[]` and the planned diff outline for:
   - Anchors that would scaffold subphase subsections inside a §Phase block. Heuristic: a §Phase H2 with proposed H3+ subsections named "Subphase N" or "Pillar N" or scaffold patterns matching `docs/plans/subphases/` shape. HALT with `BLOCKED — RFD violation: scaffolded subphase inside master-plan §Phase`.
   - Edit kinds that would name candidate pillars at master-plan layer ("Pillar 1: …", "candidate pillars: …"). HALT with `BLOCKED — RFD violation: candidate pillar names at master-plan layer`.
4. **Authority-boundary check:** scan the planned diff outline for:
   - Any output path other than the `target_doc`'s canonical path (e.g. proposing edits to a subphase plan, source file, test, CLAUDE.md, AGENTS.md, TRACKER). HALT with `BLOCKED — authority boundary breach: out-of-surface edit proposed`.
   - Any cross-doc move (PRD → arch-spec, arch-spec → master-plan, etc.). HALT with `BLOCKED — cross-doc reorganization (operator-approval-only)`.
5. **Compose the diff:**
   - **Initial mode:** for each anchor, emit the new prose per `edit_kind_per_anchor`. For master-plan §Phase additions, apply the *module-sketch step* (1–2 paragraphs sketching the §Phase's deep-module shape — what it owns, what's intentionally NOT in scope, exit criteria — without scaffolding subphases). Cite `evidence_anchor_citations[]` inline as `(per <citation-anchor>)` markers; every authored section MUST trace to at least one citation.
   - **Fix-loop mode:** the skill emits the v(N) scaffold by COPYING `prior_draft_path` byte-for-byte and applying ONLY the spans named in `findings_to_apply[]`. Required trace declarations preserved verbatim. WD-3 `idc:idc-skill-plan-patch-from-findings` is the actual span-application skill — this skill's fix-loop mode prepares the v(N) shell that WD-3 then patches. (Caller sequences ES-1 fix-loop → WD-3 patch.)
6. **Inject boundary language:**
   - Prepend a `## Operator gates exercised` H2 to the diff context with INJECT 5 verbatim.
   - Prepend an `## Authority boundaries` H2 with INJECTs 1, 2, 6, 7 verbatim (mode-applicable subset; INJECT 1 only for master-plan).
   - The INJECT 3 (Ripple obligation) language renders into the ripple-targets side-file header.
   - The INJECT 4 (Architectural-fitness fence) language renders into the fitness-fences side-file header.
7. **Emit the ripple-targets side-file:**
   - For every authored section, classify what downstream docs sync for the change. Standard implication tables:
     - PRD edit → arch spec → master plan → subphase plans → pillar plans → TRACKER. Each layer named explicitly (or "no implication" with rationale).
     - Arch-spec edit → master plan → subphase plans → pillar plans → TRACKER.
     - Master-plan §Domain/§Phase admission → affected subphase plans (named) → affected pillar plans (named) → TRACKER (named).
   - Side-file shape: H2 per affected layer, bullet list of specific files, plus a 1-line "Ripple disposition: same-PR | separate Ripple change order | no implication" per file.
8. **Emit the fitness-fences side-file:**
   - Enumerate every `tests/test_arch_*.py` triggered by the diff per the rule in INJECT 4.
   - Side-file shape: table `| Fence | Reason | New or Updated | Surface anchor |`. Empty table with explicit "no fence trigger" justification is acceptable when authentic.
9. **Validate output:**
   - Output path written; ripple-targets and fitness-fences side-files written.
   - Diff body contains the 7 INJECT-block headers (or the mode-applicable subset) verbatim.
   - Initial mode: every authored section has at least one `(per <citation-anchor>)` marker.
   - Fix-loop mode: every `required_trace_declarations[]` entry appears byte-for-byte in the output.
10. **Return** the packet `{output_path, ripple_targets_path, fitness_fences_path, sections_edited_count, mode_specific_metadata}`.

## Single-process confirmation

Single-input → single-output: caller hands one packet (target_doc + mode + anchors + citations + boundary path + output path), skill writes one diff file + two side-files at canonical scratch paths and returns one return packet. There is no internal multi-step orchestration, no spawning of teammates / Task subagents, no state across invocations. Each call is independent. Multi-doc admissions (PRD + arch-spec + master-plan in one run) require multiple invocations — once per target_doc — sequenced by the caller (ER-1).

## Banlist

Load-bearing forbiddens — violating any of these is a halt + audit at the calling roleplayer:

- **No edits to canonical paths.** Output is scratch only (`<scratch_dir>/draft-*`). The caller (ER-1) and the parent orchestrator decide when the scratch becomes a PR commit.
- **No edits to subphase plans, pillar plans, source code, tests, TRACKER, root CLAUDE.md, per-directory CLAUDE.md, AGENTS.md.** Engineer authority stops at PRD / arch-spec / master-plan (per INJECT 2 and root `CLAUDE.md §IDC role authority`).
- **No RFD violations.** Master-plan §Phase admissions stop at §Phase boundary; no scaffolded subphase subsections; no candidate-pillar names at master-plan layer (per INJECT 1).
- **No interview prompts.** The skill never emits "ask the operator about X" content into the draft. Evidence-silent decisions surface to the caller as `BLOCKED: blocker: evidence_silent_on_load_bearing_decision` halts; never as in-draft questions (per INJECT 6).
- **No paraphrased INJECT blocks.** The 7 INJECT blocks render verbatim from `boundary_language_path`. Paraphrase risks Q-eng-1 drift between drafter and reviewer (ES-1 vs ES-8 share the substrate).
- **No fix-loop scope widening.** Fix-loop mode edits ONLY spans named in `findings_to_apply[]`. Untouched anchors are byte-for-byte from `prior_draft_path`.
- **No silent ripple-target omission.** If a downstream doc is affected and not enumerated in the side-file, that's a Major reviewer finding at ES-8 — pre-emptively avoid by enumerating exhaustively here.
- **No silent fence-trigger omission.** If a fence is triggered and not enumerated, that's a Major reviewer finding at ES-8.

## Codex parity note

Loaded via the Skill tool by the folded `codex-idc-engineer` (consolidated into `idc:codex-idc-plan`; after substrate-redirection sweep) inside the codex `canonical-doc-drafter` subagent. Per `architecture.md §Cross-runtime substrate model` Option 2 (inline-read), the codex skill body reads the orchestrator inline (PR-5 fold; see substrate skills) AND this skill's body at run time and dispatches the codex subagent with both as orientation. The mode parameter (initial vs fix-loop), the per-target-doc loop, the RFD discipline, and the side-file emit shape apply identically on both runtimes — every codex-idc-engineer admission run gets the same 3-output (diff + ripple-targets + fitness-fences) shape. <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->

## See also

- `references/authority-boundary-injects.md` — the 7 INJECT blocks. Companion file shared with ES-8.
- ES-8 `idc:idc-skill-plan-review` — reviewer companion that probes for the same INJECTs in the diff.
- `idc:idc-skill-canonical-admission-audit` with `mode: anti-pattern-lint` (formerly `idc-skill-engineer-anti-pattern-check`; folded inline per Phase 2D PR-7) — invoked AFTER this skill by ER-1 to lint the emitted draft. <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->
- WD-3 `idc:idc-skill-plan-patch-from-findings` — fix-loop precise patch emit; sequenced AFTER this skill in fix-loop mode.
- CS-5 `idc:idc-skill-planning-substrate` — the parent orchestrator invokes CS-5 BEFORE this skill to capture pre-drafting approval and produce `boundary_language_path`.
- ER-1 the orchestrator inline (PR-5 fold; substrate: `idc:idc-skill-canonical-doc-authoring`) — the caller roleplayer agent that orchestrates this skill plus the `idc:idc-skill-canonical-admission-audit` `mode: anti-pattern-lint` pass (formerly ES-5 / `idc-skill-engineer-anti-pattern-check`; folded inline per Phase 2D PR-7) + WD-3. <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->
- root `CLAUDE.md §IDC role authority` — fence-pinned authority surface; this skill's banlists trace back here.
- `tests/test_arch_idc_workflow.py::test_role_boundaries_are_documented` — the fence pinning the upstream authority table.
