---
name: idc-skill-drift-evidence
description: 'Use when an IDC Ripple ingester needs to emit a standardized drift evidence artifact.'
---
# IDC Skill — Drift Evidence (`idc:idc-skill-drift-evidence`)

CUSTOM. Standardizes the Phase-1 ingester contract that `${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md §Phase 1 — Impact analysis` requires. Replaces the inline `drift-evidence-ingester` teammate prompt; the parent orchestrator now invokes this skill OR spawns PR-1 (which invokes this skill internally).

## When to invoke

Inside any IDC Ripple workflow that needs to ingest upstream-role evidence:

- **`${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md` Phase 1** — drift-evidence-ingester step. The parent orchestrator dispatches this skill to absorb subphase plan clash files, build divergence reports, brainstorm-teams considerations, sibling pillar conflict files, etc.
- **PR-1 `idc:idc-role-change-order-author` Phase 1** — drift ingestion before classifier dispatch. PR-1 reads this skill's output before invoking RS-2.
- **the orchestrator inline (substrate: `idc:idc-skill-ripple-verdict` + `idc:idc-skill-drift-evidence`) Phase 1** — drift-trigger roleplayer reads this skill's output to confirm the contradiction holds before drafting a Ripple proposal.

## Input shape

Caller passes a single packet with:

- `upstream_idc_role` — exactly one of `think | engineer | develop | deconflict | sequence | build`. Identifies which IDC role's evidence is being ingested (the role that surfaced the drift).
- `evidence_paths[]` — list of absolute paths to evidence files. Examples: a `docs/workflow/pillar-conflicts/<a>-<b>-pillar-conflicts.md` file, a build divergence report at `<scratch_dir>/divergence-report.md`, a Think-output considerations file at `docs/considerations/<YYYY-MM-DD>-<domain>-<slug>-considerations.md`, a sibling pillar plan at `docs/plans/pillars/<...>.md`, a matrix dispatch-check log.
- `proposed_layer_hint` — operator hint about the highest affected layer (`prd | spec | master | subphase | pillar | claude-md | agents-md | domain-claude-md`). The skill confirms or contradicts this hint based on the evidence.
- `scratch_dir` — absolute path to the per-run scratch dir (e.g. `/tmp/idc-ripple/<run-id>/`).
- `output_filename` — basename inside `scratch_dir` for the drift summary (defaults to `drift-evidence.md`).

## Output shape

A single response packet returned to the caller PLUS a structured drift-summary written to `<scratch_dir>/<output_filename>`:

```yaml
output_path: <abs path the drift summary was written to>
drift_summary: <one-paragraph synthesis of the contradiction>
severity: informational | actionable | blocking
surface_classification: governance | codebase
proposed_layer_confirmed: true | false
proposed_layer_revised: <new layer hint, or "n/a" when confirmed>
repo_evidence_excerpts:
  - source_path: <abs path>
    quote: <verbatim excerpt, NO body absorption — quote-only>
    line_range: <line numbers if relevant>
canonical_claim_excerpts:
  - canonical_doc: <abs path or anchor>
    quote: <verbatim excerpt, NO body absorption — quote-only>
    line_range: <line numbers if relevant>
contradiction_pair_count: <N>
recommended_next_step: <one paragraph: invoke RS-2 with these excerpts; or "no contradiction — false positive" when severity == informational>
```

### Severity enum

| Severity | Meaning |
|----------|---------|
| `informational` | Evidence does NOT actually contradict the canonical doc claim — false positive. Caller should NOT proceed to RS-2. |
| `actionable` | Genuine contradiction; canonical drift exists but is below the BLOCKING threshold (e.g. minor section staleness, legacy phrasing). Proceed to RS-2 for verdict classification. |
| `blocking` | Genuine contradiction at a load-bearing layer (master plan / arch spec / PRD; or governance fence; or root CLAUDE.md). Proceed to RS-2 for `MAJOR_GATED` / `GATED` classification. |

### Surface classification

| Surface | Meaning |
|---------|---------|
| `governance` | Evidence implicates the workflow-definition surfaces (the idc-workflow plugin repo), the `CLAUDE.md` tree, governance fences, `docs/workflow/`, `~/.claude/hooks/`. |
| `codebase` | Evidence implicates product/runtime code, PRD, arch spec, master plan, subphase plans, pillar plans, non-governance fences. |

The `surface_classification` from this skill is a **hint** — CS-4 `idc:idc-skill-ripple-verdict` makes the binding pipeline classification when RS-2 runs. The hint is byte-compatible with CS-4's output for unambiguous cases.

## Procedure

1. **Read each `evidence_paths[]` file.** Quote relevant excerpts ONLY — do NOT absorb the full body into the return packet. The repo-evidence-vs-canonical-claim contradiction surfaces from comparing specific anchors, not full-body diffs.

2. **Identify the canonical-doc claim being contradicted.** The evidence file typically references a canonical doc (PRD section, arch-spec table, master-plan §Phase, subphase plan, pillar plan, root CLAUDE.md rule, subdir CLAUDE.md rule). Read the SPECIFIC ANCHOR named, NOT the whole canonical doc.

3. **Quote both sides verbatim.** Build `repo_evidence_excerpts[]` (the upstream IDC role's claim) and `canonical_claim_excerpts[]` (the canonical doc's actual content). The quote must be tight enough that the contradiction is self-evident — typically 5–20 lines per excerpt.

4. **Assess severity.** If the quotes don't actually contradict (the evidence misread the canonical doc, or the canonical doc has an out-of-date section the upstream role legitimately superseded): `informational`. If they contradict at a non-load-bearing layer: `actionable`. If they contradict at a load-bearing layer: `blocking`.

5. **Classify surface.** Inspect both `evidence_paths[]` surfaces AND the canonical-doc anchor surfaces. If either side is in the governance surface list (per CS-4 surface rule), surface is `governance`; otherwise `codebase`.

6. **Confirm or revise the proposed layer hint.** If the operator's hint matches the highest layer named in the canonical-doc-claim quotes: `proposed_layer_confirmed: true`. If the evidence actually implicates a HIGHER layer than the hint suggested (e.g. hint said `pillar` but the canonical claim is at `master-plan`): `proposed_layer_confirmed: false`, `proposed_layer_revised: <new hint>`.

7. **Write the drift summary** to `<scratch_dir>/<output_filename>` per the shape below.

8. **Return the response packet.**

## Drift-summary file shape (verbatim)

```markdown
# Drift evidence — <run-id or change-order-slug>

## Inputs
- Upstream IDC role: <enum>
- Evidence paths: [<list>]
- Proposed layer hint: <enum>

## Severity
- severity: <informational | actionable | blocking>
- surface_classification: <governance | codebase>
- proposed_layer_confirmed: <true | false>
- proposed_layer_revised: <new layer hint, or "n/a">

## Drift summary
<one-paragraph synthesis of the contradiction>

## Repo evidence (verbatim excerpts — quote-only)

### `<source_path>` (<line_range>)
> <verbatim excerpt>

(Repeat per evidence file)

## Canonical claim (verbatim excerpts — quote-only)

### `<canonical_doc>` (<line_range>)
> <verbatim excerpt>

(Repeat per anchor)

## Contradiction pair(s)
(Per pair: which evidence excerpt vs which canonical excerpt; what they each claim; why they cannot both be true.)

## Recommended next step
<one paragraph: proceed to RS-2 with these excerpts; OR "no contradiction — false positive, halt Ripple workflow">
```

## Single-process confirmation

This skill is single-input → single-output: caller hands one packet (`upstream_idc_role` + `evidence_paths[]` + `proposed_layer_hint` + `scratch_dir` + `output_filename`), skill returns one response packet (`drift_summary`, `severity`, `surface_classification`, `proposed_layer_confirmed`, `proposed_layer_revised`, `repo_evidence_excerpts[]`, `canonical_claim_excerpts[]`, `contradiction_pair_count`, `recommended_next_step`) AND writes one drift-summary to `<scratch_dir>/<output_filename>`. Read-only — never edits canonical docs, never spawns teammates / Task subagents.

## Banlist

Load-bearing forbiddens:

- **Read-only.** This skill never edits canonical docs, never edits source / tests / TRACKER. The drift summary at the output path is scratch — under the caller's per-run scratch dir, NOT a canonical path.
- **No body absorption.** Quote-only excerpts in `repo_evidence_excerpts[]` and `canonical_claim_excerpts[]`. Do NOT inline full body sections of canonical docs — that defeats the orchestrator-context-discipline (CS-3) invariant. The reviewer / classifier reads from the quoted anchors via Skill or direct read.
- **No verdict assignment.** This skill returns `severity` (informational / actionable / blocking), NOT a Ripple verdict. RS-2 owns the 4-value verdict; this skill is the upstream evidence-shape standardizer.
- **No proposed-layer override beyond the hint check.** If the evidence revises the hint (e.g. evidence implicates master-plan but hint said pillar), surface the revision in `proposed_layer_revised` — but do NOT classify the verdict from this skill. RS-2 layers on the verdict using the revised hint.
- **No source-code authoring.** Per parent role banlist.
- **No false-positive coercion.** When the evidence does NOT actually contradict the canonical claim (the upstream role misread, or the canonical doc was already correct), return `severity: informational` truthfully. Do NOT manufacture a contradiction to keep the workflow moving.

## Codex parity note

Loaded via the Skill tool by `${CLAUDE_PLUGIN_ROOT}/skills/codex-idc-ripple/SKILL.md` at its drift-evidence-ingester step. The drift-summary file shape is byte-compatible across runtimes; the Codex parent inline-reads the same scratch artifact. Per `appendices/codex-drift-ripple.md`, the codex sibling currently has an inline `drift-evidence-ingester` subagent prompt; this skill replaces that inline prose with a substrate skill that both runtimes invoke identically.

## See also

- RS-2 `idc:idc-skill-ripple-verdict` — downstream consumer; reads this skill's `repo_evidence_excerpts[]` + `canonical_claim_excerpts[]` to compute the 4-value verdict.
- RS-3 `idc:idc-skill-ripple-verdict` — companion governance-side audit when surface is `governance` AND evidence touches CLAUDE.md.
- RS-4 `idc:idc-skill-change-order-shape` — downstream consumer; reads this skill's `drift_summary` to populate the change-order's "Trigger" section.
- CS-3 `idc:idc-skill-planning-substrate` — companion brief-on-disk discipline; this skill's drift-summary file lives on disk per CS-3's invariant.
- CS-4 `idc:idc-skill-ripple-verdict` — companion binary-verdict classifier; this skill's `surface_classification` is a hint that CS-4 confirms.
- PR-1 `idc:idc-role-change-order-author` — multi-step composition workflow; this skill is PR-1's Phase 1 ingestion step.
- the orchestrator inline (substrate: `idc:idc-skill-ripple-verdict` + `idc:idc-skill-drift-evidence`) — per-role drift-trigger roleplayer; invokes this skill in Phase 1 to confirm a contradiction holds.
- `${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md §Phase 1 — Impact analysis` — parent orchestrator boundary; cites this skill rather than restating the ingester prompt.
