---
name: idc-matrix-analysis
description: 'Use in Plan to run pairwise pillar clash checks, synthesize the phase matrix, and re-sequence the board into parallel-safe waves.'
---
# idc-matrix-analysis

Plan's vertical slice and **one of the two plan reviews** (the other is
`idc:idc-schema-check`). It is the deconfliction guardrail: parallel work never collides
(`WORKFLOW.md §4.2`). Zero durable workers — the clash checks fan out as bounded read-only
subagents. When Plan scoops **all** admitted considerations in one run, this skill first runs the
**§0 batch dedup/deconflict pre-pass** (consideration-level, before decomposition) so the run yields
a single de-duplicated plan; the §1+ pillar matrix then runs at Plan's vertical slice as before.

## 0. Batch dedup/deconflict pre-pass (the whole pending set, before decomposition)

Plan now scoops **all** admitted-but-undecomposed considerations in one run rather than one at a
time, so before any decomposition this pass de-duplicates and deconflicts the whole pending set —
the run produces a single, de-duplicated, deconflicted plan, not N independently-decomposed
considerations that re-plan each other's (or already-shipped) work.

It **reuses the §1 pairwise-clash fan-out** (the same bounded read-only subagents through the
runtime adapter — no new machinery; this **extends the clash logic** rather than duplicating it):
for each pending consideration, dispatch one read-only worker that compares it against —

- **(a) every other pending consideration** — cross-dedup: do two considerations propose the same or
  overlapping scope? (Merge them, or keep one and narrow the other.)
- **(b) the open Buildable / in-flight issues** — already covered? Don't re-plan scope already
  sitting on the board (or being built). `In Progress` issues are immutable — never re-plan them.
- **(c) the current codebase** — already done, or partially done? Drop already-shipped scope; narrow
  a partially-done consideration to the true remaining gap.

Each returns a compact verdict
`{consideration, duplicates[], covered_by_issue?, already_done?, surviving_scope}`. The orchestrator
absorbs verdicts, never full reasoning, and synthesizes **one unified assessment** → the surviving,
de-duplicated scope the decomposition (and the §1 pillar matrix below) then operate on once.

This is the **quality** layer, distinct from §1: §1's pillar matrix prevents same-wave *file* clashes
among the pillars that survive; this pre-pass removes redundant, overlapping, and already-done *work*
(and scope drift) at the consideration level, before any pillar is drafted.

## 1. Pairwise clash checks (bounded fan-out)

For each unordered pair of new pillars, dispatch one read-only fan-out worker that answers
three questions from the pillars' declared surfaces and intent:

- **Shared surfaces?** Do they touch the same files/dirs? (the parallel-safety blocker)
- **Ordering?** Does one depend on the other's output? (a `blocks_on` edge)
- **Parallel-safe?** Can they run in the same wave?

Each returns a compact verdict `{pair, shared_surfaces[], blocks_on?, parallel_safe}`. The
orchestrator absorbs verdicts, never full reasoning.

## 2. Synthesize the matrix

Fold the verdicts into one phase matrix at
`docs/workflow/pillar-matrices/<phase-tag>-matrix.yaml` — the constrained format the
matrix check parses:

```yaml
phase: Phase <N>
pillars:
  - id: <pillar-trace-key>          # github backend: stamped VERBATIM onto the matching Buildable
                                    #   issue at mint as <!-- idc-provenance {"matrix":…,"pillar":<id>} -->
                                    #   so a downstream sweep matches issue↔matrix by EXACT key
    wave: <N>
    domain: <domain>
    surfaces: [<owned path>, ...]   # becomes the issue BOUNDARIES touch-set
    blocks_on: [<other-id>, ...]    # becomes native blocked-by links
```

Each pillar's `id` is the durable provenance key: Plan carries the **exact same** `id` to the
issue-mint step (`idc:idc-goal-contract` stamps it as the github-only `idc-provenance` marker),
so the issue↔matrix link is identical by construction — no fuzzy `Trace:` matching.

Assign waves so that **every pillar in a wave owns disjoint surfaces** and all `blocks_on`
upstreams sit in earlier waves.

## 2.5 DAG intelligence — the staffing ceiling (the head chef gets smart)

Before re-sequencing, read the shape of the `blocks_on` graph so waves are staffed against real
parallelism, not guesswork:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_dag.py" docs/workflow/pillar-matrices/<phase-tag>-matrix.yaml
```

It reports the **critical-path length** (longest `blocks_on` chain — how deep the run must
serialize) and the **max-parallel width** (the widest antichain: the most pillars that are
mutually independent, the parallel-width *ceiling* an ideal wave could ever staff). A cyclic
`blocks_on` graph is unschedulable — it exits non-zero and names the cycle. This is plan-time
intelligence the run-time orchestrator staffs against; it never sets wave fields itself.

## 3. Re-sequence against the live board (global)

Re-sequencing happens ONLY here (`WORKFLOW.md §1.2`). Query the board through
`idc:idc-tracker-adapter`; **`In Progress` issues are immutable** — never re-wave them. Wave
every other not-yet-`In Progress` item (new and previously-`Todo`) globally against the new
matrix, so the board reflects one coherent ordering.

## 4. Validate

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_matrix_check.py" docs/workflow/pillar-matrices/<phase-tag>-matrix.yaml
```

It rejects a matrix where same-wave pillars share a surface (not parallel-safe), a pillar
lacks an id/wave/surfaces, a `blocks_on` ref is dangling (names no declared pillar) or
self-referential, or the `blocks_on` edges form a cycle. On PASS it also publishes the
parallel-width **ceiling** (from the DAG analysis above) plus the carved disjoint **areas** —
pillar groups that never share a file surface, so the orchestrator can staff an independent
writer per area. A clash that cannot be deconflicted into separate waves and is a genuine
upstream contradiction is parked and surfaced for a recirculation — never papered over.

## Authority boundaries

- Produces clash verdicts, the matrix YAML, and the wave assignment. Sets board `Wave`
  fields through `idc:idc-tracker-adapter`. Never edits canonical docs, never writes source,
  never spawns durable workers, never reorders `In Progress` items.
