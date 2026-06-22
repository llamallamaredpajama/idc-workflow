# Operator TODOs — run about-an-idea-to-shimmering-bubble-2026-06-21-2125

Non-blocking findings left for the Finisher / operator. Two sources, kept consolidated here:

1. **wave/1 adversarial review** (this file, below) — codex `codex exec` + manual edge-case probes
   over the `1567f3e..3e62b0c` delta. All Blocker/Major findings were **fixed** on branch
   `team-execute/sb-w1fix` (gate-green); only the Minor/Nit below remain.
2. **writer sb-75 `/simplify` items** — three cosmetic items captured at
   `~/.claude/team-execute-runs/about-an-idea-to-shimmering-bubble-2026-06-21-2125/operator-todos-sb-75.md`.
   **Do NOT fix them now** — wave/2 #76 (ready-frontier-build) touches the same frontier/drain code,
   so they are deferred to the final Finisher sweep to avoid a conflict. (Summarised here only so the
   full picture lives in one place: (a) drop the redundant `ready-frontier:` output line, (b) rename
   the `--frontier` flag → `--width`, (c) capture drain output once per board state in the smoke
   test.)

---

## wave/1 review — Minor

- **`tests/smoke/phase6-autorun-autonomy.sh` §B doctrine checks are prose-greps.** They enforce that
  the staffing-gate doctrine *phrases* are present (and parity across `agents/idc-autorun.md` +
  `commands/autorun.md`) and are red-when-broken (delete a phrase → the test fails), but they verify
  presence, not semantics. codex twice flagged this as higher severity and wanted an "executable
  harness." Held as non-blocking: the doctrine under test is **agent instructions in markdown**, not
  a runnable function, so there is no executable path to assert; and the prose-grep style matches the
  repo's established doctrine tests (`phase6-autorun.sh`, `phase7-command-prose-invariants.sh`).
  Strengthening just this one out of step with the suite would be gold-plating. If desired, the
  Finisher could add a parser-level check that the threshold value and the "exactly one gate" wording
  are internally consistent.

- **`tests/smoke/phase6-autorun-autonomy.sh` frontier coverage gap (codex pass-3).** The `--frontier`
  width assertions exercise the blocked-dependent and `Stage=Consideration` exclusions but not the
  `Stage=Planning` exclusion, the `[operator-action]` title exclusion, or a "blocker becomes Done →
  dependent becomes eligible" transition. (All three ARE covered in `phase6-autorun.sh` for the
  default `drain:` output, so the predicate itself is guarded — this is only about widening the
  `--frontier` width path's direct coverage.) Cheap fixtures to add when the Finisher touches this file.

## wave/1 review — Nit

- **`scripts/idc_matrix_check.py` runs the DAG analysis twice on a PASS** — `check()` calls
  `idc_dag.analyze()` for the cycle test and `publish()` calls it again for the width/critical-path
  numbers. Harmless for plan-sized matrices; could memoize if it ever matters.

- **Autorun doctrine wording nuance.** `agents/idc-autorun.md` / `commands/autorun.md` describe the
  staffing estimate as the frontier width "summed across the remaining buildable waves," but
  `idc_autorun_drain.py --frontier` reports only the *current* unblocked frontier (future-wave work
  is still blocked and excluded). The prose describes the operator's running estimate across `/loop`
  iterations, not a single script call — accurate in spirit, but a reader could expect one invocation
  to return the cross-wave sum. A one-line clarification would remove the ambiguity. (Note: overlaps
  the deferred sb-75 `--frontier`→`--width` rename — fold into that Finisher pass.)
