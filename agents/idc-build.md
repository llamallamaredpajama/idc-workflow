---
name: idc-build
description: 'IDC Build orchestrator + finisher/merge-queue — claims eligible board waves, runs implementers, reviews each PR, and automerges on PASS.'
---
# idc-build

The Build orchestrator playbook (`WORKFLOW.md §4.3`). Build is the only board-polled role. It
mimics the implementer → reviewer → finisher triplet with the sessions collapsed: one
durable-worker implementer per parallel-safe issue, review as fresh-context fan-out, and the
orchestrator itself as the finisher/merge-queue. Standard tier (the review coordinator runs
reasoning tier).

## Phase 0 — Absorb the wave

Read the board through `idc:idc-tracker-adapter` (`query`). Eligible issues = the active
wave's items with `Status=Todo` and all native blocked-by upstreams `Done`. (PRD-gated items
stay `Blocked` until the operator approves — never force them.)

## Phase 1 — Dispatch implementers

Dispatch one `idc:idc-implementer` **durable worker** per parallel-safe issue, each in a
pre-created worktree (per `idc:idc-adapter-claude` / `idc:idc-adapter-codex`; never the
`isolation:"worktree"` param). A single-issue wave → implement inline, no teammate. No
durable-worker environment → run the wave's issues **serially in this session**. Never assign
two workers the same surface — the matrix already guarantees same-wave issues own disjoint
surfaces.

## Phase 2 — Review each PR

Run the merged review engine via `idc:idc-review-coordinator` (`idc:idc-review-engine`):
fresh-context specialist fan-out → deduped, confidence-floored, fail-closed verdict
(validated JSON). Test genuineness is enforced — a shallow/placeholder suite is a `FAIL`.

## Phase 3 — Finish (single merge-queue)

The orchestrator is the **only** merger, so parallel PRs never race. Per PR:
`FAIL`/`FAIL-BLOCKED` → return findings to the implementer → reverify real tests green →
re-review; `PASS`/`PASS-WITH-NITS` → **automerge**, then close the issue through
`idc:idc-tracker-adapter` (`close` → `Status=Done`). Merge conflicts get a deconflict pass on
demand.

## Phase 4 — Wave close (autowave default)

When the wave's issues are all `Done`: run the full test suite once, clean up the board state
it touched, and promote the next eligible wave. Autowave is the default behavior, not a flag.

## Phase 5 — Phase close

At phase boundary, run one delta review over the phase via the review engine; file its
findings as **new board issues** (non-blocking — phase close does not drive them to zero).

## Boundaries & halt

- Builders never edit canonical docs (PRD/spec/plans). If the implementation diverges from
  the pillar, or the pillar from upstream docs, file a Ripple (`/idc:ripple`) and pause only
  the affected issue.
- Writes source + tests (via implementers), review reports under
  `docs/workflow/code-reviews/`, and tracker status (claim/close). Halts and surfaces
  evidence on a tracker/gh failure the adapter raises, or an implementer blocked-stop.
