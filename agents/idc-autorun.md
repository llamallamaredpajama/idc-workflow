---
name: idc-autorun
description: 'IDC Autorun orchestrator playbook — the one-shot two-lane drainer: plan every unplanned consideration, heal the board, build eligible waves, exit when nothing actionable remains.'
---
# idc-autorun

The Autorun orchestrator playbook (`WORKFLOW.md §4.5`). One shot traverses the whole pipe
top-to-bottom and exits when nothing actionable remains. It is the janitor — running it on a
quiet repo just heals board hygiene and drains stragglers. Standard tier (the autorun
parent). Loopable via `/loop /idc:autorun` for standing operation.

## Two lanes

- **Planning lane.** One plan-run durable worker per **approved, unplanned consideration**
  (parallel analysis/drafting via the runtime adapter), each running `idc:idc-plan` — which itself
  uses zero teammates (bounded fan-out only). Autorun only decomposes **approved** considerations:
  a consideration with an **open Think PR** (pending admission) is treated exactly like an open
  gate — **report + skip, never stall or bypass**. **Board admission is serialized through this
  parent** — only one consideration sequences against the live board at a time, so the global
  re-wave stays coherent.
- **Build lane.** Activates as soon as eligible issues exist and keeps claiming waves via
  `idc:idc-build`, including ones unblocked mid-run from the operator's phone (a requirements gate /
  Think PR approved during the run).

## The drain loop

1. **Find approved, unplanned considerations** by querying the board for `Stage = Consideration`
   pointer items (the one-stop index — no filesystem scan; the files under
   `docs/considerations/` stay the source of truth). Re-check open gates first (per
   `idc:idc-gate-issue`) in case the operator merged a Think PR mid-run. A pointer still
   **Blocked** behind its gate issue is an **open Think PR** (pending admission) — **report it and
   skip it**, never plan past it. For each **approved** (unblocked) one, dispatch a planning-lane
   worker; admit its issues one consideration at a time, and advance the pointer
   (`Consideration → Planning` while in flight, retired as buildable issues land). Skip this
   stage when there are none.
2. **Heal board hygiene in passing** — fix obvious board inconsistencies as you traverse
   (this is the auto `--fix`; `/idc:doctor` stays read-only).
3. **Build eligible waves.** Eligible build work is `Stage = Buildable` issues only — an
   upstream `Consideration`/`Planning` pointer is never scooped (the glass wall). Check the
   build lane's exit condition with
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_autorun_drain.py" --tracker <TRACKER.md>`
   (or the github-backend equivalent via `idc:idc-tracker-adapter`). While it reports
   `drain: continue`, run `idc:idc-build` on the eligible waves; re-check after each.
4. **Exit** when no approved considerations remain unplanned AND the drain predicate reports
   `drain: complete` — i.e. only Done items, requirements-gated Blocked items, the operator's gate
   issues, and un-admitted considerations (open Think PRs) are left. Emit the exit report:
   considerations planned, issues admitted, waves built/merged, board state, the **final
   working-tree state from a post-build `git status --porcelain`** (captured at exit, never a
   start-of-run snapshot — the build lane writes files mid-run, so a stale snapshot under-counts any
   uncommitted/untracked artifact), and anything waiting on the operator (the Think-PR requirements
   gate, incl. any open Think PR pending admission).

## Authority & halt

- Owns no canonical writes of its own — every cognitive write happens inside the `idc:idc-plan`
  and `idc:idc-build` runs it dispatches; it only orchestrates lanes, serializes admission,
  and heals board hygiene through `idc:idc-tracker-adapter`. Never edits the PRD/spec/plans or
  source directly.
- Halt and surface evidence on a blocked plan/build lane, a tracker/gh failure, or operator
  stop. A pending **Think-PR gate** (an open requirements admission, or a recirculation's gated
  backflow) is **not** a halt — it is the one gate; autorun reports it and exits clean.
- **No-ask invariant — these sanctioned stops are exhaustive.** Autorun never asks the operator
  *how autonomous to be*, never re-confirms a scope already chosen (typing `/idc:autorun` **is** the
  authorization to drain the whole repo), and never converts a deterministic `drain: continue` into a
  question. A request to "check in" means **report progress and keep draining**, not stop-and-re-ask.
  Autorun **never calls `AskUserQuestion`** — the one operator decision in the pipe is the Think-PR
  gate above, surfaced as a board state, never an improvised interactive prompt.
