---
name: idc-build
description: 'IDC Build orchestrator — drives the impl→review→finish triplet (implementer · combined review agent · finisher) as one logical worker per ready-frontier issue, area-packs disjoint surfaces, serializes merges, and retriggers the acceptance gate continuously.'
---
# idc-build

The Build orchestrator playbook (`WORKFLOW.md §4.3`). Build is the only board-polled role. It
runs the explicit three-role **triplet** — **implementer** (`idc:idc-implementer`, the engine)
→ **reviewer** (the independent combined review agent — `idc:idc-review-engine`, run via
`idc:idc-review-coordinator`) → **finisher** (`idc:idc-finisher`) — as one logical worker per
parallel-safe issue. The three playbooks stay single-source (no per-runtime forks); the adapter
decides only how their **sessions** are realized, and collapsing the triplet into one sequential
session is the last-resort fallback only. Standard tier (the review agent runs reasoning tier).

## Phase 0 — Absorb the ready frontier

Build dispatches off the **whole-board ready frontier**, not a wave. Read the board through
`idc:idc-tracker-adapter` (`query`), then compute the ready set by **consuming** the wave-blind
readiness helper (consume, don't duplicate the predicate):
`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_autorun_drain.py" --tracker <TRACKER.md> --width`
(or the github-backend equivalent via `idc:idc-tracker-adapter` — materialize the same tracker
state to a tempfile and feed it the identical script, exactly as Phase 4 does for the acceptance
gate). It prints `eligible:` (the ready issue numbers) and, with `--width`, `width:` (the max-useful
parallelism). The helper computes **dependency-readiness only** — an issue is eligible when every
native `blocked_by` upstream is `Done`, **independent of `Wave`**: a later-wave issue whose blockers
are all `Done` enters the frontier in the same pass as an early-wave one. `width:` is therefore a
**ceiling**; the second half of "ready" — its **file surface is free** — is enforced on top by
area-packing (Phase 1), never by this helper. If the helper exits non-zero (a corrupt/partial board
— it fails **closed**, exit 2), **halt and surface it**; never hand-derive the frontier from the
`query` dump (that reintroduces the very predicate this consumes away). (PRD-gated items stay
`Blocked` until the operator approves — never force them; a `Stage = Consideration`/`Planning`
pointer is the glass wall and is never scooped as build work.) **Wave no longer gates dispatch** —
it is retained only as the acceptance gate's reporting scope (`--wave N`, Phase 4).

## Phase 1 — Dispatch the triplets (ready-frontier + area-packing)

**Item-id cache (github backend, once per wave).** Before staffing the wave's triplets, on the github
backend populate the wave-scoped item-id cache so every triplet's tracker mutation
(`claim`/`setField`/`close` via `idc:idc-tracker-adapter`) resolves the board item id from **one** board
read instead of re-downloading the whole board per mutation (design §C.1, RC4a — the O(waves×board) API
sink). Resolve `OWNER`/`PROJ` as the `idc:idc-tracker-github` preamble does, emit the map to an
orchestrator-scoped tempfile, and export it:

```bash
IDC_ITEMID_CACHE="$(mktemp -t idc-idmap.XXXXXX)"
if python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_gh_board.py" --owner "$OWNER" --project "$PROJ" \
     --emit-idmap > "$IDC_ITEMID_CACHE"; then export IDC_ITEMID_CACHE
else rm -f "$IDC_ITEMID_CACHE"; unset IDC_ITEMID_CACHE; fi   # read failed → fall back to live itemid reads
```

`itemid()` reads the cache when it is set; a cache **miss** (issue not in the table), an unset cache, or
an empty file falls back to a live board read, so a stale or unpopulated cache never mutates with a blank
id. Re-emit at the **top of each wave** (a fresh Plan mint changes the board). Filesystem-backend runs
skip this — it is a github-only optimization, transparent to the backend-blind adapter.

Dispatch one **triplet** per ready **area** — at most one in-flight worker per matrix-disjoint
surface area, each a sous-chef owning a ready issue whose **file surface is free** — an implementer
(`idc:idc-implementer`) feeding the reviewer feeding a finisher (`idc:idc-finisher`).
**Area-packing:** the matrix (`idc:idc-matrix-analysis`, via `idc_matrix_check.py` / `idc_dag.py`)
carves the whole board into disjoint surface **areas** (issue groups that never share a file
surface), so packing at most one in-flight worker per area means no two triplets ever touch the
same surface — **wave-independently**. Staff the ready frontier up to its `width:` ceiling, one
worker per free area. A **freed** sous chef immediately takes the **next ready area** (re-query the
frontier on every finish): the kitchen runs continuously instead of stalling at a wave barrier. The
adapter decides how the durable-worker sessions are realized (`idc:idc-adapter-claude` /
`idc:idc-adapter-codex` / the new **pi** runtime adapter):

- **pi** → standing **residents** (a pool of triplets, one resident per role);
- **Claude Teams** → **teammates**;
- **Codex** → app-server **threads**.

**Fallback-collapse rule:** collapse the triplet into one sequential session only as a
last-resort fallback — e.g., Claude with no team environment, or a single ready area — never
the Codex default. Each durable worker runs in a pre-created worktree (never the
`isolation:"worktree"` param). Never assign two triplets the same surface — the matrix carves
whole-board disjoint areas, so area-packing never collides even across waves.

## Phase 1b — Recirc events spawn the larger loop (per event, consultant-routed)

A triplet that surfaces a **recirc event** — out-of-boundary scope, a substrate gap, scope/menu
drift, or a `blocks_goal` deferral: anything Build is **not** resolving in-loop (see *Boundaries*) —
files the `Stage = Recirculation` ticket **and Build immediately hands it off.** Build spawns **one
fresh specialist recirc-consultant per recirc event**, realized through the runtime adapter
(`idc:idc-adapter-claude` / `idc:idc-adapter-codex` / **pi** — teammate / thread / resident, degrading
to a Task subagent or an inline pass where no durable worker exists), each running the Recirculator
playbook (`idc:idc-recirculator`) over its one ticket. The freed sous-chef does **not** block on it —
it pulls the next ready area, so the consultant runs **concurrently** with the still-flowing kitchen:
recirc is **immediate** (per event), the Plan re-sequence it may trigger is **batched** (below). Build
never performs the recirc analysis itself — the glass wall holds, the consultant is the authority that
reads PRD/TRD/codebase and touches docs; Build only **spawns** it and **routes** its result.

**The orchestrator is a dumb router: it dispatches on the consultant's validated closeout, it does
not re-derive the gate.** When the consultant finishes it returns a small machine-readable **closeout**
naming the next action. Build validates it **fail-closed** with
`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_recirc_closeout.py" --closeout <closeout.json>` and acts on
the single **structured JSON dispatch line** it prints — a JSON object routed on its `verb`, so a
control character / delimiter inside a scalar is JSON-escaped and can never spoof a token (no
whitespace line-protocol parsing). Build reasons about nothing:

- `{"verb":"launch-plan",…,"consideration":<ref>}` — the consultant **admitted a `Stage = Consideration`**
  (not gate-worthy). Build queues it; when consultants quiesce it launches **one batched Plan worker**
  (`idc:idc-plan`, via the adapter) over **all** pending admitted considerations — a single coherent
  global re-sequence, not one Plan run per consideration. Plan is unchanged — it only ever scans
  Considerations, never Recirculation tickets — and its global matrix re-sequence (`idc:idc-matrix-analysis`,
  `In Progress` immutable) re-points the original paused issue onto its real new unblockers, so the
  still-running kitchen picks the newly-buildable issues up on its normal freed-worker frontier
  re-query (Phase 1).
- `{"verb":"notify-gated",…,"think_pr":<ref>}` — the consultant opened a **gated Think PR** (a PRD/TRD
  change). Build fires the **cmux/push ping** the consultant requested and **parks** that work — **no**
  Plan worker; the ticket rides `Blocked` behind the gate until the operator approves. Build keeps
  building everything else; gated items are the only thing that needs the human.
- `{"verb":"grant-build",…,"issue":<n>,"paths":[<subordinate canonical-doc>],"change":<str>}` — the
  event was **trivial** (a no-gate, no-replan drift-heal of a subordinate artifact whose authority is
  already merged). The consultant grants Build permission for that **one specific** canonical-doc
  change — naming the exact `paths` **and** `change`; the triplet makes **only** that named change to
  those named paths as a **separate tiny doc PR through staging** (never folded into the code PR —
  clean provenance, same merge-train path), then resumes. At write time the granted paths are
  **realpath-resolved under the repo root** and the write confined to them (a path whose realpath
  escapes the repo, is a symlink to a non-doc, or falls outside the grant is rejected — the validator's
  scope check is the contract; Build's write is the enforcement). A recirc event that turns out
  *trivial* is a **smell** — usually the triplet's context was filling and it escalated something a
  fresh consultant sees through instantly; note it, don't suppress it.

If the helper exits non-zero (a malformed or **missing** closeout), **halt and surface it** — a
dropped handoff must never silently strand the ticket, the exact failure this loop exists to prevent.
The loop is **bounded** by the deterministic guard
`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_recirc_caps.py" --recirc-count <n> --cascade-depth <d>`,
consulted **before** spawning a consultant on an issue: a **per-issue recirc ceiling** (default 2) parks
a chronically-recirculating issue, and a **cascade-depth cap** (default 3) parks-and-reports a deep
recirc→build→recirc cascade. The caps only **decide** given counts (that decision is deterministic),
and the **closeout is the authoritative source of those counts** — every closeout carries validated
non-negative-integer `recirc_count` and `cascade_depth`, because the **recirc consultant is the
designated owner** that supplies them: it bumps the issue's `recirc_count` each time it processes a
recirc event for that issue, and stamps the `cascade-depth` a recirc-originated consideration carries
(inherited by its decomposed issues). For the **first** recirc on an issue (no prior closeout) the
counts read `0`/`0`; thereafter Build uses the most recent closeout's counts and stamps them on the
issue, so it never invents or skips them. So the bound holds **as long as that count is maintained** (a
future hardening can derive `recirc_count` from board state — counting the issue's `Stage = Recirculation`
tickets, incl. retired — to drop the dependence on the bump). On a `verdict: park` — or any
non-zero/uncomputable result, **fail-closed** — Build does **not** re-spawn the loop on that issue: it
sets it `Blocked` + an operator-action marker + a cmux/push ping and moves on, so the loop always
**drains or parks for the operator, never churns**. The whole loop adds **no orchestrator monitoring** — Build's existing freed-worker frontier
re-query (Phase 1) is the only poll; the consultant's closeout is the only nudge.

## Phase 2 — Review each PR

Each implementer's PR goes to the **reviewer**: the independent combined review agent
(`idc:idc-review-engine`, run via `idc:idc-review-coordinator`) — fresh-context specialist
fan-out → deduped, confidence-floored, fail-closed verdict (validated JSON). It finds *all*
issues including side issues. Test genuineness is enforced — a shallow/placeholder suite is a
`FAIL`.

## Phase 3 — Finish (the finisher owns fix + merge)

The **finisher** (`idc:idc-finisher`), not the implementer, owns fix-application and merge. Per
PR it runs its own `/fullauto-goal` loop over **all** reviewer findings (including side issues),
then `/simplify` (Claude; the adapter maps or skips it for Codex) and git finalization.
`FAIL`/`FAIL-BLOCKED` findings are fixed and re-reviewed until the verdict is
`PASS`/`PASS-WITH-NITS`; an unsolvable/upstream finding is kicked back via a recirculation
(`/idc:recirculate`). On a clean verdict the finisher merges, then closes the issue through
`idc:idc-tracker-adapter` (`close` → `Status=Done`).

**Merge serialization (no silent race) — the commutative disjoint-surface merge train.** Parallel
finishers must never race on the merge. Two layers guarantee it: (1) **matrix-disjoint areas** —
area-packing dispatches at most one worker per whole-board disjoint surface area, so diffs are
content-commutative regardless of `Wave`; (2) **a per-surface merge lock/queue** — the merge lane
no longer funnels every finisher through **one single global lease**; the lock/queue is **keyed by
the area's actual file surface** (the paths the diff touches, not an opaque area id), so each finisher
acquires only the **single-holder merge lease(s)** for the surfaces *its* diff touches — and because
the key *is* the file surface, **any two diffs that share even one path collide on the same lease and
serialize**. Two **disjoint-surface** areas therefore hold **distinct** lease names and merge
**concurrently** (the merge train) **without contending for one single global lease**, while **only
conflicting (overlapping) surfaces serialize** (layer 1 already makes overlap the exception, so this
is the second line, not the primary guarantee). Every named lease is still **fail-closed** (no lease
→ no merge; never a silent race) and serializes the **content** merge per surface; the shared-ref
*advance* never silently races either — one merger advances it serially on the single-merger
runtimes, and under pi's concurrent residents it is an **atomic fast-forward that rejects-and-retries
on a moved base** (git's non-fast-forward guard), so a stale-base merge fails closed and retries. The
global `merge` lease survives only as the degenerate case (the collapsed fallback, or a genuinely
shared infra surface that every area touches). The adapter realizes the per-surface lease — and the
train runs **genuinely concurrently only on pi's multi-resident pool**, while the **single-merger**
runtimes **collapse it to structural serialization** (disjoint areas merge back-to-back through one
merger): a **board-backed merge lease** (keyed per surface) in the flat **pi** standing pool (no
master orchestrator — the authoritative board is the lock-holder, where disjoint surfaces merge
concurrently); the single Build **orchestrator** as the sole **serial** merger under **Claude Teams**
/ the collapsed fallback (no teammate-finisher merges another's surface); the app-server's serial
merge under **Codex**.

**Mechanical conflicts deconflict in-kitchen — the build-time mechanical-deconfliction step (never
recirculate).** A purely **mechanical** conflict — an overlapping-file edit, a git-merge conflict, or
a worktree conflict the disjoint matrix should preclude — is resolved **on the kitchen floor**,
**in-place** by the area owner (the sous-chef) or its line cook, via a **bounded
mechanical-deconfliction specialist** (a Deconflict pass dispatched on demand, not an upstream hop):
rebase/retarget against staging, resolve the textual overlap, re-acquire the surface-keyed merge
lease, and re-run the area's tests. **Classify fail-closed first:** a clash counts as *purely
mechanical* **only** when it is a provable textual overlap with **both sides inside their declared
surfaces** and **no contract / acceptance / dependency / docs implication** — if that **cannot be
established**, the ambiguity is itself treated as a **scope/menu defect** and recirculates; an
ambiguous clash is **never silently merged** in-kitchen (a real undeclared dependency can *surface as*
an overlapping-file clash, and must not be papered over as a textual merge). **Bounded means
terminating:** the specialist is capped by the standard **attempt ceiling** (~3 failed hypotheses) and
an unresolvable mechanical conflict **halts with evidence** (a blocked-stop) — never an unbounded
in-kitchen retry, never a silent merge. A mechanical conflict **never** spawns a recirculation —
recirculation is the retrograde doc-sync path, and a textual merge clash is not a docs/plan problem.
Only if deconfliction surfaces a genuine **scope/menu defect** — the resolved work no longer fits the
plan, or an **undeclared real dependency that changes the plan** — does it escalate upstream to the
Recirculator (`/idc:recirculate`); the mechanical resolution itself stays in the kitchen.

**e2e layering (staging-default).** The merge train lands area diffs on a **staging** branch, not
straight to `main`. **By default only the staging branch runs the full observed e2e** — **once,
before `main`** — never one e2e per teammate worktree. e2e is the **long pole**: it is GitHub
**rate-limited** (~1000–5000 calls/hr), so parallelizing it across worktrees would multiply the
rate-limited cost; it is therefore **scheduled serialized** (one observed e2e at a time), which is
*why* the default is staging-only. Only under **large effort** does each teammate worktree run e2e
before merging to staging, after which staging deconflicts the merged areas and runs its **own final
e2e** before promotion to `main` (the per-worktree/staging split lives in `idc:idc-finisher`).

## Phase 4 — Acceptance retrigger (continuous + autowave)

Because the wave barrier is dissolved, the **dependency-aware acceptance check** retriggers at
**per-area finish** (each time an area's issue closes `Done`), at **convergence checkpoints** (when
the ready frontier drains to nothing actionable), and at wave-close — not only when a whole wave
finishes. At each retrigger run the full test suite once, then run the check as a **blocking** gate —
`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_acceptance_check.py" --tracker <TRACKER.md> --wave <N>`.
On the **github backend** there is no on-disk `TRACKER.md`, so feed the *same* script the same input
rather than a model judgement call: via `idc:idc-tracker-adapter`, `query` **all** `Status=Done`
issues (the whole board, not just wave N — the gate must see a cross-wave enabler to mark a deferral
met), read each one's comments (the `<!-- idc-deferral: {…} -->` markers the finisher posted via the
`comment` op), materialize them into the gate's `<!-- idc-tracker-state:begin -->` JSON block
(`{"issues":[{"number","status","wave","comments":[…]}]}`) in a temp file, and run
`idc_acceptance_check.py --tracker <tempfile> --wave <N>` over it — `--wave` scopes only which Done
issues are *reported*, never the enabler lookup. Identical logic, identical exit codes. On `acceptance: gap` the gate does **not** pass green: for each offending **Done-but-inert**
issue, auto-file a recirculation (`/idc:recirculate`) — re-open/re-sequence the enabling obligation
and link it `blocked-by` to its dependents — before dispatching any further ready area. Only on
`acceptance: ok` clean up the board state it touched and advance the acceptance-reporting wave.
Autowave is the default behavior, not a flag.

## Phase 5 — Phase close

At phase boundary, run one delta review over the phase via the review engine. Most findings are
filed as **new board issues** (non-blocking — phase close does not drive them to zero). But
**acceptance-class findings are blocking**: an `acceptance: gap` (a Done-but-inert increment — a
declared runtime/infra dependency or a `blocks_goal:true` deferral unmet) is driven to zero or
auto-recirculated before the phase closes, never filed as a passive follow-up. And because a run can
pause mid-phase, the dependency-aware acceptance check (Phase 4) runs at **every wave-close**, not
only at the phase boundary — so an inert Done is caught even if the phase never closes. At the phase
boundary itself the check also runs **unscoped** (no `--wave`, the whole board) as a backstop, so a
Done-but-inert issue with no/odd wave value — or one whose enabling deferral landed after its own
wave already closed — is still caught even though no single `--wave N` close would report it.

## Boundaries & halt

- Builders never edit canonical docs (PRD/spec/plans). If the implementation diverges from
  the pillar, or the pillar from upstream docs, file a recirculation (`/idc:recirculate`) and pause only
  the affected issue.
- **Build never originates tracker scope.** It `claim`s and `close`s board items through
  `idc:idc-tracker-adapter`, but never *mints* new scope: no raw `gh issue create` /
  `gh project item-add`, and never self-sets `Stage = Buildable` or `Wave` (Plan mints Buildables
  with provenance, Sequence/Plan own `Wave` — see `idc:idc-plan`). Anything Build discovers that it
  is **not** resolving in-loop becomes a **Recirculation ticket** (`Stage = Recirculation`, the
  five-field discovered-scope body — `Discovered`/`Area`/`Suggested-scope`/`Provenance`/`PRD-TRD-impact`),
  **never** an unstaged or `Stage = Buildable` board item: an unstaged item defaults to Buildable and
  would be scooped as build work, leaking unreviewed scope past the glass wall.
- **Boundary rule (no-punt vs. recirculate).** In-boundary incidental work needed to satisfy the
  contract is fixed **in-loop** (the no-punt rule). Anything else — new scope, an out-of-boundary
  surface, a pre-existing breakage, a `blocks_goal` deferral, or scope/menu drift — is routed out as a
  `Stage = Recirculation` ticket (the Recirculator drains the inbox via `/idc:recirculate`), never
  papered into source and never silently widened. (A purely mechanical conflict is the one exception
  that does **not** recirculate — it deconflicts in-kitchen; see *Mechanical conflicts deconflict
  in-kitchen* above.)
- Writes source + tests (via the triplet's implementer + finisher), review reports under
  `docs/workflow/code-reviews/`, and tracker status (claim/close). Halts and surfaces
  evidence on a tracker/gh failure the adapter raises, or an implementer/finisher blocked-stop.
- **No-ask invariant — the sanctioned stops above are exhaustive.** Build never asks the operator
  *how autonomous to be*, never re-confirms a scope already chosen, and never converts a deterministic
  `drain: continue` into a question. "Check in" means **report progress and keep building**, not
  stop-and-re-ask. Build **never calls `AskUserQuestion`** — the only human gates are the Think-PR
  (requirements admission) and the rare `operator-decision` strategic gate (`idc:idc-gate-issue`),
  each surfaced as a board state Build reports, never an improvised interactive prompt.
