---
name: idc-build
description: 'IDC Build orchestrator — drives the impl→review→finish triplet (implementer · combined review agent · finisher) as one logical worker per issue, serializes merges, and closes the wave.'
---
# idc-build

The Build orchestrator playbook (`WORKFLOW.md §4.3`). Build is the only board-polled role. It
runs the explicit three-role **triplet** — **implementer** (`idc:idc-implementer`, the engine)
→ **reviewer** (the independent combined review agent — `idc:idc-review-engine`, run via
`idc:idc-review-coordinator`) → **finisher** (`idc:idc-finisher`) — as one logical worker per
parallel-safe issue. The three playbooks stay single-source (no per-runtime forks); the adapter
decides only how their **sessions** are realized, and collapsing the triplet into one sequential
session is the last-resort fallback only. Standard tier (the review agent runs reasoning tier).

## Phase 0 — Absorb the wave

Read the board through `idc:idc-tracker-adapter` (`query`). Eligible issues = the active
wave's items with `Status=Todo` and all native blocked-by upstreams `Done`. (PRD-gated items
stay `Blocked` until the operator approves — never force them.)

## Phase 1 — Dispatch the triplets

Dispatch one **triplet** per parallel-safe issue in the active wave — an implementer
(`idc:idc-implementer`) feeding the reviewer feeding a finisher (`idc:idc-finisher`). The
adapter decides how the durable-worker sessions are realized (`idc:idc-adapter-claude` /
`idc:idc-adapter-codex` / the new **pi** runtime adapter):

- **pi** → standing **residents** (a pool of triplets, one resident per role);
- **Claude Teams** → **teammates**;
- **Codex** → app-server **threads**.

**Fallback-collapse rule:** collapse the triplet into one sequential session only as a
last-resort fallback — e.g., Claude with no team environment, or a single-issue wave — never
the Codex default. Each durable worker runs in a pre-created worktree (never the
`isolation:"worktree"` param). Never assign two triplets the same surface — the matrix already
guarantees same-wave issues own disjoint surfaces.

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

**Merge serialization (no silent race).** Parallel finishers must never race on the merge. Two
layers guarantee it: (1) **matrix-disjoint surfaces** — same-wave issues own disjoint files, so
diffs are content-commutative; (2) **a single merge lock/queue** — exactly one finisher merges
the integration ref at a time under a **single-holder merge lease**, **fail-closed** (no lease →
no merge). The adapter realizes the lease: a **board-backed merge lease** in the flat **pi**
standing pool (no master orchestrator — the authoritative board is the lock-holder); the single
Build **orchestrator** as the sole merger under **Claude Teams** / the collapsed fallback (no
teammate-finisher merges another's surface); the app-server's serial merge under **Codex**.
The lease serializes only the integration-ref update, never content. Merge conflicts (which the
disjoint matrix should preclude) get a deconflict pass on demand.

## Phase 4 — Wave close (autowave default)

When the wave's issues are all `Done`: run the full test suite once, then run the
**dependency-aware acceptance check** as a **blocking** gate —
`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_acceptance_check.py" --tracker <TRACKER.md> --wave <N>`
(or the github-backend equivalent via `idc:idc-tracker-adapter`). On `acceptance: gap` the wave does
**not** close green: for each offending **Done-but-inert** issue, auto-file a recirculation
(`/idc:recirculate`) — re-open/re-sequence the enabling obligation and link it `blocked-by` to its
dependents — before doing anything else. Only on `acceptance: ok` clean up the board state it
touched and promote the next eligible wave. Autowave is the default behavior, not a flag.

## Phase 5 — Phase close

At phase boundary, run one delta review over the phase via the review engine; file its
findings as **new board issues** (non-blocking — phase close does not drive them to zero).

## Boundaries & halt

- Builders never edit canonical docs (PRD/spec/plans). If the implementation diverges from
  the pillar, or the pillar from upstream docs, file a recirculation (`/idc:recirculate`) and pause only
  the affected issue.
- Writes source + tests (via the triplet's implementer + finisher), review reports under
  `docs/workflow/code-reviews/`, and tracker status (claim/close). Halts and surfaces
  evidence on a tracker/gh failure the adapter raises, or an implementer/finisher blocked-stop.
- **No-ask invariant — the sanctioned stops above are exhaustive.** Build never asks the operator
  *how autonomous to be*, never re-confirms a scope already chosen, and never converts a deterministic
  `drain: continue` into a question. "Check in" means **report progress and keep building**, not
  stop-and-re-ask. Build **never calls `AskUserQuestion`** — the only human gate is the Think-PR
  (requirements admission), surfaced as a board state, never an improvised interactive prompt.
