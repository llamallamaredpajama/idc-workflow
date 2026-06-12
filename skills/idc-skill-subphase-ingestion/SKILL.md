---
name: idc-skill-subphase-ingestion
description: 'Use when IDC deconflict work needs to ingest canonical subphase plans into structured pillar inputs.'
---
# idc:idc-skill-subphase-ingestion (KS-1 — Deconflict)

CUSTOM. Deconflict's Phase 1 input absorber. Reads every supplied subphase plan plus its upstream master-plan section, and returns a structured per-subphase digest WITH the verbatim `§Rough Pillars` list intact.

This skill is the only way pillar candidates enter Deconflict's reasoning surface. Per the RFD principle (root `CLAUDE.md §Recursive Fractal Distillation (RFD) principle`) Develop's inline `§Rough Pillars` section IS the candidate split — Deconflict polishes them, never invents new ones, never re-derives from §Goal/§Scope prose. This skill enforces that contract by returning the §Rough Pillars list **verbatim** from the source markdown rather than summarized or paraphrased.

## When to invoke

- the orchestrator inline (substrate: `idc:idc-skill-pillar-plan-shape` + `idc:idc-skill-plan-review` + `idc:idc-skill-pillar-clash-analysis`) Phase 1 step 1 — the polish workflow's first read.
- Deconflict parent orchestrator's pre-KR-1 step when it needs to validate subphase admissibility before spawning the polish roleplayer.

Do NOT invoke from Engineer (different layer authority), from Sequence (post-polish input), or from Build (pillar-execution-time input — pillar plans, not subphase plans, are the runtime read).

## Input contract

| Field | Shape |
|-------|-------|
| `subphase_paths` | non-empty array of absolute paths under `docs/plans/subphases/<domain>-phase-<n>-subphase-<n>-<slug>-plan.md` |
| `scratch_dir` | absolute path to the Deconflict run's per-run scratch dir (typically `/tmp/idc-deconflict/<run-id>/`) |
| `output_filename` | basename for the emitted digest (caller-supplied; defaults to `subphase-ingestion.md`) |
| `mode` | `full` (default — emit complete digest) \| `validate-only` (return validation result without writing) |

Each subphase path MUST resolve to a file matching the canonical fence (`docs/plans/subphases/` + `-plan.md` suffix per `tests/test_arch_idc_workflow.py::test_subphase_and_pillar_trace_headers_exist`). Paths that escape the fence → halt.

## Output contract — digest shape (verbatim)

The emitted digest is a single markdown file at `<scratch_dir>/<output_filename>`. Shape:

```markdown
# Subphase Ingestion Digest — <run-id>

**Subphases ingested:** <N>
**Cross-subphase dependency edges detected:** <K>
**§Rough Pillars sections found:** <M>  <!-- MUST equal Σ rough_pillar_count_per_subphase -->

## Subphase 1 — `<basename of path 1>`

**Path:** `<absolute path>`
**Upstream Master Plan Domain/Phase:** <copied verbatim from subphase header>
**Highest Affected Layer:** <subphase | pillar — copied verbatim>
**Goal (1-line):** <distilled from §Goal>
**Work packets (count):** <N>
**File surfaces declared:** <comma-separated list of repo-relative paths from §Scope or work-packet bodies>
**Dependencies (within-subphase):** <list>
**Dependencies (cross-subphase):** <list with subphase trace keys>
**Exit criteria (count):** <N>
**Architectural-fitness obligations:** <list of `tests/test_arch_*.py` modules named, or "none declared">
**No Higher-Layer Impact Rationale:** <copied verbatim — 1 sentence>

### §Rough Pillars (verbatim from source)

> The following block is reproduced byte-for-byte from the subphase plan body — DO NOT paraphrase or extract. KR-1's polish workflow consumes this verbatim.

```
<verbatim §Rough Pillars section content from the subphase plan, including its
sub-headings, bullets, file_surfaces declarations, and dependencies notes.>
```

**Rough pillar entries detected:** <count of distinct rough-pillar entries inside the section>

## Subphase 2 — `<basename of path 2>`

<...same shape...>

## Cross-subphase dependency edges

| From subphase | To subphase | Edge kind | Evidence |
|---------------|-------------|-----------|----------|
| <basename> | <basename> | depends-on / blocks / shared-surface | <plan-section quote or file-surface overlap> |

## Halts / drift detected

<list any subphases flagged for halt — missing §Rough Pillars, unreadable, broken trace, etc. — OR "none">
```

The `### §Rough Pillars (verbatim from source)` heading is LOAD-BEARING. KR-1's polish workflow grep-anchors on this heading + the subsequent fenced block to extract the per-subphase rough-pillar candidate list.

## Procedure

1. **Validate inputs**:
   - `subphase_paths` is non-empty.
   - Every path is absolute, exists, ends in `-plan.md`, and lives under `docs/plans/subphases/`. Mismatch → `BLOCKED — path <i> not under docs/plans/subphases/ or missing -plan.md suffix`.
   - `scratch_dir` exists and is writable.
2. **Per subphase, in input order**:
   - Read the subphase plan end-to-end via `Read` tool.
   - Extract: `Upstream Master Plan Domain/Phase` (required header), `Highest Affected Layer` (required header), `No Higher-Layer Impact Rationale` (required header), §Goal, §Scope, §Work Packets, §Dependencies, §Exit Criteria, §Architectural Fitness Obligations (if present), §Rough Pillars (REQUIRED per RFD principle).
   - **§Rough Pillars MUST exist.** If absent → flag in §Halts and emit `BLOCKED — subphase <basename>: §Rough Pillars section missing (Develop-side defect; route to idc-develop)`. DO NOT invent the section.
   - Capture file surfaces from §Scope + work-packet bodies via simple regex on backtick-quoted relative paths (the governed repo's source dirs per `WORKFLOW-config.yaml` — e.g. `services/`, `web/` — plus `tests/`, `scripts/`, `docs/`).
   - Read the upstream master-plan section named in `Upstream Master Plan Domain/Phase`. Verify the section exists in `docs/plans/master-implementation-plan.md`. Mismatch → flag in §Halts as `subphase <basename>: upstream master-plan section "<name>" not found — route to idc-engineer`.
3. **Cross-subphase dependency detection**:
   - For every pair (i, j) with i < j, check whether subphase i's §Dependencies references subphase j (or its trace key fragment). Record edges as `depends-on`.
   - Check whether subphase i's file-surface list overlaps subphase j's. Record overlaps as `shared-surface` edges.
   - Check whether subphase i's §Goal references subphase j's domain/phase tag. Record as `blocks` edges if i precedes j sequentially but i's exit criteria block j's entry.
4. **Emit the digest** at `<scratch_dir>/<output_filename>` per the digest shape above. Write the §Rough Pillars block **verbatim** — copy character-for-character from the source plan; no normalization, no markdown re-formatting.
5. **Return** `{output_path, subphase_count, rough_pillar_total, cross_subphase_edge_count, halts: [...] | []}`.

In `validate-only` mode, skip step 4 — return validation result only.

## Halt conditions

| Halt | When |
|------|------|
| `BLOCKED — subphase_paths empty` | step 1 |
| `BLOCKED — path <i> not under docs/plans/subphases/ or missing -plan.md suffix` | step 1 |
| `BLOCKED — scratch_dir does not exist or not writable` | step 1 |
| `BLOCKED — subphase <basename>: required header missing (<header name>)` | step 2 (e.g. `Upstream Master Plan Domain/Phase`) |
| `BLOCKED — subphase <basename>: §Rough Pillars section missing (Develop-side defect)` | step 2 — RFD invariant |
| `BLOCKED — subphase <basename>: upstream master-plan section "<name>" not found` | step 2 |

On halt the digest file is NOT written. Caller routes per the halt's recovery hint:

- `§Rough Pillars` missing → route to `idc-develop` for subphase repair (Develop owns rough-pillar emission).
- Master-plan section missing → route to `idc-engineer` for upstream admission.
- Required header missing → route to `idc-develop` for subphase header repair.

## Banlist

- **Do NOT invent or extract a §Rough Pillars list from §Goal/§Scope prose.** If the section is absent from the source, halt — that is a Develop-side defect, NOT a Deconflict drafting opportunity. RFD invariant.
- **Do NOT paraphrase, normalize, or re-format the §Rough Pillars block.** Verbatim only. KR-1 grep-anchors on the source bullet structure.
- **Do NOT invoke KS-2 (clash analysis) or KS-3 (sibling-pillar precedent review) from this skill.** Single-responsibility — KS-1 reads + ingests, KS-2 + KS-3 reason over KS-1's output.
- **Do NOT write to `docs/plans/subphases/`, `docs/plans/master-implementation-plan.md`, or any canonical doc.** Read-only on canonical surfaces; emit-only to the scratch dir.
- **Do NOT widen the per-subphase block schema without a Ripple change order.** KR-1 + KS-2 grep-anchors on the documented headings.
- **Do NOT skip the master-plan-section-exists check.** Subphase admissibility at master-plan layer is part of the digest contract — KR-1's trace-triple gate depends on it.

## Cross-references

- KR-1 caller: the orchestrator inline (PR-5 fold; see substrate skills) (Phase 1 step 1 — invokes this skill once per polish run)
- Downstream consumer: KS-2 `idc:idc-skill-pillar-clash-analysis` (reads this digest's per-subphase file-surface list + §Rough Pillars)
- Sibling read: KS-3 `idc:idc-skill-sibling-pillar-precedent-review` (reads adjacent already-landed pillar plans, NOT subphase plans — disjoint scope)
- Schema fence: `tests/test_arch_idc_workflow.py::test_subphase_and_pillar_trace_headers_exist` (validates required-header subset enforced here)
- RFD principle: root `CLAUDE.md §Recursive Fractal Distillation (RFD) principle`
- Authority source: the folded `idc-deconflict` orchestrator (consolidated into `idc:idc-plan`), Phase 1 line 171 (`subphase-ingester` teammate prompt)
