---
description: IDC Recirculator — drain the Recirculation inbox or absorb a drift; autonomous doc-sync across the canonical chain (one PR), or reuse the one gate (a new gated Think PR) when requirements change
argument-hint: '[<drift-description | "scope summary">]   # omit to drain the Recirculation inbox'
---

You are running `/idc:recirculate`, the only retrograde path from Build back to the planning docs.
Operate as the Recirculator orchestrator **in this session**: read
`${CLAUDE_PLUGIN_ROOT}/agents/idc-recirculator.md` end-to-end, then execute its procedure (absorb
the drift → decide → sync or gate → close out).

## Two intake modes (additive — pick by `$ARGUMENTS`)

`/idc:recirculate` has two ways in; **both funnel each item through the identical decision flow**
below (`idc:idc-recirculator-sync` → `idc_recirculator_layers.py`). Mode is chosen by `$ARGUMENTS`:

- **Drift intake (operator/role-passed).** `$ARGUMENTS` carries a **scope/menu drift** description,
  a scope summary, or an **acceptance-gap** (a Done-but-inert increment the wave-close acceptance
  check flagged: a declared runtime/infra dependency or a `blocks_goal:true` deferral is unmet) —
  from Build, another role, or the operator. Process that one drift.
- **Board-scan inbox-drain (no `$ARGUMENTS`, or `--drain`).** **Enumerate every open
  `Stage=Recirculation` inbox ticket** on the board (`Status=Todo` — items already behind a gate or
  retired are skipped, so a re-run is idempotent) via `idc:idc-tracker-adapter` (`query`), then
  **drain each ticket** through the decision flow below. This is the inbox of scope **discovered
  mid-build** (filed as `Stage=Recirculation` tickets, the non-Buildable inbox); draining it admits
  that scope to the front of the pipeline so **Plan** (unchanged) later decomposes it. Autorun runs
  this mode at the top of the pipeline before the Buildable wave.

- **Reviewed intake unit (`<manifest>#<unit>`).** `$ARGUMENTS` may be a single external-intake
  reference `docs/workflow/intakes/<file>.json#<unit>` — accepted **only** for a unit whose `route`
  is `recirculate` (validate the manifest + its independent review first; reject any other route, and
  never build from a foreign plan). Process that **one** unit through the **identical** decision flow
  below — its `summary` + `dependencies` are the discovered scope. After it lands (an admitted
  consideration, a gated Think PR, or a paused ticket), **link the unit on the exact-once manifest**
  so the manifest is never left stale:
  ```bash
  python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_intake_manifest.py" link \
    --manifest "$MANIFEST" --unit "$UNIT" --state materialized \
    --target-ref "<recirc-ticket | consideration | gate>" --evidence "recirculate:<ref>"
  ```

The Recirculator's trigger is **narrowed to scope/menu (requirements/plan) drift**: a purely
**mechanical** conflict (an overlapping-file / git-merge / worktree clash) does **not** reach
here — it deconflicts **in-kitchen** via Build's **build-time mechanical-deconfliction step**; only
work that no longer fits the plan, or an undeclared real dependency that changes the plan,
recirculates.

## The decision flow (shared by both modes — do NOT duplicate it)

**Zero durable workers** — any analysis is bounded read-only fan-out per the runtime adapter.
For the drift, or for each enumerated `Stage=Recirculation` ticket (its five scope fields —
`Discovered / Area / Suggested-scope / Provenance / PRD-TRD-impact` — are the discovered scope),
use `idc:idc-recirculator-sync` to determine the highest affected canonical layer, the downstream
sync set, and the gate decision:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_recirculator_layers.py" <prd|spec|master|subphase|pillar> --config WORKFLOW-config.yaml
```

The helper reads the `gating:` toggle from `WORKFLOW-config.yaml`: the PRD always gates, and the
TRD (the `spec` layer) gates only when `gating.trd: on`. Two outcomes:

- **gate: no — not gate-worthy.** *Drift intake:* if no gated layer changes, update that layer and
  every layer below it — arch spec, master plan, subphases, pillars, affected open issues —
  **synchronized in one PR**, automerged, with the **PR body as the change order**. *Inbox-drain:*
  the discovered scope fits within today's requirements, so **admit it directly** — author a
  function-first **ADMITTED consideration** per `idc:idc-consideration-schema` (carrying the
  discovered scope), write its board pointer as `Stage=Consideration`, `Status=Todo` (admitted —
  *Todo*, distinct from Think's pending-admission-behind-a-gate pointer which rides `Blocked`), then
  **RETIRE the Recirculation ticket** via the engine's guarded `dispose --disposition drained` (the
  ticket's `idc-recirc-source` provenance is the receipt the guard verifies). **Preserve provenance**: a
  `discovered-scope` label on the consideration pointer (github) and an "originated as discovered
  scope (recirculation ticket #<n> — <Provenance>)" line in the consideration doc body, plus a
  closing comment on the retired ticket naming the consideration it became.
- **gate: yes — PRD/TRD-worthy.** A gated requirements layer changes (the PRD, or the TRD/`spec`
  layer when `gating.trd: on`): run the existing doc-sync to draft the requirements diff and
  **reuse the one gate** (`WORKFLOW.md §2`) via `idc:idc-gate-issue` — it opens a new gated **Think
  PR** carrying the requirements diff (blocked gate issue + plain-terms summary + push
  notification), the same admission Think fires. *Inbox-drain:* the `Stage=Recirculation` ticket
  **rides `Status=Blocked` behind that gate and PAUSES there** (it is not retired); admission clears
  the gate the same way Think's does. Pause only the affected work; everything else keeps flowing.

- **Trivial subordinate-artifact drift (Build-triggered).** When the only lagging layer is a
  subordinate machine-readable artifact whose authority is **already merged** (e.g. a stale enum
  mirror) and a running Build worker surfaced it, the consultant **grants Build permission** for that
  one specific change (a **separate tiny doc PR through staging**) instead of authoring its own PR —
  the glass wall holds because only the consultant authorizes the canonical-doc edit.

**Spawned by Build's larger loop?** Build spawns one fresh recirc-consultant **per** recirc event and
routes on its **structured closeout** — `pass-through` (admitted consideration → launch a batched
Plan worker), `gated` (Think PR opened → **cmux/push ping** + park, no Plan), or `trivial`
(grant-Build). The parent validates it **fail-closed** with
`${CLAUDE_PLUGIN_ROOT}/scripts/idc_recirc_closeout.py` (a malformed/absent closeout halts rather than
stranding the ticket); the mandatory `provenance` stamp rides every closeout.

## Kill-safe closeout — reconcile the checkpoint ledger when the drain finishes

The **board-scan inbox-drain** runs **in this (main) session**, so — unlike a Build-spawned
consultant — **no `SubagentStop` fires** and Stage C's closeout gate never sees it; a hard kill
fires no hook at all. So when the inbox-drain ends (or you finish this run), run the deterministic
reconciliation as the backstop — it checkpoints every still-open `Stage = Recirculation ∧ Todo`
ticket the drain did not dispose (a resume comment + a `recirc_checkpoint:<ticket>` taint) and clears
the taint for every ticket that left the inbox:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_recirc_reconcile.py" --repo "$PWD" --session-id "$CLAUDE_CODE_SESSION_ID"
# backend auto-detected from tracker-config.yaml; on github this is one cheap board read (best-effort)
```

It is **idempotent** (the taint is the latch — a re-run never duplicates a comment), **fail-soft**
(never breaks this command), and **repo-gated**. Autorun re-runs the same reconciliation at the top
of every pass, so a hard-killed drain is recovered on the next pass regardless.

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
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --command recirculate \
  --status <complete|waiting_gate> --evidence-json '<envelope>'
```

- **`complete`** — every requested ticket/unit has a valid closeout **and** the deterministic
  reconciliation re-derives as reconciled/complete. Evidence refs:
  `closeouts:{<ticket|unit>:<disposition>}`. The validator **re-runs the deterministic reconciliation
  read-only** and refuses the close unless the inbox re-derives as reconciled/complete — a caller
  `reconciliation:"ran"` string is **not** proof, and a nonexistent/unreadable repo fails closed. When
  the run was invoked on a NAMED item (`<manifest>#<unit>` or `#<ticket>`, recorded on the record at
  start), EVERY named item must carry a closeout whose disposition is **re-checked against durable
  state**: a `<manifest>#<unit>` closeout's disposition must **EQUAL** the durable manifest disposition
  (`materialized`/`verified_done`/`ignored` — never `queued`); a bare `#<ticket>` closeout's disposition
  gets a **per-ticket re-derivation from Stage + Status + the transition journal** (how the ticket
  reached its state). A non-terminal `gated`/`paused` requires the ticket **still open** (not Done). The
  only durably-distinguishable terminal is **`drained`** — the ticket reached Done through the guarded
  recirc-retirement door (`dispose --disposition drained`, journal-recorded, Stage still
  `Recirculation`). A **raw-closed Done** (no `dispose/drained` journal record) is refused, and
  `admitted`/`materialized` **cannot be told apart from a plain drained retirement on a bare Done ticket**
  so a mismatched terminal disposition is refused (rule B: an unreadable/undistinguishable truth is a
  refusal, never a pass). `closeouts:{}` is valid only for a bare full-inbox drain (no named item).
- **`waiting_gate`** — a valid requirements gate / Think PR is **open** (a gated backflow paused behind
  its gate). Evidence refs: `gate:<ref>` (and `think_pr:<N>` when the gate is a Think PR). The validator
  reads the referenced gate **for real** — a Think PR must read OPEN, a gate issue must be present and
  not Done on the CURRENT board; a nonexistent/closed gate is refused (a dead gate is not a wait).

Recirculate has **no `blocked_external`** terminal: its deterministic helpers write no durable failure
receipt and cannot be re-run read-only, so a blocked stop cannot be re-derived and is not claimable —
fix the failing helper or wait; never self-report a blocked stop as a completed terminal.

No verdict taxonomy, no change-order files — they are deleted; the PR body is the record. Do
not write source or tests; never admit a requirements (PRD/TRD) change without the gate; never
leave the doc chain half-updated (`WORKFLOW.md §4.4`).
