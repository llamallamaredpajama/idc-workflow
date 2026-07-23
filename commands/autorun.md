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
It drains the pipe in one fixed top-to-bottom order — **recirculate** the Recirculation inbox, then **plan** approved considerations, then **drain** the Buildable waves — and exits when nothing actionable remains. A repo still carrying
`reconciliation-baseline-required` / `baseline-pending` is **not** actionable completion: the drain must surface `baseline: pending` / `drain: baseline-pending`, never `complete`.

**Command lifecycle (verify at entry).** The command entry gate opened this command's lifecycle record
at expansion; verify it before the drain, and **close it with a validated terminal status** at exit
(the Stop closeout gate refuses a walk-away from an open command):
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" status \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --json
```

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
clear the marker with the command below; it is optional hygiene, not required for correctness (a
drained board is allowed to stop regardless). Note `clear` takes **no `--session`** — a taint's
identity is its `(kind, key)` pair, and clearing is deliberately NOT session-scoped so a later session
can discharge a dead one's marker. (Written out in full because "the same command with `clear`" read
as "keep the `--session` flag too": two independent agent runs did exactly that and hit
`unrecognized arguments: --session`.)
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/hooks/idc_ledger.py" --cwd "$PWD" clear \
  --kind orchestrator_drain
```

**Pick up a paused run (deterministic — run ONCE, at drain start).** A previous session may have
stopped this repo's pipeline on purpose with `/idc:pause`. That pause is graceful by contract —
nothing was left half-done — and it holds no work state, so resuming it is exactly: clear the record,
then drain from the live board as usual. Doing this at the top of the drain is what makes a forgotten
pause impossible to strand: the operator gets the run back by running `/idc:autorun`, without having
to remember they paused it. `resume: not-paused` is the normal, silent case, and costs one local file
stat — it reads no board and adds zero GraphQL.

<!-- autorun-preflight:begin -->
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_pause_state.py" --cwd "$PWD" resume \
  --session "$CLAUDE_CODE_SESSION_ID"
```
<!-- autorun-preflight:end -->

Report it in the exit report when it cleared something: `resume: cleared (paused)` means this run
continues a deliberately-paused one, and `resume: cleared (pause-requested)` means the previous
session asked to pause and never achieved it — an ordinary interrupted run, so treat anything the
normal preflight sweeps surface as that session's unfinished business, not as a clean handover.

**`resume: error …` (exit 2) — ABORT THE DRAIN. Do not start work.** The pause record could not be
removed, so this repo is **still paused**. Draining over it is the worst of both worlds: the run
starts working again while the Stop fixpoint gate, reading that surviving record, still believes the
run is cleanly stopped and will allow an undrained walk-away. Relay the printed cure (make the record
path writable), close this command as `blocked_external` citing
`blocker:{helper:"idc_pause_state.py", exit:2, diagnostic:"<the printed cure>"}`, and end the session.
The helper wrote a durable failure receipt when the removal actually failed, and the validator requires
**that receipt** — bound to this invocation — so this close is only reachable when the preflight really
did fail, never as a way out of a drain you did not want to run. This matches `commands/resume.md` step 1, which stops on the same condition — the
preflight is the same clear, so it cannot have a weaker rule.

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
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_git_janitor.py" --repo "$PWD" --tracker "$PWD/TRACKER.md" --json
# github
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_git_janitor.py" --repo "$PWD" --backend github --owner <o> --project <n> --json
```
**Report-only by default** — the janitor's default mode mutates nothing (`--json` only makes the
report machine-readable), and autorun never applies a fix on its own initiative. The **one** opt-in
exception is the operator-set `janitor: auto-safe` knob in `WORKFLOW-config.yaml`: when present,
add `--apply-safe` to the SAME call above — never a silent auto-apply, always
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
   **Then complete any finish a dead session left in flight (handoff safety — run at the top of
   EVERY pass).** The finish tail merges the PR — which also closes the linked issue, via the
   mandated closing keyword — several steps before it flips the board. A session that died in that
   window left the item **shipped, closed, and still `In Progress`**; the tail records that window as
   a `mid_finish:<item>` obligation in the session ledger, and a LATER session is the only thing that
   can discharge it:
   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_finish_recover.py" --repo "$PWD" --session-id "$CLAUDE_CODE_SESSION_ID"
   ```
   It reads the ledger **across sessions** (the taint belongs to a session that is already dead),
   asks the **board** about each item first — an item already `Done` just has its stale taint cleared,
   never re-closed — and completes the rest through the existing idempotent
   `idc_git_finish.py --close-only` door, which journals the close exactly once. Costs **no** board
   read at all when there is nothing to recover (a local ledger read), is **fail-soft** (never halts
   the drain), **repo-gated**, and safe to run repeatedly. Its verdict is advisory: relay
   `recovered:` / `cleared:` in the exit report, and treat **`unresolved:`** as a live obligation the
   run still owes — those taints are deliberately PRESERVED, never dropped, and the item is named
   with the reason the door refused (most often: the finish died *before* the merge, so nothing
   shipped and the item is simply still open).
   **Then synthesize any phantom-idle implementer (drop H — run at the top of EVERY pass, beside the
   reconcile above).** An implementer teammate can go IDLE without reporting: its item sits
   `Stage = Buildable ∧ Status = In Progress` (claimed) but is never advanced, and the drain is BLIND
   to it (it counts only `Todo` / merged-`Done`) — so the wave would close `drain: complete` with the
   item **stranded**. Run the deterministic synthesizer to reconstruct each such item's real state
   from **local git evidence** (no board GraphQL beyond the one item read, no per-item `gh pr view`):
   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_teammate_idle_synth.py" --repo "$PWD" --session-id "$CLAUDE_CODE_SESSION_ID"
   ```
   It stamps ONE idempotent breadcrumb per `(item, class)` and prints one `teammate-idle:` line per
   In-Progress item. Act on each class through the SANCTIONED path — the synth never moves the board:
   - `teammate-idle: <n> synthesized-complete branch <b>` — the work LANDED (its branch is merged into
     base, incl. a **squash-merge** the synth detects by patch-equivalence) but the board never
     advanced → recover with the **CLOSE-ONLY finisher**:
     `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_git_finish.py" --close-only --pr <pr> --issue <n> --repo "$PWD"`. It **skips** the merge
     (which already happened — the plain finisher would hard-fail at `gh pr merge`), verifies the
     merged state as its receipt, then runs the normal cleanup + tracker-close tail; it is idempotent.
   - `teammate-idle: <n> in-flight branch <b> ahead <k>` — the teammate went idle mid-work with `<k>`
     genuinely-unmerged commits → **re-dispatch / resume** from branch `<b>` (do NOT restart).
   - `teammate-idle: <n> no-evidence` — no local branch/commits — BUT a squash-merge that **deleted**
     its branch leaves no local ref, so this can be an already-landed item. **Before reclaiming**,
     check for a merged PR / a base-history commit referencing `#<n>`; if found, recover close-only as
     above — otherwise **reclaim / re-dispatch** the item.
   It is **fail-soft** (never halts the drain), **repo-gated**, and honors `IDC_HOOKS_OBSERVE_ONLY=1`
   as a dry run; a `teammate-idle: unknown` (unreadable board) is advisory — surface it, never as clean.
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
   claiming **only `Stage = Buildable`** issues — a `Consideration`/`Planning`/`Recirculation`
   ticket is never build work; the glass wall is enforced twice over (the drain helper's
   eligibility allowlist never surfaces one, and the transition engine refuses a `claim` on one as
   an illegal transition) — including waves unblocked mid-run from the operator's phone.
   Check the exit condition with the **same deterministic drain helper, by backend** — never
   improvise the predicate or read the board with a bare `gh project item-list` (it truncates at its
   30-item first page → a grown board blinds the lane):
   ```bash
   # filesystem — `--acceptance` also runs the wave-close acceptance check when the build lane is
   # drained (surfaces a Done-but-inert increment as `acceptance: gap <#s>`; file a recirculation on a gap).
   # A gap/error GATES the would-be-`complete` wave close (Stage E3): gap ⇒ `drain: acceptance-gap` exit 4
   # (recirculate the inert items), a corrupt/unrunnable check ⇒ `drain: unknown` exit 2 — both NON-terminal.
   # `--coherence` + `--live` are the two completion-honesty gates. Pass them on EVERY drain call, both
   # backends: an empty build lane was never proof the work was finished.
   #   --coherence  the board is a DASHBOARD and it can lie. The finish tail merges the PR — which
   #                auto-closes the issue via the mandated `Closes #N` — several steps before it flips
   #                the board, so a session dying in that window strands a SHIPPED item at `In Progress`
   #                forever. The drain counts only `Todo`, so it never saw those items and printed a
   #                clean terminal `complete` over them. Gap ⇒ `drain: coherence-gap` exit 4.
   #   --live       every other gate verifies code, not the running product. The project declares each
   #                live surface AND the `verify:` command that drives it; the drain AUDITS the receipt
   #                (read-only, executes nothing, so the stop path stays fast) while `idc:idc-build`'s
   #                wave close RUNS it. Gap ⇒ `drain: live-gap` exit 4, cured by
   #                `idc_live_check.py --repo "$PWD" --run`. A repo that declares no live surface
   #                reports `live: not-declared` — free, and nothing is ever executed.
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_autorun_drain.py" --tracker <TRACKER.md> --acceptance --coherence --live
   # github — pages the WHOLE board, same predicate (github wave-close acceptance runs in idc:idc-build Phase 4).
   # `--session-id` attributes the persisted drain verdict (.idc-drain-verdict.json) to THIS session so the
   # Stop fixpoint gate can read the github board conjunct locally (0 GraphQL on the stop path, v4 Phase 3
   # Stage E2); the drain also falls back to $CLAUDE_CODE_SESSION_ID if the flag is omitted. The two
   # completion-honesty gates ride here too — on github they are the ONLY path by which the Stop gate
   # learns about them, because that gate reads this persisted verdict rather than re-scanning the board.
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_autorun_drain.py" --backend github --project <n> --owner <o> --coherence --live --session-id "$CLAUDE_CODE_SESSION_ID"
   ```
   Both apply the identical Buildable-eligibility predicate — the drain helper is the predicate's
   single source of truth; never re-derive it in prose or by hand. On the github backend,
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
   (the board read succeeded but a build candidate's blocked-by lookup could not be verified — or, under
   `--acceptance`, the wave-close acceptance check was corrupt/unrunnable so the wave could not be proven
   clean), `drain: acceptance-gap` (exit 4, filesystem `--acceptance` — a merged-Done item is inert;
   recirculate it, do not stop), **`drain: coherence-gap`** (exit 4, `--coherence` — the named items
   SHIPPED but the board never advanced; repair each through the idempotent
   `idc_git_finish.py --close-only --pr <N> --issue <M>`, or `/idc:janitor --apply-safe` for the batch,
   then re-check — the check is safe to re-run), **`drain: live-gap`** (exit 4, `--live` — a declared
   live surface has no current passing verification; **run
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_live_check.py" --repo "$PWD" --run`**, which EXECUTES each
   declared surface's own `verify:` command and regenerates its evidence record from the real result.
   A non-zero exit is a **finding about the product, and it is yours to work**: read the captured output
   in the evidence record, fix it (or file it as a recirculation) exactly as you would a failing test,
   and re-run. Escalate to the operator ONLY when the pipeline genuinely cannot proceed — a surface
   declared `attested: true`, or a failure that needs a credential or permission no agent holds — and
   say which, never "go and check the app"), a hard
   board-read failure (exit 2, no `drain:` line), and
   `drain: rate-limited until <reset>` (exit 3, github only, #99 §C.3). Treat the lane as possibly-unfinished and let the next `/loop`
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
   Emit the exit report: recirculated, planned, admitted, built/merged, board state, **whether this
   run resumed a deliberately-paused one** (the `resume:` line from the preflight above), the
   **final working-tree state from a post-build `git status --porcelain`** (run it at exit, never a
   start-of-run snapshot — the build lane writes files mid-run, so a stale snapshot under-counts any
   uncommitted/untracked artifact), and anything waiting on the operator.

   **Close the command contract from the oracle, not from prose.** Call the read-only next-action
   oracle and finish the record; the final prose quotes the oracle's command/reason or states
   `waiting_gate`/`fixpoint` — never an invented handoff:
   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_next_action.py" --repo "$PWD" --json
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" finish \
     --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --command autorun \
     --status <complete|waiting_gate|blocked_external|paused> --evidence-json '<envelope>'
   ```
   - **`complete`** — **this session's** PERSISTED drain verdict (`.idc-drain-verdict.json`, written by
     `idc_autorun_drain.py --session-id "$CLAUDE_CODE_SESSION_ID"`) reads exactly `drain: complete`
     **and records the wave-close gates that prove it**. The validator reads that DURABLE artifact
     directly (session-scoped), so **no caller-supplied `drain` string clears it** — the evidence refs
     may be empty (`refs:{}`). So the drain that closes this run must have been invoked with
     `--session-id` for THIS session **AND with `--coherence --live`** (exactly as step 4 above spells
     it out for both backends). A bare `complete` token is NOT proof of completion: the gates are
     opt-in flags, so an ungated pass — including `idc:idc-build` Phase 0's `--width` frontier query,
     which overwrites this same file — persists an identical `complete` having verified nothing. The
     drain therefore records WHICH gates ran, and a `complete` that names none is refused here
     (`autorun-drain-ungated`) and does not clear the orchestrator marker at the Stop gate either.
     The cure is always the same: re-run the drain with the gates, then close.
   - **`waiting_gate`** — the oracle reports only human gates (an open Think PR / `[operator-action]`
     gate). Evidence refs: `gates:[<refs>]` (non-empty). The validator **re-runs the oracle** and
     refuses the claim unless it reports a human-gate wait as the live blocking state (no actionable
     pipeline work ahead of it) and every named gate is one of the oracle's live gates — a nonempty
     caller list alone is not proof, and a nonexistent/unreadable repo fails closed.
   - **`blocked_external`** — the drain reported `unknown`/`rate-limited`: `blocker:{helper, exit
     (nonzero), diagnostic}`. Report it as blocked, never as a drained run.
   - **`paused`** — this run was stopped by a deliberate `/idc:pause`, and
     `idc_pause_state.py close-open` is what closes it (never a hand-written `finish`). The
     validator re-derives the confirmed pause record **and** re-runs the quiescence check, so
     the status cannot be claimed by a run that merely stopped. Listed here because it IS a
     legal terminal for this command: an agent reading only this playbook could not otherwise
     discover the outcome its own lifecycle record can take.

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
