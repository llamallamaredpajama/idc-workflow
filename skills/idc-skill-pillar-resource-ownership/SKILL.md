---
name: idc-skill-pillar-resource-ownership
description: 'Use when drafting or reviewing resource ownership tables inside IDC pillar plans.'
---
# idc:idc-skill-pillar-resource-ownership (WM-1)

Fenced-schema substrate skill encoding the canonical shape of the per-pillar Resource Ownership table. The table is embedded inline in every polished pillar plan at `docs/plans/pillars/<domain>-phase-<n>-subphase-<n>-pillar-<n>-<slug>-plan.md` and collectively forms half of the rough matrix that Sequence's QR-3 polishes into `<phase-tag>-matrix.yaml`.

This skill is the immutable shape contract — validates the schema and emits the fixed-format table. Never decides which resources a pillar owns (that's KR-1's drafting work, informed by upstream `§Rough Pillars` `file_surfaces` declarations from Develop's DR-1).

## Input contract

| Field | Shape |
|-------|-------|
| `pillar_id` | the pillar trace key (matches the polished pillar plan's filename stem without `-plan` suffix, e.g. `domain-x-phase-2-subphase-1-pillar-3-foo`) |
| `ownership_rows` | array of objects, one per row in the table (see "Row schema" below) |
| `output_path` | absolute path where the schema-validated table is written (typically a scratch shard at `<scratch_dir>/pillar-resource-ownership/<pillar_id>.md`, OR inline in the pillar plan body if KR-1 is composing the plan body in one shot) |
| `mode` | `validate-and-emit` (default) | `validate-only` (returns validation result without writing) |

### Row schema (load-bearing — every row MUST have all 5 fields)

| Field | Type | Allowed values |
|-------|------|----------------|
| `resource_kind` | enum | `file` \| `service` \| `doc` \| `governance` |
| `resource_id` | string | for `file`: relative repo path; for `service`: service name (e.g. `agent-web`); for `doc`: `docs/...` path; for `governance`: rule slug (e.g. `claude-md-tree`, `tracker-bootstrap-fence`) |
| `ownership` | enum | `exclusive` \| `shared` |
| `parallel_safe_with` | string OR list | for `exclusive`: free-text constraint (e.g. `safe-with-all-non-overlapping`, `blocks-on-pillar-X`); for `shared`: MUST list every co-owning pillar by trace key |
| `notes` | string (optional) | inline `Blocks on:` / `Wave:` directives + free-text rationale |

### Parity rule (load-bearing — fence-pinned)

**Every `shared` row MUST list every co-owning pillar by trace key in the `parallel_safe_with` field.** A `shared` row that names only one co-owner when there are three is a parity violation — pinned by `tests/test_arch_pillar_matrix.py` (the matrix-consolidator deduplicates against the union of all per-pillar tables, and any pillar's table that declares shared-with-A but not shared-with-B-and-C breaks symmetry).

## Output contract — table shape (verbatim)

The emitted table is a 4-column markdown table with H2 heading. Caller embeds the entire block (heading + table) in the pillar plan body (typically in a section titled `## Pillar Resource Ownership`).

```markdown
## Pillar Resource Ownership

| Resource Kind | Resource ID | Ownership | Parallel-safe with |
|---------------|-------------|-----------|--------------------|
| <resource_kind> | <resource_id> | <ownership> | <parallel_safe_with — comma-separated for shared> |
| ... | ... | ... | ... |

<optional: inline `Blocks on: <pillar-id>` / `Wave: <wave-tag>` lines, one per directive, after the table>
```

Inline directives (after the table, before the next H2 heading) are formatted one per line:

```
Blocks on: <pillar-trace-key> | <reason>
Wave: <wave-tag> | <rationale>
```

These directives are read by QR-3 during matrix synthesis to seed `dependencies` edges in `<phase-tag>-matrix.yaml`.

### Downstream — Build `/goal` `[BOUNDARIES]` derivation (load-bearing)

The completed ownership table is the **authoritative source for the Build implementer's `/goal` recipe `[BOUNDARIES]` element** (`${CLAUDE_PLUGIN_ROOT}/agents/idc-build-runbook.md §`/goal` recipe template`). The derivation is mechanical:

- **in-scope writes** = this pillar's `exclusive` rows whose `resource_kind` is `file` / `service` / `doc` — the owned write paths.
- **off-limits** = everything else, **especially** every `shared` row's co-owned surfaces, sibling-pillar surfaces, and any canonical surface (PRD / arch-spec / master-plan / subphase / pillar plans).

This is what lets the `/goal` evaluator catch a write toward an off-limits surface mid-loop instead of only at the post-hoc halt check. Keep the table complete: an owned surface omitted here silently widens what `[BOUNDARIES]` treats as off-limits, and an unlisted co-owned surface silently narrows it.

## Procedure

1. **Validate inputs**:
   - `pillar_id` is a non-empty string matching the polished-pillar trace-key shape.
   - `ownership_rows` is a non-empty array.
   - `output_path` (if `mode = validate-and-emit`) is an absolute path; parent directory exists.
2. **Validate each row**:
   - All 5 fields present (`resource_kind`, `resource_id`, `ownership`, `parallel_safe_with`, optional `notes`).
   - `resource_kind` ∈ `{file, service, doc, governance}`. Out-of-enum → `BLOCKED — row <i>: resource_kind out-of-enum`.
   - `ownership` ∈ `{exclusive, shared}`. Out-of-enum → `BLOCKED — row <i>: ownership out-of-enum`.
   - `parallel_safe_with` is non-empty.
3. **Validate parity rule**: for every row where `ownership = shared`, `parallel_safe_with` MUST list every co-owning pillar by trace key. If `parallel_safe_with` is a single value or a free-text non-list for a `shared` row → `BLOCKED — row <i>: shared row missing co-owner enumeration`.
4. **Validate intra-table uniqueness**: no two rows have identical `(resource_kind, resource_id)` pair. Duplicate → `BLOCKED — row <i>: duplicate (resource_kind, resource_id) with row <j>`.
5. **Emit the table** to `output_path` per the table shape above. Inline directives appended after the table per row's `notes` field if any directive present (parse `Blocks on:` / `Wave:` prefixes from `notes`).
6. **Return** `{output_path, row_count, exclusive_count, shared_count, validation: "PASS"}` to caller.

In `validate-only` mode, skip step 5 — return `{validation: "PASS"}` only.

## Halt conditions

| Halt | When |
|------|------|
| `BLOCKED — pillar_id missing/empty` | step 1 |
| `BLOCKED — ownership_rows empty` | step 1 |
| `BLOCKED — output_path missing or parent dir absent` | step 1 |
| `BLOCKED — row <i>: <resource_kind\|ownership> out-of-enum` | step 2 |
| `BLOCKED — row <i>: shared row missing co-owner enumeration` | step 3 (parity rule) |
| `BLOCKED — row <i>: duplicate (resource_kind, resource_id) with row <j>` | step 4 |

On halt, NO file is written; caller's KR-1 fix-loop or QR-3 matrix-staleness re-synthesis decides next step.

## Banlist

- **Do NOT decide ownership.** KR-1 polishes the rough `file_surfaces` from `§Rough Pillars` into ownership rows; this skill validates + emits.
- **Do NOT auto-elevate `shared` to `exclusive` or vice versa.** Ownership type is KR-1's call.
- **Do NOT invent co-owner pillar trace keys.** If the parity rule fires, halt — caller decides whether to add the missing pillar or correct the row.
- **Do NOT widen the resource-kind enum.** New kind classes require a Ripple change order touching `tests/test_arch_pillar_matrix.py` first.
- **Do NOT widen the ownership enum.** New ownership values require the same Ripple route.
- **Do NOT write to canonical pillar plan paths directly.** This skill writes to scratch shards OR returns the table block as a string for KR-1 to splice into the pillar plan body — never touches `docs/plans/pillars/` directly.

## Cross-references

- WM-2 sibling: `idc:idc-skill-clash-evidence/` (the other half of the rough matrix; clash files reference ownership-table rows by `(resource_kind, resource_id)` pair)
- KR-1 caller: the orchestrator inline (PR-5 fold; pillar-polishing substrate: `idc:idc-skill-pillar-plan-shape` + `idc:idc-skill-plan-review`) (Deconflict's polish workflow; populates this table per pillar)
- QR-3 reader: the orchestrator inline (PR-5 fold; matrix synthesis substrate: WM-3/4/5 skills) (Sequence's matrix synthesizer; consolidates per-pillar tables into matrix.yaml)
- Related skills: KS-2 `idc:idc-skill-pillar-clash-analysis` (detects clashes from these tables), DS-3 `idc:idc-skill-rough-pillars-section` (Develop emits the upstream `file_surfaces` declarations this table polishes)
- Schema fences: `tests/test_arch_pillar_matrix.py`
