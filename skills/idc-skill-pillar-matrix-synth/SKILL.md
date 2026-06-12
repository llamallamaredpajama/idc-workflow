---
name: idc-skill-pillar-matrix-synth
description: 'Use when IDC Wave planning needs to synthesize dispatch matrices from pillar plans and dependencies.'
---
# idc:idc-skill-pillar-matrix-synth (parameterized WM-3 / WM-4 / WM-5)

Single entry point that folds the three matrix-synthesis skills behind a `view` parameter. Each view is independently invocable; the parent orchestrator (Sequence's QR-3) dispatches the skill three times per matrix synthesis with the correct view. The fence-critical re-synthesis discipline is restated once at the top of this skill and inherited by every view; per-view input contracts, procedures, and halt conditions appear in their own sections below.

## View router

Caller passes `view` exactly once per call. Each view is independently invocable; per-Q2 sequence: dispatch `view: dag` and `view: parallel-safety` in parallel, then dispatch `view: wave` after both fragments land (wave reads both as input).

| `view` | Output fragment | Replaces |
|--------|-----------------|----------|
| `dag` | `dependency_dag:` view of `<phase-tag>-matrix.yaml` | `idc-skill-pillar-matrix-dag-synth` | <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->
| `parallel-safety` | `parallel_safety:` view of `<phase-tag>-matrix.yaml` | `idc-skill-pillar-matrix-parallel-safety-synth` | <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->
| `wave` | `wave_ordering:` view of `<phase-tag>-matrix.yaml` (depends on `dag` + `parallel-safety` outputs) | `idc-skill-pillar-matrix-wave-synth` | <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->

## Re-synthesis discipline (load-bearing — fence-pinned)

This is THE fence-critical contract for the matrix-analysis track. Pinned by:
- `tests/test_arch_pillar_matrix.py::test_active_rows_locked` — active-pillar rows must be byte-for-byte preserved across re-runs
- `tests/test_arch_pillar_matrix.py::test_synthesis_deterministic` — same input produces same output (stable ordering, no timestamp leakage, no nondeterministic dict iteration)

Every view honors this discipline:

| Phase | Action |
|-------|--------|
| 1. **Drop completed** | For every pillar in `completed_pillars`, do NOT include it in the view's output. Completed pillars are absorbed into the milestone-level history; the active-and-pending matrix is what the operator + Build need. |
| 2. **Lock active byte-for-byte** | For every pillar in `active_pillars`, COPY VERBATIM the existing rows for that pillar from the prior `<phase-tag>-matrix.yaml` if it exists. Active pillars MUST NOT be re-synthesized — Build is in flight against the active rows; rewriting them mid-flight invalidates Build's dispatch-check. If no prior matrix exists (first synthesis), skip this step (active list is empty by definition on first run). |
| 3. **Re-synthesize pending** | For every pillar in `pending_pillars`, freshly read its WM-1 ownership table + every WM-2 clash-evidence file referencing it, and synthesize the per-view content. |

**Determinism rules** (apply to every view):
- Sort pillars within each section by trace key (lexicographic).
- Sort all per-pillar list fields (`depends_on`, `blocks`, `clash_with`, `parallel_safe_with`, `unsafe_parallel_with`, `shared_writers`, `seeded_from`) by trace key.
- Sort waves by integer ordinal (`wave-1`, `wave-2`, ...).
- Topological-sort tiebreaks resolved by trace key (lexicographic).
- For symmetric pair relations (e.g. `unsafe_parallel_with: [A, B]` for pillar A means pillar B's entry must include A), assert symmetry — halt on mismatch.
- Use single-quote strings consistently (no smart quotes, no unicode normalization variation).

---

## View 1 — `dag` (`dependency_dag:` fragment)

Replaces former WM-3 `idc-skill-pillar-matrix-dag-synth`. YAML-fragment-only synthesis. Reads per-pillar Pillar Resource Ownership tables (WM-1 emissions) + clash-evidence files (WM-2 emissions) for a phase, applies the re-synthesis discipline, and emits the `dependency_dag:` view of `<phase-tag>-matrix.yaml`. The `wave` view (WM-4) reads this view's output to seed wave ordering. The `parallel-safety` view (WM-5) is independent (reads same upstream WM-1 + WM-2 inputs). <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->

### Input contract (`dag`)

| Field | Shape |
|-------|-------|
| `view` | `dag` |
| `active_pillars` | array of trace keys currently in active state (TRACKER `Currently building: <key>` non-`(idle)` entries) |
| `pending_pillars` | array of trace keys in pending state (admitted to TRACKER but not yet building) |
| `completed_pillars` | array of trace keys in completed state |
| `prior_matrix_path` | absolute path to existing `<phase-tag>-matrix.yaml` if any (for active-row locking); MAY be empty string on first synthesis |
| `ownership_table_dir` | absolute path to the directory containing per-pillar ownership shards (typically `<scratch_dir>/pillar-resource-ownership/` OR derived from each pillar plan body) |
| `clash_evidence_dir` | absolute path to `docs/workflow/pillar-conflicts/` (the durable clash-evidence files) |
| `output_path` | absolute path for the YAML fragment (typically `<scratch_dir>/dependency-dag-fragment.yaml`) |

### Output contract — `dag` YAML fragment shape

```yaml
dependency_dag:
  active:
    # byte-for-byte from prior_matrix_path; sorted by trace key
    - id: <active-pillar-trace-key>
      depends_on: [<sorted trace keys>]
      blocks: [<sorted trace keys>]
      clash_with: [<sorted pair-filename references>]
    - ...
  pending:
    # freshly synthesized; sorted by trace key
    - id: <pending-pillar-trace-key>
      depends_on: [<sorted trace keys>]
      blocks: [<sorted trace keys>]
      clash_with: [<sorted pair-filename references>]
    - ...
```

This is a YAML fragment — the caller (QR-3 step 7) consolidates this fragment with the wave-synth and parallel-safety-synth outputs into the full `<phase-tag>-matrix.yaml`.

### Procedure (`dag`)

The skill routes to `python docs/workflow/scripts/pillar_matrix.py --synthesize-dag` with the input arguments translated to CLI flags. Internally:

1. **Validate inputs**: all directory paths exist; `output_path` parent dir exists; `prior_matrix_path` is either a real file path or empty string.
2. **Drop completed** — discard `completed_pillars` from synthesis scope.
3. **Lock active**:
   - If `prior_matrix_path` is empty OR not a file, halt with `BLOCKED — active locking requires prior matrix` IF `active_pillars` is non-empty (active means in-flight; absence of prior matrix while active is non-empty is contradictory). Empty active + empty prior → step continues with empty active list.
   - Else read `prior_matrix_path`, parse `dependency_dag.active` and `dependency_dag.pending` blocks, EXTRACT the rows for every pillar in `active_pillars` byte-for-byte. If any active pillar is missing from the prior matrix → halt with `BLOCKED — active pillar <id> missing from prior matrix`.
4. **Re-synthesize pending** — for each pillar in `pending_pillars`:
   - Read the per-pillar ownership table (WM-1 emission).
   - Read every clash-evidence file in `clash_evidence_dir` whose filename includes this pillar's trace key.
   - Compute `depends_on` from `Blocks on:` directives in the ownership table's inline directives.
   - Compute `blocks` as the inverse of `depends_on` for sibling pending pillars (also includes any pending pillar this one is named in via `Blocks on: <this>`).
   - Compute `clash_with` from clash-evidence file names this pillar appears in.
5. **Sort everything** per the determinism rules above.
6. **Emit the YAML fragment** to `output_path`.
7. **Return** `{output_path, active_count, pending_count, total_dependencies, total_clashes}`.

### Halt conditions (`dag`)

| Halt | When |
|------|------|
| `BLOCKED — output_path parent dir absent` | step 1 |
| `BLOCKED — active locking requires prior matrix` | step 3 (active non-empty + no prior matrix) |
| `BLOCKED — active pillar <id> missing from prior matrix` | step 3 |
| `BLOCKED — pending pillar <id>: ownership table not found` | step 4 |
| `BLOCKED — pending pillar <id>: ownership table malformed` | step 4 |
| `BLOCKED — clash-evidence file <name>: malformed` | step 4 |

On halt, NO YAML fragment is written. Caller (QR-3) decides whether to re-bootstrap or escalate.

### Banlist (`dag`)

- **Do NOT re-synthesize active rows.** Byte-for-byte preservation is fence-pinned. Even if the ownership table changed, active rows are frozen until the pillar transitions out of active.
- **Do NOT include completed pillars in any output section.** Completion absorption is permanent for the lifetime of the matrix; restoration requires a Ripple change order.
- **Do NOT invent pillar trace keys.** If a clash-evidence file references a pillar not in active+pending+completed, halt — that's a Ripple condition.
- **Do NOT add metadata beyond the schema.** No `synthesized_at:` timestamps (breaks determinism); no `synthesized_by:` annotations (breaks determinism).
- **Do NOT widen `clash_with` references beyond pair-filename strings.** This view's downstream consumers expect `<pillar_a>-<pillar_b>-pillar-conflicts.md`-shape strings only.
- **Do NOT write outside `output_path`.** Single fragment file per invocation.

---

## View 2 — `parallel-safety` (`parallel_safety:` fragment)

Replaces former WM-5 `idc-skill-pillar-matrix-parallel-safety-synth`. YAML-fragment-only synthesis. Reads per-pillar Pillar Resource Ownership tables (WM-1) + clash-evidence files (WM-2), applies the re-synthesis discipline, and emits the `parallel_safety:` view of `<phase-tag>-matrix.yaml`. <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->

Independent of the `dag` view — both read the same upstream WM-1 + WM-2 inputs but emit different views. The `wave` view reads BOTH this view's output and the `dag` view's output. Per QR-3's step ordering: dispatch `view: dag` and `view: parallel-safety` in parallel; dispatch `view: wave` after both land.

### Input contract (`parallel-safety`)

| Field | Shape |
|-------|-------|
| `view` | `parallel-safety` |
| `active_pillars` | array of trace keys in active state |
| `pending_pillars` | array of trace keys in pending state |
| `completed_pillars` | array of trace keys in completed state |
| `ownership_table_dir` | absolute path to per-pillar ownership shards (typically `<scratch_dir>/pillar-resource-ownership/` OR derived from each pillar plan body) |
| `clash_evidence_dir` | absolute path to `docs/workflow/pillar-conflicts/` |
| `prior_matrix_path` | absolute path to existing `<phase-tag>-matrix.yaml` if any; MAY be empty string |
| `output_path` | absolute path for the YAML fragment (typically `<scratch_dir>/parallel-safety-fragment.yaml`) |

### Output contract — `parallel-safety` YAML fragment shape

```yaml
parallel_safety:
  active:
    # byte-for-byte from prior_matrix_path; sorted by trace key
    - id: <active-pillar-trace-key>
      parallel_safe_with: [<sorted trace keys>]
      unsafe_parallel_with: [<sorted trace keys>]
      shared_writers: [<sorted trace keys for shared file surfaces>]
    - ...
  pending:
    # freshly synthesized; sorted by trace key
    - id: <pending-pillar-trace-key>
      parallel_safe_with: [<sorted trace keys>]
      unsafe_parallel_with: [<sorted trace keys>]
      shared_writers: [<sorted trace keys for shared file surfaces>]
    - ...
```

`parallel_safe_with` and `unsafe_parallel_with` are mutually exclusive per-pair: a pair is in one or the other (or in neither — when no relationship is specified). `shared_writers` enumerates pillars that share file write surfaces with this pillar (a stricter concurrency constraint than mere `unsafe_parallel_with`).

### Procedure (`parallel-safety`)

The skill routes to `python docs/workflow/scripts/pillar_matrix.py --synthesize-parallel-safety` with the input arguments translated to CLI flags. Internally:

1. **Validate inputs**: directory paths exist; `output_path` parent dir exists.
2. **Drop completed**.
3. **Lock active byte-for-byte**:
   - If `prior_matrix_path` empty AND `active_pillars` non-empty → halt with `BLOCKED — active locking requires prior matrix`.
   - Else read prior matrix, extract `parallel_safety.active` rows for every active pillar byte-for-byte.
   - Missing active row → halt with `BLOCKED — active pillar <id> missing from prior parallel-safety`.
4. **Re-synthesize pending**:
   - For each pending pillar, read its WM-1 ownership table.
   - For each row in the ownership table:
     - If `ownership = exclusive`: pillars sharing the same `(resource_kind, resource_id)` (none expected) would clash; otherwise no shared-writer entry.
     - If `ownership = shared`: every co-owner in `parallel_safe_with` is added to this pillar's `shared_writers` list AND to `parallel_safe_with` (sharing a write target IS allowed in `parallel_safe_with` if `union` resolution applies — but downstream wave-synth treats `shared_writers` as the stricter signal).
   - Read every clash-evidence file in `clash_evidence_dir` referencing this pillar:
     - For clash entries with `resolution: serialize` → add the partner pillar to `unsafe_parallel_with`.
     - For clash entries with `resolution: union` → ensure partner pillar is in `shared_writers` (already added via WM-1 parity rule).
     - For clash entries with `resolution: ripple-required` → add the partner pillar to `unsafe_parallel_with` AND emit a `RIPPLE_PARKED` annotation in `notes:` (this pillar is on hold pending Ripple).
5. **Symmetry validation**: for every entry in any pillar's `unsafe_parallel_with` list, the partner pillar's entry must also include this pillar. Asymmetry → halt with `BLOCKED — symmetry violation: <pillar_a>.unsafe_parallel_with includes <pillar_b> but not vice versa`.
6. **Sort everything** per determinism rules.
7. **Emit the YAML fragment** to `output_path`.
8. **Return** `{output_path, active_count, pending_count, total_unsafe_pairs, ripple_parked_pairs}`.

### Halt conditions (`parallel-safety`)

| Halt | When |
|------|------|
| `BLOCKED — ownership_table_dir missing` | step 1 |
| `BLOCKED — clash_evidence_dir missing` | step 1 |
| `BLOCKED — active locking requires prior matrix` | step 3 |
| `BLOCKED — active pillar <id> missing from prior parallel-safety` | step 3 |
| `BLOCKED — pending pillar <id>: ownership table malformed` | step 4 |
| `BLOCKED — clash-evidence file <name>: malformed` | step 4 |
| `BLOCKED — symmetry violation: <pair>` | step 5 |

### Banlist (`parallel-safety`)

- **Do NOT re-synthesize active rows.** Byte-for-byte preservation is fence-pinned. Build's `pillar_matrix.py --dispatch-check` would invert if active rows mutate.
- **Do NOT include completed pillars in any output section.** Permanent absorption.
- **Do NOT silently fix symmetry violations.** Halt and surface — asymmetry indicates upstream WM-1 / WM-2 drift that the caller (QR-3) needs to flag.
- **Do NOT add metadata beyond schema.** No timestamps; no synthesizer annotations beyond `RIPPLE_PARKED` in `notes:`.
- **Do NOT write outside `output_path`.**
- **Do NOT collapse `shared_writers` into `parallel_safe_with`.** They're distinct signals — `shared_writers` is the stricter "needs serialization or union" signal; `parallel_safe_with` is the looser "can be in same wave" signal.

---

## View 3 — `wave` (`wave_ordering:` fragment)

Replaces former WM-4 `idc-skill-pillar-matrix-wave-synth`. YAML-fragment-only synthesis. Reads the dependency-dag fragment from `view: dag` + the parallel-safety fragment from `view: parallel-safety`, applies the re-synthesis discipline (drop completed / lock active wave assignments byte-for-byte / re-synthesize pending wave assignments via topological sort), and emits the `wave_ordering:` view of `<phase-tag>-matrix.yaml`. <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->

Sequence's QR-3 dispatches `view: dag` and `view: parallel-safety` first (independent in the per-Q2 sequence), then dispatches `view: wave` with both their outputs as input. The wave view is the synthesis terminal in the sense that wave assignments determine concurrency boundaries Build will dispatch against.

### Input contract (`wave`)

| Field | Shape |
|-------|-------|
| `view` | `wave` |
| `active_pillars` | array of trace keys in active state |
| `pending_pillars` | array of trace keys in pending state |
| `completed_pillars` | array of trace keys in completed state (informational only — for sanity checks) |
| `dag_fragment_path` | absolute path to the `view: dag` emission's `dependency-dag-fragment.yaml` |
| `parallel_safety_fragment_path` | absolute path to the `view: parallel-safety` emission's `parallel-safety-fragment.yaml` |
| `prior_matrix_path` | absolute path to existing `<phase-tag>-matrix.yaml` if any (for active wave-assignment locking); MAY be empty string on first synthesis |
| `output_path` | absolute path for the YAML fragment (typically `<scratch_dir>/wave-ordering-fragment.yaml`) |

### Output contract — `wave` YAML fragment shape

```yaml
wave_ordering:
  active:
    # byte-for-byte from prior_matrix_path; sorted by wave then by trace key
    - wave: <wave-tag>
      pillars: [<sorted trace keys>]
    - ...
  pending:
    # topologically sorted; deterministic tiebreak
    - wave: <wave-tag>
      pillars: [<sorted trace keys>]
      seeded_from: [<sorted trace keys that this wave depends on>]
    - ...
```

### Procedure (`wave`)

The skill routes to `python docs/workflow/scripts/pillar_matrix.py --synthesize-wave` with the input arguments translated to CLI flags. Internally:

1. **Validate inputs**: `dag_fragment_path` is a readable YAML file; `parallel_safety_fragment_path` is a readable YAML file; `output_path` parent dir exists.
2. **Drop completed** — discard from synthesis scope.
3. **Lock active wave assignments**:
   - If `prior_matrix_path` is empty AND `active_pillars` is non-empty → halt with `BLOCKED — active locking requires prior matrix`.
   - Else read prior matrix, extract `wave_ordering.active` block byte-for-byte for every pillar in `active_pillars`.
   - If any active pillar is missing from prior matrix → halt with `BLOCKED — active pillar <id> missing from prior matrix wave assignment`.
4. **Re-synthesize pending wave assignments**:
   - Build a DAG from the `view: dag` fragment restricted to `pending_pillars` ∪ `active_pillars` (active are pinned; pending are sorted relative to them).
   - Apply parallel-safety constraints from the `view: parallel-safety` fragment: pillars marked `unsafe_parallel_with` cannot share a wave.
   - Run deterministic topological sort: nodes with zero unmet predecessors enter `wave-1`; remove them; repeat for `wave-2`; etc. Tiebreak by trace key.
   - Within each wave, validate no two pillars are unsafe-parallel together — if violation detected, push the lexicographically-later pillar to the next wave.
   - Active pillars retain their existing wave assignments; pending pillars sort into waves ≥ the maximum active wave (no pending pillar enters a wave earlier than the active wave) — if topological sort would place a pending pillar in an earlier wave, push it forward.
5. **Emit the YAML fragment** to `output_path`.
6. **Return** `{output_path, wave_count, max_pending_wave, parallel_safety_violations_resolved}`.

### Halt conditions (`wave`)

| Halt | When |
|------|------|
| `BLOCKED — dag_fragment_path missing or unreadable` | step 1 |
| `BLOCKED — parallel_safety_fragment_path missing or unreadable` | step 1 |
| `BLOCKED — active locking requires prior matrix` | step 3 |
| `BLOCKED — active pillar <id> missing from prior matrix wave assignment` | step 3 |
| `BLOCKED — topological sort: cycle detected involving <pillar_a>, <pillar_b>` | step 4 |
| `BLOCKED — irreconcilable parallel-safety conflict between <pillar_a> and <pillar_b> after 3 wave pushes` | step 4 (algorithmic safety net) |

On halt, NO YAML fragment is written.

### Banlist (`wave`)

- **Do NOT re-synthesize active wave assignments.** Build is dispatching against them.
- **Do NOT re-order completed pillars into pending.** Completion absorption is permanent.
- **Do NOT widen the wave-tag format.** `wave-<integer>` only. Named waves (`wave-stabilization`, etc.) require a Ripple change order.
- **Do NOT add metadata beyond schema.** No timestamps, no synthesizer annotations.
- **Do NOT write outside `output_path`.**

---

## Cross-references

- WM-1 input source: `idc:idc-skill-pillar-resource-ownership/` (per-pillar ownership tables) — read by `view: dag` and `view: parallel-safety`.
- WM-2 input source: `idc:idc-skill-clash-evidence/` (durable clash-evidence files) — read by `view: dag` and `view: parallel-safety`.
- QR-3 caller: the orchestrator inline (substrate: `idc:idc-skill-pillar-matrix-synth`) — dispatches the skill three times (one per view) per matrix synthesis run.
- TRACKER consumer: lane-block emission in TRACKER's `## Implementation Wave Queue` reads the `view: wave` output (sequenced into `Currently building: (idle)` lines per wave-tag at admit time).
- Build dispatch consumer: `python docs/workflow/scripts/pillar_matrix.py --dispatch-check --pillar=<id>` reads the `view: parallel-safety` output to authorize Build's dispatch.
- Schema fences: `tests/test_arch_pillar_matrix.py::test_active_rows_locked`, `::test_synthesis_deterministic` — pin the re-synthesis discipline across all three views.
