---
description: IDC Autorun — fixpoint full-pipe loop drainer (drain the Recirculation inbox, plan unplanned considerations, heal the board, build eligible Buildable waves; re-loop to a fixpoint, not one-shot)
argument-hint: '[--consideration <path>...] [free-form notes]'
---

You are running `/idc:autorun`, the one button. Operate as the Autorun orchestrator **in this
session**: read `${CLAUDE_PLUGIN_ROOT}/agents/idc-autorun.md` end-to-end, then run its
full-pipe drain loop.

Operator input: `$ARGUMENTS` — optional consideration paths or notes; otherwise drain the
whole repo.

Autorun is **full-pipeline autonomy that pauses only at human gates**: it **never forces** a gate — a gate-worthy item just **pauses behind its gate** (reported + skipped), exactly like an `[operator-action]` gate issue.
It drains the pipe in one fixed top-to-bottom order — **recirculate** the Recirculation inbox, then **plan** approved considerations, then **drain** the Buildable waves — and exits when nothing actionable remains.

**Mark this session as a drain orchestrator (deterministic liveness — run ONCE, at drain start).**
Before the loop below, record in the obligations ledger that THIS session is an active autorun drain,
so the deterministic **Stop fixpoint gate** (`hooks/hooks.json` → `idc_stop_fixpoint_gate.py`) knows to
hold a dishonest exit: a session that tries to stop while `idc_autorun_drain.py` still reports
`drain: recirc-pending` (the Buildable waves are drained but the Recirculation/Consideration inbox is
non-empty) is blocked with the remediation, bounded N=3 then a loud-fail. The marker is **session-scoped**
(keyed to this session's id), so it gates only this drain and never an unrelated session in the same repo:
```bash
# Guard the marker on a NON-EMPTY session id. If $CLAUDE_CODE_SESSION_ID is empty the marker would be
# stored keyed to "" — which the real Stop payload's true id never matches, so the gate would silently
# NEVER fire (a fail-open protection gap). Skip + WARN LOUDLY instead of storing an unkeyable marker
# (do NOT normalize ""→None: an unattributed marker would gate EVERY session in the repo — the exact
# MAJOR-3 false-block). A skipped marker disables the liveness gate for this run, VISIBLY, by design.
if [ -z "$CLAUDE_CODE_SESSION_ID" ]; then
  echo "[idc-liveness] WARNING: CLAUDE_CODE_SESSION_ID is empty — NOT setting the orchestrator_drain marker; the Stop fixpoint gate will NOT fire this run (fail-open, visible). Continuing the drain." >&2
else
  python3 "${CLAUDE_PLUGIN_ROOT}/scripts/hooks/idc_ledger.py" --cwd "$PWD" set \
    --kind orchestrator_drain --session "$CLAUDE_CODE_SESSION_ID"
fi
```
The gate **never blocks a clean board** — a `drain: complete` always wins over the ledger hint, so it
only ever catches a stop that abandons a non-empty inbox. On a clean `drain: complete` exit you may
clear the marker (same command with `clear --kind orchestrator_drain`); it is optional hygiene, not
required for correctness (a drained board is allowed to stop regardless).

**Janitor preflight** — run ONCE, before the drain loop below begins (not on every re-loop pass:
board↔git debris left by a dead or interrupted **prior** session doesn't regenerate mid-run just
because the pipe loops back, unlike the rogue-sweep backstop below, which specifically catches a
**new** rogue item a build triplet can create *during this run* — and a fresh full board read on
every pass would double the GraphQL cost the rate-limit handling below exists to respect). The
deterministic board↔git reconciler (`idc_git_janitor.py`, `/idc:janitor`'s scanner) surfaces debris
up front, before any new build work — not only when the operator remembers to run `/idc:janitor` by
hand:
```bash
# filesystem
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_git_janitor.py" --repo "$PWD" --tracker "$PWD/TRACKER.md" --report
# github
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_git_janitor.py" --repo "$PWD" --backend github --owner <o> --project <n> --report
```
**Report-only by default** — autorun never applies a fix on its own initiative. The **one** opt-in
exception is the operator-set `janitor: auto-safe` knob in `WORKFLOW-config.yaml`: when present,
add `--apply-safe` to the SAME call above instead of `--report` — never a silent auto-apply, always
traceable to an explicit operator setting. `--apply-safe` only ever touches the **SAFE-FIX** tier
(the scanner's own contract). Relay every finding in the exit report as **advisory** — **RISKY and
REPORT-ONLY stay so even with the knob set**, never auto-applied — never a halt, never a reason to
self-narrow the drain.
**Read the scanner's exit code, not just its findings list.** Exit 0 (COHERENT) or 1 (findings) both
report normally. Exit **2** means the scanner could not establish ground truth — an unreadable board,
a failed git op, **or a capped/possibly-partial read that hit its own `--limit` ceiling** — and is
**indeterminate**, never a hollow clean: surface it as such in the exit report and do **not** proceed
as if the repo were COHERENT (a capped read with findings still exits 1, carrying its own stderr
caveat — only a capped read that would otherwise report zero findings forces exit 2).

Traverse the pipe top-to-bottom and **re-loop to a fixpoint** — because a build triplet can file a
new Recirculation ticket mid-drain, re-run the whole pipe after the Buildable waves drain and exit
only when a full pass leaves nothing actionable:

1. **Recirculation intake** — the top of the pipe. **First run the rogue-sweep backstop:**
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_recirc_sweep.py" --repo "$PWD" --auto-correct` — the
   same detective the SessionEnd hook runs, re-run here because a headless `-p` / `/loop` / crashed
   session may not have fired SessionEnd (it is **cancelled** in headless `-p`); it re-stages any
   rogue Buildable (bypassed Plan → no `idc-provenance` marker) into the Recirculation inbox and
   clears its Wave, so the Build drain below can never claim it.
   **Then reconcile the recirculation checkpoint ledger (kill-safe — run at the top of EVERY pass).**
   A main-session `/idc:recirculate` drain fires no `SubagentStop`, and a hard kill fires no hook at
   all, so a prior pass that died mid-drain leaves still-open inbox tickets with **no resume
   checkpoint** — the next pass is the only path that can recover it. Run the deterministic
   reconciliation to checkpoint every un-checkpointed open `Stage = Recirculation ∧ Todo` ticket (and
   clear a checkpoint taint once its ticket has left the inbox):
   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_recirc_reconcile.py" --repo "$PWD" --session-id "$CLAUDE_CODE_SESSION_ID"
   ```
   The backend is auto-detected from `docs/workflow/tracker-config.yaml` (no `--backend` flag needed).
   On the **github** backend this performs **one cheap board read per pass inside the drain loop** —
   NOT on the stop path, so the Stop gate's 0-GraphQL guarantee is unaffected. It is **fail-soft** (a
   reconciliation error never halts the drain) and **repo-gated**; its `reconcile:` verdict is advisory
   — surface a `reconcile: unknown` (an unreadable board) in the exit report, never as a clean state.
   Then, if any `Stage = Recirculation`
   inbox tickets exist (scope discovered mid-build, filed back into the non-Buildable inbox), run
   `/idc:recirculate` with **no arguments** (its **board-scan inbox-drain** mode) to absorb each back
   into the canonical chain *before* any new build work. Not-gate-worthy scope is admitted as a
   `Stage = Consideration` item (which the Planning lane then decomposes this same run); a ticket
   whose backflow changes a gated requirements layer opens a **gated Think PR** — a **human gate**:
   autorun leaves that ticket **paused behind its gate** (reported + skipped), exactly the
   `[operator-action]` skip/surface behavior, and **never forces** it. Skip if no
   `Stage = Recirculation` tickets exist.
2. **Planning lane** — one plan-run durable worker per **approved**, unplanned
   (admitted-but-undecomposed) consideration (each runs `idc:idc-plan`, itself zero-teammate). A
   consideration with an **open Think PR** (pending admission) is treated like an open gate —
   **report + skip, never plan past it**; **serialize board admission** through this parent so the
   global re-wave stays coherent. Skip if none.
3. **Heal board hygiene** in passing (the auto `--fix`; `/idc:doctor` stays read-only).
4. **Build lane** — while eligible build work exists, run `idc:idc-build` on the eligible waves,
   claiming **only `Stage = Buildable`** issues (a `Consideration`/`Planning`/`Recirculation` ticket
   is never scooped — the glass wall), including waves unblocked mid-run from the operator's phone.
   Check the exit condition with the **same deterministic drain helper, by backend** — never
   improvise the predicate or read the board with a bare `gh project item-list` (it truncates at its
   30-item first page → a grown board blinds the lane):
   ```bash
   # filesystem — `--acceptance` also runs the wave-close acceptance check when the build lane is
   # drained (surfaces a Done-but-inert increment as `acceptance: gap <#s>`; file a recirculation on a gap)
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_autorun_drain.py" --tracker <TRACKER.md> --acceptance
   # github — pages the WHOLE board, same predicate (github wave-close acceptance runs in idc:idc-build Phase 4).
   # `--session-id` attributes the persisted drain verdict (.idc-drain-verdict.json) to THIS session so the
   # Stop fixpoint gate can read the github board conjunct locally (0 GraphQL on the stop path, v4 Phase 3
   # Stage E2); the drain also falls back to $CLAUDE_CODE_SESSION_ID if the flag is omitted.
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_autorun_drain.py" --backend github --project <n> --owner <o> --session-id "$CLAUDE_CODE_SESSION_ID"
   ```
   Both apply the identical eligibility predicate (`Status = Todo` AND `(stage or "Buildable") ==
   "Buildable"` AND title not `[operator-action]` AND every native blocked-by `Done`); an
   empty/missing `Stage` reads as `Buildable` (the legacy 4-field default). On the github backend,
   `idc:idc-build`'s own dispatch (Phase 1) mints + hands off the `IDC_ITEMID_CACHE` item-id cache
   once per wave for every tracker mutation that wave's triplets perform (design §C.1, RC4a, #98) —
   the drain this loop dispatches into benefits from that cost fix automatically; nothing further to
   wire here.
5. **Re-loop to a fixpoint, then exit.** The pipe is **not one-shot** — a build triplet can surface a
   recirc event and file a **new `Stage = Recirculation` ticket mid-drain** (Build's larger loop,
   `idc:idc-build` Phase 1b), which is *upstream* of the build lane. So after the build lane drains,
   **loop back to step 1** and re-run recirculate → plan → build; repeat until a **full pass** is a
   fixpoint: no `Stage = Recirculation` ticket remained, no approved consideration was unplanned, and
   the drain predicate reported `drain: complete` (only Done + requirements-gated Blocked + operator
   gate issues + un-admitted considerations + gated recirculation backflow left). The re-loop
   **reuses the SAME machinery as Build's larger loop** — the consultant's structured closeout
   (`idc_recirc_closeout.py`), the per-issue recirc ceiling + cascade-depth cap (`idc_recirc_caps.py`),
   and the new board-lint retired-recirc guard (`idc_board_lint.py`) — so it **parks, never churns**:
   the caps park a chronically-recirculating issue or a deep recirc→build→recirc cascade (Blocked +
   operator-action) instead of re-looping it, and the board-lint guard keeps a paused issue from going
   spuriously eligible behind a **retired** recirc ticket. Termination is **bounded** (not
   unconditionally guaranteed): the caps park a runaway **only while the per-issue `recirc:N` /
   `cascade-depth:D` counts they read are maintained** — the recirc consultant is the designated
   owner that bumps them (`idc:idc-build` Phase 1b) — backstopped by **natural drain** (closed issues
   leave the frontier) and the **outer /loop** that re-checks live board state each pass.
   **Any non-zero drain exit is NOT `complete` — do not exit on it.** That covers `drain: unknown`
   (the board read succeeded but a build candidate's blocked-by lookup could not be verified), a
   hard board-read failure (exit 2, no `drain:` line), and `drain: rate-limited until <reset>` (exit
   3, github only, #99 §C.3). Treat the lane as possibly-unfinished and let the next `/loop`
   iteration re-check; never report the run drained on a non-zero drain exit. The **Stop fixpoint gate**
   (set up at drain start above) is the deterministic backstop for this rule on the filesystem backend:
   if you try to stop while the drain still reports `drain: recirc-pending` (exit 4), the gate refuses
   the stop and hands back the exact remediation — a `drain: complete` is the only honest terminal state.
   A **`rate-limited until <reset>` verdict is a THIRD, distinct case** — not a hard error, not
   nothing-actionable: GitHub's GraphQL quota is exhausted and will reset on its own. Treat it as a
   **deliberate, resumable pause**: never silently drop the tail wave, never report the run drained,
   never busy-retry before `<reset>`. `/loop` re-checks next `/loop` iteration — once past
   `<reset>` the same drain call succeeds again and the lane resumes exactly where it left off (the
   board is the source of truth; nothing is lost by waiting). Any triplet that was mid-finish when
   the quota ran out is not orphaned either: before treating it as still in flight, the next `/loop`
   iteration's `idc:idc-build` re-verifies its **end-state** via `idc_git_finish.py` (PR merged,
   branches gone, worktree gone, Status=Done) — so a finish that actually completed during the
   outage is never re-attempted.
   Emit the exit report: recirculated, planned, admitted, built/merged, board state, the
   **final working-tree state from a post-build `git status --porcelain`** (run it at exit, never a
   start-of-run snapshot — the build lane writes files mid-run, so a stale snapshot under-counts any
   uncommitted/untracked artifact), and anything waiting on the operator.

**Drain everything; one launch gate, never self-narrow.** `/idc:autorun` drains the **whole** repo —
every phase, every eligible wave. Before draining, size a **staffing estimate** from the
ready-frontier width (`idc_autorun_drain.py --width`, one **sous chef** per ready issue — one call
reports the current frontier) accrued across the `/loop` drain: **~N sous chefs / ~M subagents across
K usage windows**. Read
`WORKFLOW-config.yaml::autorun.staffing_gate_threshold` (default **10**): at or below it, run
**fully autonomous with no launch gate**; above it, surface **exactly one** pre-drain
`AskUserQuestion` — **"~N sous chefs / ~M subagents across K windows — go / scope down?"** (a
one-time cost confirmation): on **go**, drain ALL phases; on **scope down**, autorun **stands down**
so the operator runs an explicit `/idc:build --phase N`. Autorun **never self-narrows** to a phase;
phase-scoping is the operator's explicit `/idc:build --phase N` choice. Wrap the drain in `/loop`
so each iteration re-reads the **live board** and **resumes across usage-window resets**.

A pending Think-PR gate (incl. an open Think PR pending admission, or a recirculation's gated
backflow) is not a halt — autorun reports it and exits clean. Run
`/loop /idc:autorun` for always-on operation. Autorun owns no direct canonical or source
writes — every cognitive write happens inside the `/idc:plan` and `/idc:build` runs it
dispatches (`WORKFLOW.md §4.5`).
