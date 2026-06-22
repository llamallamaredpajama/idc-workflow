# Operator TODOs — run about-an-idea-to-shimmering-bubble-2026-06-21-2125

Non-blocking Minor/Nit findings from the **wave/1** adversarial review (codex `codex exec` +
manual edge-case probes). The two Major findings were fixed under PR (healing branch
`team-execute/sb-w1fix`); the items below were judged not worth blocking and are left for the
operator to triage.

## Minor

- **`tests/smoke/phase6-autorun-autonomy.sh` §B doctrine checks are prose-greps.** They enforce that
  the staffing-gate doctrine *phrases* are present (and parity across `agents/idc-autorun.md` +
  `commands/autorun.md`), but they verify presence, not semantics — a grep for `scope down` would
  still pass if the prose said the opposite. This matches the repo's existing doctrine-test style
  (`phase6-autorun.sh`, `phase7-command-prose-invariants.sh`), so it is consistent, not a
  regression. *If* you want stronger coverage, add a behavior-level fixture that drives the runnable
  path (threshold compare → exactly-one-gate → no self-narrow). Deferred to avoid gold-plating one
  test out of step with the rest of the suite.

## Nit

- **`scripts/idc_dag.py` silently drops a self-edge** (`blocks_on: [<self>]`). `build_edges` skips
  `x == y`, so a pillar that blocks on itself — an unschedulable authoring error — is treated as a
  no-dependency pillar with no operator signal. Consider surfacing a self-edge as a matrix defect
  (it is a trivial cycle). Low impact; current behavior is documented as intentional.

- **`scripts/idc_matrix_check.py` runs the DAG analysis twice on a PASS** — `check()` calls
  `idc_dag.analyze()` for the cycle test and `publish()` calls it again for the width/critical-path
  numbers. Harmless for plan-sized matrices; could memoize if it ever matters.

- **Autorun doctrine wording nuance.** `agents/idc-autorun.md` / `commands/autorun.md` describe the
  staffing estimate as the frontier width "summed across the remaining buildable waves," but
  `idc_autorun_drain.py --frontier` reports only the *current* unblocked frontier (future-wave work
  is still blocked and excluded). The prose is describing the operator's running mental estimate
  across `/loop` iterations, not a single script call — accurate in spirit, but a reader could
  expect one invocation to return the cross-wave sum. Consider a one-line clarification.
