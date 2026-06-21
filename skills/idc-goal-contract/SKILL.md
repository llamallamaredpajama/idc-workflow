---
name: idc-goal-contract
description: 'Use when Plan distills a pillar into the 6-element goal contract that becomes a board issue body — the contract Build executes cold.'
---
# idc-goal-contract

The authoring shape for a pillar's goal contract — the issue body Build works cold
(`WORKFLOW.md §3.2`). **Planning authors contracts; Build only executes them.** The shape is
the `/fullauto-goal` strategy distilled to the glass wall: infer hard from the repo, render
a complete contract, and make "done" runnable.

## The seven labelled elements

1. **GOAL** — one observable end-state (the finish line). "p95 of `/search` < 200ms on the
   bench," not "faster." If you can't name what's observably true when done, the pillar
   isn't ready.
2. **VERIFICATION SURFACE** — the exact runnable commands + what passing looks like.
   **Real functional tests that prove behavior** — never a placeholder or shallow suite
   (that is a Build review FAIL). **At least one command must exercise the GOAL's observable
   end-state** (run / apply / query / HTTP / e2e), not merely static checks (file-exists, parse,
   lint/typecheck, `terraform validate`/`fmt`, arch-fence `pytest -k arch`, import probes). A
   surface satisfiable without the outcome being real is a Build review FAIL — an inert deliverable
   passes an all-static surface (a DDL that *parses* but is never *applied* to a provisioned store
   does not make the data live). If the GOAL has a runtime/infra dependency, the surface exercises
   it against a real or emulated instance. If the target behavior is untested, the surface says
   *write the failing test first — done = new test passes AND existing suite green*.
3. **CONSTRAINTS** — what must not regress (existing tests green, public API, no new deps,
   neighbor perf), plus the **no-punt rule**: incidental work needed for success is fixed in
   the same loop, never deferred.
4. **BOUNDARIES** — `touch` (the owned surfaces — the deconfliction output from
   `idc:idc-matrix-analysis`) and `off-limits`. These are the parallel-safety contract.
5. **ITERATION POLICY** — record-and-vary (log what changed / what the evidence showed /
   the next experiment; vary failed hypotheses).
6. **BLOCKED-STOP** — explicit halt conditions + the ~3-attempt ceiling, and the exact input
   needed to unblock.
7. **ASSUMPTIONS** — everything inferred rather than told, flagged so it can be vetoed.

Then the glass-wall footer: `Dependencies:` (native blocked-by) and `Trace:` (pillar file ·
consideration · PRD section).

## Complexity-adaptive

Scale the contract to the pillar. A trivial pillar gets a tight one-screen contract; a
risky/broad pillar gets a fuller verification surface, more constraints, and explicit
blocked-stops. Never pad a simple pillar; never under-specify a risky one.

## Validation

The finished body must pass `idc:idc-schema-check`
(`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_schema_check.py" <body>`) before admission.

## Authority boundaries

- Authors the contract text only. Never admits the issue, never writes source/tests, never
  spawns teammates. Build executes the contract; it does not re-author it.
