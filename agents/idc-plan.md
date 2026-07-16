---
name: idc-plan
description: 'IDC Plan orchestrator playbook — consideration → goal-contract issues on the board, in one zero-teammate run.'
---
# idc-plan

The Plan orchestrator playbook (`WORKFLOW.md §4.2`). Plan is **pure decomposition**: one run
scoops all admitted considerations — their PRD + TRD already authored and gated at the end of
Think — and produces **one** de-duplicated, deconflicted set of goal-contract issues on the board. Plan
**never authors the PRD/TRD and never gates**; that happened on the Think PR. **Zero durable
workers** — every fan-out is bounded read-only work through the runtime adapter
(`idc:idc-adapter-claude` / `idc:idc-adapter-codex`). Plan authors contracts (issue bodies); Build
only executes them. The two plan reviews are matrix deconfliction + the schema check — nothing else.

Run the phases in order; each phase's evidence gates the next.

## Phase 0 — Absorb (the whole pending set, not one)

- Scoop **every** admitted-but-undecomposed consideration — the full pending set, in one run, not
  one consideration at a time. Validate each one's shape with `idc:idc-consideration-schema`, and
  confirm each is **admitted** (its Think PR merged); an un-admitted consideration is not yet Plan's
  to decompose. While confirming, run the interrupted-run recovery (Plan does not gate — this only
  finishes a recovery the gate's own guarded close already validated): `query` `Status=Blocked`
  items and, for any whose blocking gate issue is already `Done`, **first verify that gate's
  journaled guarded dispose** — an `op=dispose`/`disposition=gate-approved` record naming it in
  `docs/workflow/transition-journal.ndjson` (+ its `journal-archive/` segments) — and only then
  finish the unblock through the engine's journaled `unblock`. A `Done` gate does NOT alone prove the
  guarded door ran (a raw/manual close or janitor repair also mints `Done`): if it is **not**
  journaled the `Done` is UNPROVEN — leave the dependent `Blocked` and surface it, never
  auto-unblock. A `Done` gate must never strand its dependents.
- Read each admitted consideration's requirements (the PRD + TRD) and the master plan, plus the live
  board through `idc:idc-tracker-adapter` (`query`) — including the open Buildable / in-flight
  issues. Note which issues are `In Progress` — they are immutable for the rest of the run.
- Resolve the repo's standing domains from `WORKFLOW-config.yaml::domains`; prune to the union of
  domains the pending considerations touch, adding ad-hoc ones as needed.

## Phase 0.5 — Batch dedup/deconflict assessment (one unified pass)

Before decomposing, run **one** read-only dedup/deconflict pass over the whole pending set so the run
yields a single, de-duplicated, deconflicted plan — not N independently-decomposed considerations
that re-plan each other's (or already-shipped) work. Hand the set to `idc:idc-matrix-analysis`'s
**batch dedup/deconflict pre-pass** (§0), which **fans out read-only workers** (the same bounded
fan-out the pairwise pillar clash uses — not a new mechanism) that compare each pending consideration
against:

- **(a) every other pending consideration** — cross-dedup: two considerations proposing the same or
  overlapping scope (merge them, or keep one and narrow the other).
- **(b) the open Buildable / in-flight issues** — already covered? Don't re-plan scope already on the
  board (or being built).
- **(c) the current codebase** — already done, or partially done? Drop already-shipped scope; narrow
  a partially-done consideration to the true remaining gap.

Absorb the digests, synthesize **one unified assessment**, and carry forward only the surviving,
de-duplicated scope (merges and drops recorded with their reason). This is a **quality** layer —
Phase 4's matrix already prevents same-wave *file* clashes; this pass removes the redundant,
overlapping, and already-done *work* (and scope drift) before a single line is decomposed.

## Phase 1 — Horizontal slice (domain experts)

Bounded fan-out of one read-only domain-expert per touched domain (reasoning tier), over the
surviving, de-duplicated considerations from Phase 0.5. Each returns, for its slice: what the
considerations require, what already exists, the gap, risks, and goal-shaped work items. The
orchestrator absorbs the digests, not full reasoning.

## Phase 2 — Draft the plan chain (decomposition)

The PRD + TRD are already authored and admitted (the merged Think PR) — Plan does **not** touch
them. Draft only the **plan layers** below the requirements: the master-plan section, subphase
plans, and pillar plans, each tracing back to the admitted PRD/TRD. Parallel drafting fan-out
**writes to disk and returns digests**; the orchestrator never absorbs full doc bodies. These
plan-chain layers are autonomous (no gate) and survive as files for traceability.

## Phase 3 — Author the goal contracts

Distill each pillar into a complete contract with `idc:idc-goal-contract`
(complexity-adaptive; real-functional-test verification surfaces). Templated emission of the
issue body from the authored contract is utility-tier; the contract authoring itself is
reasoning-tier.

## Phase 4 — Vertical slice (matrix)

Run `idc:idc-matrix-analysis`: pairwise clash fan-out → synthesize the phase matrix at
`docs/workflow/pillar-matrices/<phase-tag>-matrix.yaml` → re-sequence the board **globally**
against it (all not-`In Progress` items), assigning parallel-safe waves. Validate with
`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_matrix_check.py" <matrix>`. **Re-link paused origins:**
the same global re-sequence also re-points any **paused** issue whose recirc ticket was retired (its
scope admitted as one of the considerations now being decomposed — found via the consideration's
recorded paused-origin link) **off that retired ticket** and onto the consideration's **new unblocker
issues** (`blocked_by` the real new work), so it is **never left eligible behind a retired
recirculation ticket** — the premature-eligibility / infinite-recirc trap — and resurfaces naturally
only once its true unblockers land. A genuine upstream
contradiction that can't be deconflicted is parked and surfaced for a recirculation — never papered.
The consideration-level dedup/deconflict already ran in Phase 0.5; here the matrix handles
pillar-level *file* clashes among the surviving, de-duplicated pillars.

## Phase 5 — Validate + admit

1. Run `idc:idc-schema-check` on every issue body
   (`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_schema_check.py" <body>`); fix until PASS.
2. Create issues and set `Status`/`Wave`/`Phase`/`Domain` + native blocked-by through
   `idc:idc-tracker-adapter`. All issues flow as `Todo` — **there is no gate in Plan**; the
   requirements were already admitted at the end of Think. **Link each Buildable child back to its
   consideration pointer** through the **engine** (`idc_transition.py … link --parent <pointer>
   --child <buildable> --kind sub`) — the engine records the link durably (a journaled `idc-blocked-by`
   marker on github; native `blocked_by`/`parent` on filesystem). This is the **pointer-decomposition
   record** the engine's guarded `dispose --disposition retired` verifies (a named Buildable child that
   references the pointer) before it retires the pointer in step 3; without it the retirement is
   fail-closed. On the **github** backend, stamp each
   Buildable issue body with the provenance marker
   `<!-- idc-provenance: {"matrix":"<phase-tag>-matrix.yaml","pillar":"<id>"} -->`
   (`idc:idc-goal-contract`), carrying the **exact** `pillars[].id` from the matrix entry just
   authored in Phase 4 (the same value written to the matrix YAML, so the link is deterministic at
   source — no fuzzy `Trace:` matching downstream). Filesystem trackers have no issue bodies, so
   the stamp is github-only. **Provenance post-condition (github, DET-VERIFY):** once this run's
   Buildables are minted, run
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_provenance_check.py" --matrix <phase-tag>-matrix.yaml --issues <n1,n2,...>`
   — it re-reads each issue's LIVE body (not Plan's own belief of what it wrote) and confirms a
   valid marker naming a pillar actually in the matrix just authored. **Exit 0** confirms every
   minted Buildable is stamped; **exit 2 halts Plan** — it prints the offending issue numbers,
   which Plan re-stamps (`comment`/body edit through the adapter) and re-checks before continuing
   to step 3. Plan **cannot report Phase 5 done while this check fails** — a dropped stamp used to
   silently disarm the Recirculator's provenance regime (`idc_recirc_sweep.py`); this converts that
   gap from PROSE-ONLY to a verified post-condition.
3. Advance the consideration pointer `Consideration → Planning` through the **guarded Stage door**
   (the only sanctioned Stage-write — it validates the Stage/Status pair against the machine and
   journals the transition; a raw `set --field Stage` is denied by the mutation interlock):
   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_transition.py" --repo "$PWD" move \
     --num <pointer> --to-stage Planning --to-status Todo
   ```
   Then retire it via the engine's guarded `dispose --disposition retired` — a decomposition child as
   the receipt — as its buildable issues land; open the planning PR whose **body is the audit trail**
   (what was planned, the matrix,
   the trace) and **automerge when green** through the sanctioned finisher, which does a **direct,
   blocking** squash-merge and **deletes the merged branch as part of the merge** (no human
   touchpoint):
   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_pr_finish.py" autonomous \
     --repo "$PWD" --pr <planning-pr> --kind planning
   ```
   The finisher runs `gh pr merge --squash --delete-branch` **internally** (never a raw merge typed
   into the Bash tool — the mutation interlock denies that during an active command) and re-reads
   `state=MERGED`; the planning PR closes no tracker item, so this is the sanctioned door for it.
   It is **not** GitHub `--auto`: auto-merge defers the merge server-side and, with the repo's
   `deleteBranchOnMerge` off, would skip the branch delete and leave an orphaned `plan/*`. Branch
   deletion is **atomic with the merge**, not a separate best-effort step.

   **Advance a consumed intake unit's manifest disposition.** When a consideration being decomposed
   **originated from a reviewed external-intake unit** — its paused-origin / discovered-scope
   provenance names a `docs/workflow/intakes/<file>.json#<unit>` reference — record the decomposition
   on the exact-once manifest as its Buildables land, so the manifest never goes stale against the
   board. A recirculate-origin unit's class is `admitted_unplanned` / `discovered_drift`, so the
   manifest state machine's ONLY legal durable disposition for it is **`materialized`**
   (`verified_done` is reserved for `class=already_done` and the helper rejects it here). Recirculation
   already materialized the unit against its recirculation ticket; append the planning-PR evidence and
   keep it materialized:
   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_intake_manifest.py" link \
     --manifest "$MANIFEST" --unit "$UNIT" --state materialized --evidence "plan:<planning-pr>"
   ```
   A consideration with no intake provenance has no manifest to touch — skip this.
4. **Report the newly-created Buildable issue numbers on completion.** When this run was spawned by a
   parent orchestrator (Build's larger loop, or Autorun), Plan's closeout **reports the new Buildable
   issues** so the parent re-queries its ready frontier and the still-running kitchen picks up
   whatever is now open-to-build — the loop's pickup. This is the only handoff: **no monitoring**, the
   completion report *is* the nudge (Build already re-queries the frontier on every freed worker).
   Issues sequenced into a later wave simply wait; only open-to-build ones are claimed this session.

## Model tiers (resolved by the runtime adapter)

- `reasoning`: domain-expert synthesis, goal-contract authoring, clash/matrix judgment,
  sequencing decisions.
- `utility`: repo recon, research digestion, templated emission (issue bodies from
  contracts, matrix siblings, the PR description), board mechanics, the two checks.

## Authority & halt

- Writes `docs/plans/` (master + subphases + pillars), pillar matrices, and tracker issues.
  **Never** writes the PRD/TRD (Think authors + gates them), never source/tests, never reorders
  `In Progress`, never gates.
- Halt and surface evidence on: a consideration that fails the schema check or is not yet
  admitted (an open Think PR); an
  undeconflictable clash / upstream contradiction (park + recirculation); a tracker/gh failure the
  adapter surfaces; or missing input.
