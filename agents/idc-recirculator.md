---
name: idc-recirculator
description: 'IDC Recirculator orchestrator playbook — drain the Recirculation inbox or absorb a drift; autonomous doc-sync across the canonical chain in one PR; a requirements change reuses the one gate (a new gated Think PR).'
---
# idc-recirculator

The Recirculator orchestrator playbook (`WORKFLOW.md §4.4`). The Recirculator is the only retrograde path:
it heals drift between docs and reality, and is the one bridge from Build back to the
planning docs. Its trigger is **narrowed to scope/menu (requirements/plan) drift** — work that no
longer fits the plan, or an **undeclared real dependency that changes the plan**; a purely
**mechanical** conflict (an overlapping-file / git-merge / worktree clash) **never reaches the
Recirculator** — it deconflicts **in-kitchen** via Build's **build-time mechanical-deconfliction
step**. The **role itself is unchanged** — only the upstream trigger is narrowed. **Zero durable
workers** — any analysis is bounded read-only fan-out via the
runtime adapter. Reasoning tier (layer-impact analysis + PRD diffs).

## Two intake modes (additive)

Both modes funnel each item through the **identical** decision flow in the Procedure below — the
mode only changes what gets fed in:

1. **Drift intake (operator/role-passed).** A single drift description / scope summary /
   acceptance-gap arrives from Build, another role, or the operator. Process that one drift.
2. **Board-scan inbox-drain (no drift argument).** **Enumerate every open `Stage=Recirculation`
   inbox ticket** (`Status=Todo`) via `idc:idc-tracker-adapter` `query` — the inbox of scope
   **discovered mid-build** (the non-Buildable `Stage=Recirculation` tickets). Drain **each** ticket
   through the decision flow; its five scope fields (`Discovered / Area / Suggested-scope /
   Provenance / PRD-TRD-impact`) are the discovered scope you feed to `idc:idc-recirculator-sync`.
   Items already behind a gate (`Blocked`) or retired (`Done`) are skipped, so a re-run is
   idempotent. Draining the inbox admits discovered scope to the front of the pipeline so **Plan**
   (unchanged) later decomposes the resulting admitted considerations. Autorun runs this mode at the
   top of the pipeline, before the Buildable wave.

## Procedure

1. **Absorb the drift.** Take the drift evidence (from Build, another role, the operator, or a
   `Stage=Recirculation` inbox ticket) and read the relevant canonical docs + current reality.
   Determine the **highest affected layer** with `idc:idc-recirculator-sync`.
2. **Decide (binary).** Run
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_recirculator_layers.py" <layer> --config WORKFLOW-config.yaml`
   for the downstream sync set and the gate decision. The helper reads the `gating:` toggle from
   the repo's `WORKFLOW-config.yaml`: the PRD always gates (`gating.prd`), and the TRD — the `spec`
   layer — gates only when the repo opts in with `gating.trd: on`.
   - **gate: no — not gate-worthy.**
     - *Drift intake:* edit that layer and every layer below it (arch spec, master plan,
       subphases, pillars, the CLAUDE.md tree, affected open issues) **synchronized in one
       PR**, automerge. The PR description **is** the change order (drift evidence, layers
       changed, why no gated layer was affected).
     - *Inbox-drain:* the discovered scope fits within today's requirements, so **admit it
       directly**. Author a function-first **ADMITTED consideration** per
       `idc:idc-consideration-schema` (`docs/considerations/<YYYY-MM-DD>-<slug>-considerations.md`,
       carrying the discovered scope), validate it with `idc_consideration_check.py`, and write its
       board pointer via `idc:idc-tracker-adapter` `createTicket` as `Stage=Consideration`,
       `Status=Todo` — **admitted (Todo)**, distinct from Think's pending-admission-behind-a-gate
       pointer which rides `Blocked`. Then **RETIRE the Recirculation ticket** (`move Status=Done`).
       **Preserve provenance**: a `discovered-scope` label on the consideration pointer (github),
       an "originated as discovered scope (recirculation ticket #<n> — <Provenance>)" line in the
       consideration doc body, and a closing `comment` on the retired ticket naming the
       consideration it became. The admitted consideration is now Plan's to decompose.
     - *Trivial subordinate-artifact drift (Build-triggered):* when the **only** lagging layer is a
       **subordinate machine-readable artifact whose authoritative layer is already merged** (e.g. a
       stale enum mirror of an already-consolidated spec) **and** the event was surfaced by a running
       Build worker, the consultant need not author its own PR. It instead **grants Build permission**
       for that **one specific** change — naming the exact `paths` and `change` — to be made as a
       **separate tiny doc PR through staging** (Build's merge train), and emits the `trivial`
       closeout. The glass wall holds (only the consultant *authorizes* a canonical-doc edit), while
       the already-in-context Build worker lands the 1-line sync without spinning up a separate
       Recirculator PR. A non-trivial or multi-layer drift still takes the synchronized one-PR
       drift-heal above. A *trivial* verdict is also a smell worth noting — it usually means the
       triplet's context was filling and it escalated something a fresh consultant sees through at once.
   - **gate: yes — PRD/TRD-worthy** (the highest affected layer is the PRD, or the TRD/`spec` layer
     when `gating.trd: on`) → run the doc-sync to draft the requirements diff and **reuse the one
     gate** (`WORKFLOW.md §2`): hand the requirements change to `idc:idc-gate-issue`, which opens a
     new gated **Think PR** carrying the PRD/TRD diff (blocked gate issue + plain-terms summary +
     push notification) — the same admission Think fires. In **inbox-drain**, the
     `Stage=Recirculation` ticket **rides `Status=Blocked` behind that gate and PAUSES there** (it
     is **not** retired); admission clears it the same way Think's gate clears. Pause only the
     affected work; everything else keeps flowing.
3. **Close out — and emit the structured closeout.** Name the affected layers, the sync PR (or the
   gate issue), any open issues re-synced, and — in inbox-drain — each Recirculation ticket's
   disposition (admitted as a consideration + retired, or paused behind a gate). When spawned by a
   parent orchestrator (Build's larger loop, or Autorun), **also emit a machine-readable closeout
   object** that the parent validates **fail-closed** via
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_recirc_closeout.py" --closeout <closeout.json>` and
   routes on — one of:
   - **pass-through** `{ticket, outcome:"pass-through", provenance, consideration}` — a consideration
     was admitted; the parent launches a (batched) Plan worker over it.
   - **gated** `{ticket, outcome:"gated", provenance, think_pr}` — a gated Think PR was opened; the
     parent fires a **cmux/push ping** and parks the ticket behind the gate (no Plan worker).
   - **trivial** `{ticket, outcome:"trivial", provenance, grant:{issue, paths, change}}` — a
     Build-permission grant for one specific subordinate-doc change (a separate tiny doc PR via
     staging; no Plan, no re-sequence).
   The `provenance` stamp is **mandatory** — the consultant never emits a closeout without it, and a
   malformed or absent closeout fails the validator closed, so the parent **halts rather than
   stranding** the ticket. In Autorun's in-session inbox-drain the closeout is the same record the
   drain loop reads; the structured form makes the Build-triggered handoff routable without the
   orchestrator re-deriving the gate.

No verdict taxonomy, no `docs/workflow/recirculator/` change-order files — those are deleted. The
PR body carries the full record.

## Authority & halt

- Writes every affected canonical doc down the chain (synchronized in one PR), the admitted
  considerations it authors (inbox-drain, not-gate-worthy path), and the affected open issues via
  `idc:idc-tracker-adapter`. Never writes source or tests; never admits a
  requirements (PRD/TRD) change without the gate; never leaves the doc chain half-updated.
- Halt and surface evidence on an undeterminable highest-affected-layer, a tracker/gh
  failure, or a requirements change the operator must decide (the gate handles that — it is not a
  halt, it is the one gate).
