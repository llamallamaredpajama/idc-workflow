# Phase 4 / U5 — prose-demotion batch log (issue #145)

Sweep of `commands/` `agents/` `skills/` for imperative control-flow prose whose enforcement now
exists in code (v4 deterministic-core plan §5, Phase 4 U5), executed 2026-07-07 on
`te-integration/phase4-2026-07-06`. Per-batch ablation gate: `bash scripts/lint-references.sh &&
bash tests/smoke/run-all.sh`, plus 2–3 representative governance engine tests under BOTH parsers
(default `python3` mini-yaml fallback AND `uv run --with pyyaml` for the real-PyYAML path).
Judgment knowledge (severity meanings, layer-impact thinking, disposition guidance, review
rubrics) stays; when in doubt the prose was demoted to a pointer rather than deleted.

Enforcement-map ground truth used for the "enforcing gate" citations below: the transition engine
(`scripts/idc_transition.py`), finisher receipt gate (`scripts/idc_git_finish.py`), Stop fixpoint
gate (`scripts/hooks/idc_stop_fixpoint_gate.py`), verdict gate (`scripts/hooks/idc_verdict_gate.py`),
autorun drain (`scripts/idc_autorun_drain.py`), janitor (`scripts/idc_git_janitor.py`), journal
replay (`scripts/idc_journal_replay.py`), recirc sweep (`scripts/idc_recirc_sweep.py`), board lint
(`scripts/idc_board_lint.py`, advisory), release gate (`scripts/idc_release_check.py`), reference
lint (`scripts/lint-references.sh` rules A–O).

**Deliberately NOT demoted (prose is the only guard, per the enforcement map):** the PreToolUse
terminal-action interlock ships warn-inject-only by default (`scripts/hooks/idc_interlock_gate.py`
hard-denies only under `IDC_HOOKS_INTERLOCK_ENFORCE=1`), so "route through the door" prose stays;
`retire`/non-Done terminal dispositions are a fail-closed engine stub (no code path exists — the
prose describes an unbuilt Phase-4 behavior); `idc_board_lint.py` reports and never gates;
`journal_append` is best-effort (fail-soft per plan §6) — divergence is caught after the fact, so
"is journaled" prose must not be read as a write-time guarantee; obligations-ledger taints are
hints, never independent blocks.

---

## Batch 1 — commands/janitor.md: four-dimensions + tier-criteria demotion (the Phase-0 deferred target)

**Files:** `commands/janitor.md`

**Prose removed (quoted):**

> "reconciles, from a **single board read + the merged-PR list**, board state against git reality
> across four dimensions — **worktrees**, **branches** (local + remote), **board↔issue↔PR
> coherence**, and **attribution** —"

> "**SAFE-FIX** — IDC-attributable (`idc-*`, `build*`, `plan/*`, `recirculate/*`, `worktree-*`)
> **AND** merged **AND** clean. The *only* tier `--apply-safe` touches: remove a clean merged
> worktree, delete a merged branch (local + remote), close a Done-but-open issue, set Status=Done
> on an issue whose work merged."

> "**REPORT-ONLY** — non-IDC artifacts (Codex / Antigravity / team-execute / claude / recovery
> debris)."

> "**RISKY** — dirty worktree, unmerged branch, or ambiguous attribution."

**Replaced with:** a pointer ("the dimensions it scans, the tier criteria … and the exact fix set
`--apply-safe` may touch are computed by the scanner — it is the source of truth; do not re-derive
them here") plus the intact tier→operator-disposition bullets.

**Enforcing gate:** `scripts/idc_git_janitor.py` — branch/worktree attribution + tier assignment
`classify_branch:498-523`, board↔issue↔PR coherence `board_coherence_verdict:271-289`, the
`--apply-safe` SAFE-FIX-only allowlist, single authoritative verdict rule `_VERDICT_EXIT:732`.

**Kept (judgment/disposition):** REPORT-ONLY "does not clean tooling it did not create"; RISKY
"one-by-one on explicit operator confirmation"; the exit-code interpretation rubric (0/1/2, "do
not treat a 2 as COHERENT"); the report/offer flow.

**Gate result:** GREEN — `lint-references.sh` CLEAN (34 files); `tests/smoke/run-all.sh` ALL GREEN;
governance `engine-machine-table` + `engine-illegal-transition` + `machine-yaml-crosscheck` PASS
under `uv run --with pyyaml` (real-PyYAML parser) in addition to run-all's python3 lane.

**Decision:** KEEP (batch committed).

---

## Batch 2 — the autorun pair: drain-predicate + fixpoint-enumeration demotion

**Files:** `agents/idc-autorun.md`, `commands/autorun.md`

**Prose removed (quoted):**

> "the **identical** eligibility predicate (`Status = Todo` AND `(stage or "Buildable") ==
> "Buildable"` AND the title is not `[operator-action]` AND every native blocked-by is `Done`)"
> — both files (agent step 4, command Build-lane step). Also the companion "An empty/missing
> `Stage` reads as `Buildable` (the legacy 4-field default)" restatement in both.

> "no `Stage = Recirculation` ticket remained, no approved consideration was unplanned, AND the
> drain predicate reported `drain: complete` (only Done items, requirements-gated Blocked items,
> the operator's gate issues, un-admitted considerations (open Think PRs), and any gated
> recirculation backflow left)" — agent step 5's fixpoint-condition enumeration.

> "(a `Consideration`/`Planning`/`Recirculation` ticket is never scooped — the glass wall)" —
> command Build-lane step, replaced with the two-gate citation.

**Replaced with:** "the drain helper is the predicate's single source of truth (never re-derive it
in prose or by hand)"; the fixpoint = "`drain: complete`" with a note that the drain verdict folds
in the top-of-pipe conjuncts (recirc inbox / unplanned approved consideration ⇒
`drain: recirc-pending`) and the Stop fixpoint gate deterministically backstops the stop; the glass
wall cited to its two enforcing gates (drain allowlist + engine claim refusal).

**Enforcing gates:** `scripts/idc_autorun_drain.py` — Buildable-only allowlist
`_is_build_candidate:178-189`, recirc-pending verdict `main:436-439`, fail-closed board reads
`load_filesystem:138-174`; `scripts/idc_transition.py` — claim on Recirculation/Consideration
refused `check_worked_state:265-272` + machine transition table (governance test
`engine-illegal-transition.sh` proves both refusals); `scripts/hooks/idc_stop_fixpoint_gate.py` —
board-pending ∧ ledger-pending block `_gate:348-360`, filesystem live drain re-run
`_board_says_pending:162-212`.

**Kept (judgment / only-guard, per the enforcement map):** the whole drain-exit taxonomy
(`unknown` / `acceptance-gap` / `rate-limited` semantics and "do not exit on a non-zero drain
exit") — the Stop gate hard-blocks only the board-pending (exit 4) case, so the exit-2/exit-3
resumable-pause prose is the only guard there; the 30-item pagination warning (a how-to trap, not
an enforced rule); the caps/parking + bounded-termination reasoning; the orchestrator_drain
marker-set block (live wiring the gate depends on); staffing/launch-gate posture.

**Gate result:** RED on first attempt, then GREEN (record-and-vary). The first gate run failed
`phase6-autorun.sh` — "autorun.md build-exclusion must name Consideration/Planning/Recirculation as
build-excluded" (the glass-wall demotion had dropped the stage enumeration the doctrine lock
requires in the COMMAND file). Fix: the enumeration was restored inside the demoted sentence ("a
`Consideration`/`Planning`/`Recirculation` ticket is never build work; the glass wall is enforced
twice over …"). Re-run: lint CLEAN (34 files); run-all ALL GREEN; governance
`stop-fixpoint-nonempty-inbox` + `drain-recirc-pending` + `engine-illegal-transition` green under
`uv run --with pyyaml`. Also caught this batch: the batch-1 gate invocation had piped run-all
through `tail -3`, masking its exit code — the gate command was fixed to fail loudly (batch 1 was
re-verified ALL GREEN from its full captured output; no bad batch slipped through).

**Decision:** KEEP (batch committed, with the enumeration-restoring iteration folded in).

---

## Batch 3 — the build triplet: receipt-gate enumeration, tail narration, close-on-verdict, Rule M

**Files:** `agents/idc-finisher.md`, `agents/idc-build.md`, `agents/idc-implementer.md`

**Prose removed (quoted):**

> "refuses to merge/close unless the review verdict for this PR/issue validates, is passing,
> **owns** the item, has every routable finding (each `minor`/`nit` + every deferral) **already
> routed to the board** by the filer, and has **no unmet `merge_conditions[]`**" — finisher git
> finalization, the verbatim enumeration of `enforce_receipt_gate`'s checks (plus the "#246→#248
> class" / "RC1/RC2/RC3" archaeology).

> "It then verifies the remote branch is actually gone (`git ls-remote`), deletes the local branch,
> closes the tracker (both halves) through the adapter's `close` op, and re-verifies the end state
> (PR merged, branches gone, worktree gone, Status=Done, issue closed) before ever exiting 0." —
> finisher, the step-by-step narration of the script's internal tail.

> "an issue is eligible when every native `blocked_by` upstream is `Done`" — build Phase 0, the
> one predicate-restating clause (the consume-don't-duplicate framing around it stays).

> "closes the issue through `idc:idc-tracker-adapter` (`close` → `Status=Done`)" — build Phase 3,
> replaced with the two-gate close citation.

> "so merging the PR never closes the issue (the audit found this on every checked PR)" —
> implementer hand-off, replaced by the Rule M lint citation.

**Enforcing gates:** `scripts/idc_git_finish.py` — `enforce_receipt_gate:565-604` (verdict
required/valid/passing/item-owned/pr-owned, routed-findings gap refusal, unmet `merge_conditions`
refusal), gated mutation order + fail-closed verifies `main:725-741`, `tracker_close:518-531`;
`scripts/idc_transition.py` — terminal close guard `check_close_guards:312-344`;
`scripts/idc_autorun_drain.py` — the `--width` readiness predicate; `scripts/lint-references.sh`
Rule M (backticked closing keyword) — governance/`finish-receipt-gate.sh`,
`engine-close-verdict-receipt.sh`, `engine-close-rejects-fail-verdict.sh` prove the close guards.

**Kept (judgment / test-locked / only-guard):** the role-authority partition incl. "refuses to fix
or merge an area that lacks an independent review verdict" (locked by
`phase4-sous-chef-ownership.sh` and it IS the judgment partition); the unrouted-deferral block
(the schema + routing judgment around the receipt-gate-enforced clause); worktree-first,
`--delete-branch`, and the not-GitHub-`--auto` caveats (test-locked operational traps, not
duplicated enforcement); "Build never originates tracker scope" + implementer's twin (the recirc
sweep only re-stages a rogue under an ACTIVE provenance regime and the PreToolUse interlock is
warn-only by default, so the prose remains the primary guard); the unbackticked-`Closes #<N>`
instruction itself (locked by `phase7-closing-keywords.sh`, demoted to carry the Rule M citation).

**Gate result:** GREEN (first run) — lint CLEAN (34 files); run-all ALL GREEN; governance
`finish-receipt-gate` + `engine-close-verdict-receipt` + `engine-close-rejects-fail-verdict` green
under `uv run --with pyyaml`.

**Decision:** KEEP (batch committed).

---

## Batch 4 — the tracker skills (#150 prose half): status-mutation recipes re-pointed at the engine

**Files:** `skills/idc-tracker-filesystem/SKILL.md`, `skills/idc-tracker-github/SKILL.md`,
`skills/idc-tracker-adapter/SKILL.md`

**Prose removed / re-pointed (quoted):**

> filesystem raw rows re-pointed to the engine: `set --num N --field {Status|…}` (Status variant),
> "`move --num N --status "In Progress"`", "claim `claim --num N --agent NAME`", "block
> `block --num N [--by M]`", "close `close --num N`" (verdict-backed case), "`link …`", and the
> claim-protocol sentence "A builder claims an issue by `claim --num N --agent <name>`".

> github ops re-pointed: "**move(ticket, status)** — convenience over `setField` for `Status`:
> `setField "$NUM" Status "$STATUS"`", "**claim(issue, agent)** — `move "$NUM" "In Progress"` +
> `comment …`", "**block(issue, by)** — `move "$NUM" Blocked` + `link …`", and close(issue)'s
> routing (verdict-backed case → engine `close --verdict --pr`; the `idc_gh_close.py` recipe kept
> as the mechanic the engine drives).

**Replaced with:** engine-first routing on both backends
(`idc_transition.py --backend {filesystem|github} …` for `create-ticket`/`claim`/`move`/`unblock`/
`close`/`link` — machine-legal, read-back-verified, journaled to
`docs/workflow/transition-journal.ndjson`), plus an adapter-level paragraph declaring
Status-changing ops engine-routed. Raw helpers explicitly scoped to reads, non-Status fields
(`Stage`/`Wave`/`Phase`/`Domain` — no engine op), and the **verdict-free operator paths** (gate
approval, pointer retirement, recirc-drain retirement), each annotated as KEEP-AS-RAW with the
engine gap named ("the engine's `retire` is deliberately fail-closed — Awaiting a non-Done
terminal disposition (Phase 4)") pending the #150 door design.

**Enforcing gates:** `scripts/idc_transition.py` — the op table + guards
(`validate_target:275-285`, `check_close_guards:312-344`, terminal guard-free refusal `:630-633`,
`verify_readback:223-233`, `journal_append:348-411`); `scripts/idc_git_janitor.py`
`--check-journal-divergence:827-893` (what un-journaled raw Status writes surface as); governance
`engine-github-move.sh` / `engine-github-close.sh` / `engine-github-link.sh` prove the github
engine path.

**Kept:** the whole github Preamble (paginating `board_json`/`itemid`/`optid`/`projnode` mechanics
— test-extracted and executed by `phase4-tracker-github-recipe.sh`), the `setField` guard block and
`idc_gh_close.py` close block byte-identical (same extraction coupling + they ARE the mechanics the
engine drives), the retire recipe + its hand-roll warning (test-locked; no engine op), the lease
primitives, `comment`/`query`/`show` (no engine ops), and the blocked-by REST mechanics.

**Gate result:** GREEN (first run) — lint CLEAN (34 files); run-all ALL GREEN (incl.
`phase4-tracker-github-recipe.sh` + `phase4-atomic-close.sh`, which extract and execute the kept
recipe blocks); governance `engine-github-move` + `engine-github-close` + `journal-append` green
under `uv run --with pyyaml`.

**Decision:** KEEP (batch committed).

---

## Full examination inventory — every shipped command/agent/skill file, examined once

Each file was read in full against the enforcement map (2026-07-07). Verdicts:

**commands/ (10):**
- `autorun.md` — demoted (Batch 2). Kept: drain-exit taxonomy (only-guard), marker-set wiring, janitor-preflight invocations, staffing/launch-gate posture.
- `build.md` — examined, KEEP. Thin launcher; the line-30 "automerges on PASS/PASS-WITH-NITS" is orientation, not enforced-rule duplication; the close behind it is engine/receipt-gated (cited in agents/idc-build.md instead).
- `doctor.md` — examined, KEEP. Rows ARE the gate surface (live read-only invocations + PASS/FAIL/SKIP interpretation rubric); nothing duplicated.
- `init.md` — examined, KEEP. Live scaffolding/provisioning orchestration; no gate supersedes it.
- `janitor.md` — demoted (Batch 1). Kept: tier→disposition guidance, exit-code rubric.
- `plan.md` — examined, KEEP. Thin launcher + boundaries; "In Progress immutable" is a delegated property statement (no code enforcer — `idc_matrix_check.py` does not check it).
- `recirculate.md` — examined, KEEP. Gate/no-gate decision flow is layer-impact judgment; helper invocations live.
- `think.md` — examined, KEEP. Describes the human gate (not a code gate) + live validation invocation.
- `uninstall.md` — examined, KEEP. Live receipt-driven removal orchestration.
- `update.md` — examined, KEEP. Live receipt-driven resync orchestration; the one board mutation is an idempotent helper invocation.

**agents/ (8):**
- `idc-autorun.md` — demoted (Batch 2). Kept: caps/parking + bounded-termination reasoning, no-ask invariant, rogue-sweep/reconcile invocations.
- `idc-build.md` — demoted (Batch 3: predicate clause, close-on-verdict citation). Kept: "Build never originates tracker scope" (the recirc sweep re-stages a rogue only under an ACTIVE provenance regime and the PreToolUse interlock is warn-only by default — prose remains the primary guard), consultant routing, merge train, area-packing doctrine (test-locked).
- `idc-finisher.md` — demoted (Batch 3: receipt-gate enumeration, tail narration). Kept: role-authority partition (test-locked judgment), deferral schema + routing, e2e layering, merge serialization.
- `idc-implementer.md` — demoted (Batch 3: Rule M citation replaces audit narration). Kept: "never originates tracker scope" twin (same primary-guard reasoning as build), goal-contract discipline, boundaries.
- `idc-plan.md` — examined, KEEP. Tool invocations + decomposition judgment; the paused-origin re-link is Plan's cognitive work (board lint only detects, never fixes).
- `idc-recirculator.md` — examined, KEEP. Layer-impact judgment; the closeout section is already in demoted advisory-pointer form ("checked by code on SubagentStop, not on trust").
- `idc-review-agent.md` — examined, KEEP. Review rubric (severity ladder, 0.8 floor, test-genuineness) is designated judgment; the verdict-gate description is already pointer-form.
- `idc-review-coordinator.md` — examined, KEEP. Same rubric character; filer enforcement already described as deterministic ("never by this agent").

**skills/ (13):**
- `idc-adapter-claude` / `idc-adapter-codex` / `idc-adapter-pi` — examined, KEEP. Runtime mechanics; no U5 gate family enforces them (pi's glass-wall ACL is enforced by coms-net, a different surface).
- `idc-consideration-schema` — examined, KEEP. Shape knowledge + delegated check (`idc_consideration_check.py`).
- `idc-gate-issue` — examined, KEEP. Operator-gate judgment; line-167 raw close is the verdict-free gate-approval door (KEEP-AS-RAW, engine gap on #150).
- `idc-goal-contract` — examined, KEEP. Authoring rubric; validation already a script pointer.
- `idc-matrix-analysis` — examined, KEEP. Deconfliction judgment; "In Progress immutable" is agent-applied (not code-enforced).
- `idc-recirculator-sync` — examined, KEEP. Layer-impact thinking; gate decision already delegated to `idc_recirculator_layers.py`.
- `idc-review-engine` — examined, KEEP. The canonical review rubric; validator already a pointer.
- `idc-schema-check` — examined, KEEP. Describes its own deterministic gate.
- `idc-tracker-adapter` — engine-routing paragraph added (Batch 4).
- `idc-tracker-filesystem` — re-pointed (Batch 4). Kept: lease mechanics, reads, atomic-write substrate knowledge.
- `idc-tracker-github` — re-pointed (Batch 4). Kept: paginating preamble, guard blocks, retire recipe (KEEP-AS-RAW), blocked-by REST mechanics, provisioning caveat.

## Closing state

- Batches: 4 run, 4 kept, 0 reverted; one in-batch red (Batch 2's build-exclusion doctrine lock)
  fixed by restoring the enumeration inside the demoted sentence.
- Final gate = Batch 4's gate (no shipped file changed after it): lint CLEAN (34 files), run-all
  ALL GREEN, both-parser governance spot checks green. This log file is the only post-gate change
  (docs/, not a shipped surface).
- WORKFLOW.md router semantics from Wave 1: untouched.
- #150 hand-back: the PROSE half is done here (adapter + both backend skills engine-first; every
  KEEP-AS-RAW door annotated in place). The CODE half remains on #150: journal the
  `idc_recirc_sweep.py` Stage stamp, design the non-verdict terminal op (gate approvals, pointer
  retirement, recirc-drain retirement), fix the rotation/append race (round-10 P2), then flip the
  janitor replay check default on and restore governance case 5's default-on assert.
