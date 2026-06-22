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

---

## wave/2 review — Minor

(WAVE/2 adversarial review of the `4199ce6..fc4ed75` delta — #76 ready-frontier-build + #77
sous-chef-ownership. codex `codex exec` (ran clean both passes) + manual probing. **All Blocker/Major
were FIXED** on branch `team-execute/sb-w2fix`, gate-green: the `commands/build.md` wave-barrier
contradiction, the `idc-implementer.md` "active wave" prose, the `idc-finisher.md` stale "same-wave"
merge-safety, the `idc-build.md` Phase 0 github-backend gap + fail-closed-on-helper-error +
width-is-a-ceiling clarity, and two red-when-broken test weaknesses. Only the Minor/Nit below remain.)

- **`tests/smoke/phase4-ready-frontier.sh` §B doctrine checks are prose-greps** (same accepted-standard
  limitation as the wave/1 `phase6-autorun-autonomy.sh` note above). codex pass-1 flagged two as
  "Major": (a) the `width: 2` §A assertion tests the *dependency* frontier (what the helper computes)
  and therefore cannot go red on broken **area-packing**; (b) the "consume, don't duplicate" §B1 grep
  is a token-presence check, not proof the agent consumes the helper rather than re-deriving the
  frontier. Held non-blocking for the same reason: **area-packing and "the agent consumes vs
  re-derives" are agent-markdown behaviors with no executable surface** — there is no runnable path to
  assert them, and the prose-grep style matches the repo's established doctrine tests. (The behavioral
  half the helper *does* own — wave-blind, blocked-aware width — IS genuinely red-when-broken in §A.)
  An executable harness would be a suite-wide change, out of step with the current standard.

## wave/2 review — Nit

- **`idc_autorun_drain.py` docstring still frames width in wave terms.** Lines ~26/119 call `width:`
  "the max-useful parallelism **the next wave** can staff" / "the **per-wave** sous-chef count" — mild
  wave-thinking in a helper that #76 made wave-blind. Cosmetic doc wording (the code is wave-blind and
  correct); fold into the deferred sb-75 `--frontier`→`--width` rename pass so the docstring is
  retuned in one edit rather than twice.

## wave/3 review — Nit

(WAVE/3 adversarial review of the `5bf6c9a..b4389a5` delta — #78 adapter-fanout-docs + #79
e2e-merge-train. codex `codex exec` (read-only on the local diff) + manual probing. The merge-lease
primitive `idc_tracker_fs.py` is **unchanged** — #79 only re-keys the lease NAME — so the findings
were doctrine-coherence + docs-accuracy, not logic. **All Blocker/Major were FIXED** on branch
`team-execute/sb-w3fix`, gate-green: the partial-overlap/surface-keying soundness gap, the
concurrent-vs-single-merger contradiction, the shared-ref-advance overclaim, the Codex `spawn_agent`
`--cd` over-statement, and two red-when-broken test weaknesses (bypassable e2e greps + file-wide
adapter-mechanic greps). Only the Nit below remains.)

- **`skills/idc-adapter-claude/SKILL.md` inner-fan-out wording "one cook per stage thunk"** (line ~41)
  conflates the `pipeline()` **role** pipeline (implement → review → finish, sequential stages on one
  surface) with the **disjoint-sub-surface** cook fan-out (cooks parallelise across *surfaces*, i.e.
  `parallel()` thunks / pipeline *items*, not stages). The concrete mechanic is otherwise accurate
  (`Workflow` tool, `parallel()`, `isolation:'worktree'` per cook), so this is cosmetic; reword to
  "one cook per `parallel()` thunk / per disjoint-surface item" when the finisher next touches the
  claude adapter, so the cook→surface mapping isn't read as cook→stage.

## wave/4 review — Minor

(WAVE/4 adversarial review of the `a389bc9..f6d3a1b` delta — #80 narrow-recirc-deconflict + build-time
mechanical-deconfliction, PR #88. codex `codex exec` (read-only on the local diff) + manual probing +
BSD-grep mutation testing. **All Blocker/Major were FIXED** on branch `team-execute/sb-w4fix`,
gate-green: the mechanical-vs-scope **fail-OPEN** (a real undeclared dependency can surface as an
overlapping-file clash and get silently deconflicted in-kitchen — closed with a fail-closed
classification gate that reclassifies any not-provably-mechanical clash as a scope/menu defect), the
"bounded" specialist with **no terminal state** (closed: attempt-ceiling → halt-with-evidence, no
infinite retry / silent merge), and a **test-coverage gap** (the suite didn't protect build.md's
scope/menu escape hatch — deleting the escalation clause passed green; closed with assertions A7/A8/A9,
all proven red-when-broken under `/usr/bin/grep`). The dangling-sentence fix in `idc-finisher.md` was
verified complete. Only the two Minor below remain.)

- **`tests/smoke/phase4-recirc-deconflict.sh` A2 (mechanical-conflict-type enumeration) under-asserts.**
  The §A2 regex `overlapping.file[^.]*git.merge|mechanical[^.]*(overlapping.file|git.merge|worktree)`
  passes if **only one** of the three mechanical conflict types appears after "mechanical", not all
  three. All three types ARE present in `idc-build.md` today, so this is fidelity-not-correctness:
  splitting A2 into three independent assertions (`overlapping-file`, `git-merge`, `worktree`) would
  remove the bypass. Held Minor — same accepted prose-grep-fidelity standard as the wave/1/wave/2
  notes above; fold into any future tightening pass over the doctrine tests.

- **`idc-finisher.md` step 4 places the mechanical-conflict branch after "Settle tracker status,
  release the lock."** (line ~97). The exceptional in-kitchen-deconflict path reads *after* the
  settle/release prose, so a careless reader could infer status is settled before deconfliction
  succeeds. Meaning is recoverable (the branch is clearly exceptional) and the doctrine is correct —
  purely a prose-ordering nit. Reword so the mechanical-conflict branch precedes settle/release (lock
  released only after a successful merge, or deliberately before a bounded retry) when the finisher
  next touches that step.
