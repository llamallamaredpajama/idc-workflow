---
name: idc-skill-clash-evidence
description: 'Use when recording pillar conflict evidence for IDC deconflict work.'
---
# idc:idc-skill-clash-evidence (WM-2)

Fenced-schema substrate skill encoding the canonical shape of clash-evidence files at `docs/workflow/pillar-conflicts/<pillar-a>-<pillar-b>-pillar-conflicts.md`. These files are the durable record of every cross-pillar conflict resolved during a Deconflict run AND are the source of truth Sequence's QR-3 reads when synthesizing the pair-wise clash component of `<phase-tag>-matrix.yaml`.

This skill is the immutable shape contract — validates schema and emits the fixed-format file. Never decides resolutions (that's KR-1 / KS-2's work), never invents evidence.

## Input contract

| Field | Shape |
|-------|-------|
| `pillar_a` | trace key of the lexicographically-first pillar in the pair (e.g. `domain-x-phase-2-subphase-1-pillar-3-foo`) |
| `pillar_b` | trace key of the lexicographically-second pillar in the pair |
| `clash_register` | array of clash entries (see "Clash entry schema" below) — one row per clash between this specific pair |
| `evidence_blocks` | array of evidence-block objects (free-form prose backing each clash entry; see "Evidence block schema") |
| `resolution_rationale` | string (markdown prose) — the rationale paragraph(s) explaining why each clash's `resolution` was chosen |
| `output_path` | absolute path — must match `docs/workflow/pillar-conflicts/<pillar_a>-<pillar_b>-pillar-conflicts.md` exactly |
| `mode` | `validate-and-emit` (default) | `validate-only` (returns validation without writing) |

### Clash entry schema (load-bearing — every entry MUST have all 4 fields)

| Field | Type | Allowed values |
|-------|------|----------------|
| `resource_kind` | enum | `file` \| `service` \| `doc` \| `governance` |
| `resource_id` | string | matches an existing `(resource_kind, resource_id)` pair from one or both pillar plans' Pillar Resource Ownership tables (WM-1) |
| `nature_of_conflict` | string | free-text 1-line description (e.g. "both pillars write to `web/src/foo.tsx`", "Pillar B's API contract supersedes Pillar A's") |
| `resolution` | enum | `serialize` \| `union` \| `ripple-required` |

### Evidence block schema

| Field | Type |
|-------|------|
| `clash_index` | integer index into `clash_register` (0-based) |
| `body` | markdown string with concrete evidence (file paths, line numbers, diff snippets, plan-section quotes) |

## Output contract — file shape (verbatim)

```markdown
# Pillar Conflicts: <pillar_a> ↔ <pillar_b>

**Pillar A:** `<pillar_a>` (link: `docs/plans/pillars/<pillar_a>-plan.md`)
**Pillar B:** `<pillar_b>` (link: `docs/plans/pillars/<pillar_b>-plan.md`)
**Clash count:** <N>

| Resource Kind | Resource ID | Nature of Conflict | Resolution |
|---------------|-------------|--------------------|------------|
| <resource_kind> | <resource_id> | <nature_of_conflict> | <resolution> |
| ... | ... | ... | ... |

## Evidence

### Clash 0 — <clash_register[0].resource_id> (<clash_register[0].resolution>)

<evidence_blocks[clash_index=0].body>

### Clash 1 — <clash_register[1].resource_id> (<clash_register[1].resolution>)

<evidence_blocks[clash_index=1].body>

...

## Resolution rationale

<resolution_rationale prose verbatim>
```

The `## Evidence` and `## Resolution rationale` H2 headings are LOAD-BEARING (KR-1 reviewer + QR-3 reader rely on heading-based parsing). Do NOT rename or omit.

## Procedure

1. **Validate inputs**:
   - `pillar_a` and `pillar_b` are non-empty trace keys.
   - `pillar_a < pillar_b` lexicographically (canonical ordering — pair filenames sort the pair). If reversed → `BLOCKED — pillar pair not in canonical order`.
   - `output_path` matches `docs/workflow/pillar-conflicts/<pillar_a>-<pillar_b>-pillar-conflicts.md` exactly. Mismatch → `BLOCKED — output_path doesn't match canonical pair-filename`.
   - `clash_register` is non-empty.
   - `evidence_blocks` covers every entry in `clash_register` (one or more blocks per clash; each block's `clash_index` is in range).
   - `resolution_rationale` is non-empty.
2. **Validate each clash entry**:
   - All 4 fields present.
   - `resource_kind` ∈ `{file, service, doc, governance}`. Out-of-enum → `BLOCKED — clash <i>: resource_kind out-of-enum`.
   - `resolution` ∈ `{serialize, union, ripple-required}`. Out-of-enum → `BLOCKED — clash <i>: resolution out-of-enum`.
3. **Validate intra-file uniqueness**: no two clash entries have identical `(resource_kind, resource_id)` pair (a single resource can clash only once per pillar pair — multiple distinct natures are still ONE clash entry per pair, with the `nature_of_conflict` field describing all aspects).
4. **Emit the file** to `output_path` per the file shape above.
5. **Return** `{output_path, clash_count, resolution_summary: {serialize: N, union: M, ripple_required: K}}`.

In `validate-only` mode, skip step 4.

## Halt conditions

| Halt | When |
|------|------|
| `BLOCKED — pillar pair not in canonical order` | step 1 |
| `BLOCKED — output_path doesn't match canonical pair-filename` | step 1 |
| `BLOCKED — clash_register empty` | step 1 |
| `BLOCKED — evidence_blocks does not cover all clashes` | step 1 |
| `BLOCKED — clash <i>: resource_kind out-of-enum` | step 2 |
| `BLOCKED — clash <i>: resolution out-of-enum` | step 2 |
| `BLOCKED — clash <i>: duplicate (resource_kind, resource_id) with clash <j>` | step 3 |

## Banlist

- **Do NOT decide resolutions.** KS-2 `idc:idc-skill-pillar-clash-analysis` proposes resolutions; KR-1 / Deconflict orchestrator confirms or escalates to Ripple via KS-5; this skill validates + emits.
- **Do NOT widen the resolution enum.** `serialize` (one pillar precedes the other), `union` (both proceed; conflicting work merged), `ripple-required` (clash means upstream doc is wrong — route to Ripple) are the only allowed values. New values require a Ripple change order touching `tests/test_arch_pillar_matrix.py`.
- **Do NOT auto-resolve `ripple-required` to `serialize`.** A `ripple-required` resolution means Deconflict found upstream-doc drift; that pillar pair is parked until Ripple lands. Severity-downsizing this resolution is forbidden.
- **Do NOT write outside `docs/workflow/pillar-conflicts/`.** Caller's `output_path` validation enforces; halt if mismatched.
- **Do NOT inline-cite plan body content beyond what's in `evidence_blocks`.** Evidence is the only attribution surface — the `nature_of_conflict` is a 1-line label.

## Cross-references

- WM-1 sibling: `idc:idc-skill-pillar-resource-ownership/` (this file references `(resource_kind, resource_id)` pairs from per-pillar ownership tables)
- WM-3, WM-4, WM-5 readers: `idc-skill-pillar-matrix-{dag,wave,parallel-safety}-synth/` consume clash-evidence files as input <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->
- KS-2 `idc:idc-skill-pillar-clash-analysis` (detects + proposes resolution; this skill emits the durable record)
- KR-1 caller: the orchestrator inline (PR-5 fold; pillar-polishing substrate: `idc:idc-skill-pillar-plan-shape` + `idc:idc-skill-plan-review`)
- QR-3 reader: the orchestrator inline (PR-5 fold; matrix synthesis substrate: WM-3/4/5 skills)
- Schema fences: `tests/test_arch_pillar_matrix.py`
