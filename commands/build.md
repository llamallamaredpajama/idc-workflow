---
description: IDC Build — execute goal-contract issues as goal loops, review via the merged engine, automerge on PASS
argument-hint: '[<issue-ref> | "scope summary"] [free-form notes]'
---

You are running `/idc:build`, the only board-polled stage of the IDC v2 pipeline. Operate as
the Build orchestrator driving the impl→review→finish **triplet**: read
`${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md` end-to-end, then execute its phases (absorb the
ready frontier → dispatch triplets → review each PR → finish → acceptance retrigger → phase close).

Operator input: `$ARGUMENTS` — an optional issue ref or scope summary; otherwise dispatch off the
whole-board ready frontier.

**This is where durable workers are used.** Dispatch one **triplet** per ready issue whose file
surface is free — area-packed off the whole-board ready frontier, one worker per matrix-disjoint
surface area (not per wave) — an `idc:idc-implementer` (the engine) feeding the reviewer feeding an
`idc:idc-finisher`. A freed sous chef immediately pulls the next ready area, so the kitchen runs
continuously instead of stalling at a wave barrier. The
adapter decides session realization: **pi** = standing residents, **Claude Teams** = teammates,
**Codex** = app-server threads; collapse to one sequential session only as a last-resort
fallback (a single ready area, no-team environments). The implementer executes its issue's goal
contract as a `/fullauto-goal` loop with auto-goal discipline — failing test first,
record-and-vary, evidence-before-assertion, the attempt ceiling, and the no-punt rule — then
hands off to review.

Each PR is reviewed by the independent combined review agent (`idc:idc-review-engine`, run via
`idc:idc-review-coordinator`) — fresh-context fan-out across the 13 dimensions, test genuineness
enforced. The **finisher** (not the implementer)
runs its own `/fullauto-goal` loop over all findings, then `/simplify` + git finalization, and
**automerges on `PASS`/`PASS-WITH-NITS`** → closes the issue via `idc:idc-tracker-adapter`.
Merges across parallel finishers are **serialized** (matrix-disjoint areas + a single merge
lock/queue — no silent race). The dependency-aware acceptance gate retriggers continuously — at
per-area finish, at convergence checkpoints, and at wave-close — running the full suite each time;
Wave survives only as that gate's reporting scope. Phase close files a delta review's findings as
non-blocking issues.

## Command lifecycle — verify at entry, close out through the oracle

The command entry gate opened this command's lifecycle record at expansion; verify it, and **close it
with a validated terminal status** before your final answer (the Stop closeout gate refuses a
walk-away from an open command):

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" status \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --json
```

Before the final answer, call the oracle and finish the contract; the final prose **quotes the
oracle's next command/reason**, never an improvised handoff:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_next_action.py" --repo "$PWD" --json
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" finish \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --command build \
  --status <complete|no_action|blocked_external> --evidence-json '<envelope>'
```

- **`complete`** — the requested issue receipts pass, or the whole ready frontier had no eligible
  requested item. Evidence refs: `receipts:{<issue>:{"pr":<merged-PR#>,"state":"MERGED"}}` (a
  **structured merged-PR reference per issue**, non-empty — not a bare receipt string), or
  `frontier:"none-eligible"` (**oracle-backed**: the validator re-reads the live ready frontier and
  refuses the claim unless there is genuinely no eligible Buildable).
- **`no_action`** — the **live oracle** reports no eligible Buildable work (its `eligible_buildables`
  count is 0). Never claim `no_action` without that fresh oracle result.
- **`blocked_external`** — an existing drain error or rate-limit receipt: `blocker:{helper, exit
  (nonzero), diagnostic}` (e.g. `idc_autorun_drain.py` exit 3 = github GraphQL rate-limited).

Builders never edit canonical docs — divergence files a recirculation (`/idc:recirculate`) and pauses
only the affected issue. The **one precise exception** is the consultant-authorized **`grant-build`
trivial** path: when a fresh recirc-consultant's validated closeout returns
`{"verb":"grant-build",…,"issue":N,"paths":[…subordinate canonical-doc…],"change":…}`, Build may make
that **one specific** named change (and only it) to the named subordinate canonical-doc file(s) as a
**separate tiny doc PR through staging** — never folded into the code PR, never broadened beyond the
authorized `paths`/`change`, and the paths are scope-checked by `idc_recirc_closeout.py` (a subordinate
doc under `docs/`, never a governing instruction surface). Every other canonical-doc divergence still
takes the recirculation path. Halt only on the conditions in the playbook. The retrograde path is
`/idc:recirculate`; the full-pipe drainer is `/idc:autorun`.
