# WORKFLOW.md — {{PROJECT_NAME}} IDC governance contract

> **This file is a hard contract.** Its existence marks the repo as IDC-governed,
> and its section numbers are **stable** so the IDC roles can cite governance rules
> by anchor (e.g. "WORKFLOW.md §4.2"). Keep the numbering stable when you edit.

This repository is governed by the full **IDC** chain — `Think → Plan → Sequence →
Build`, with `Ripple` handling drift. Each role is the sole writer of its own surface;
Ripple is the canonical-edit guard for cross-role drift. The chain runs on Claude-Teams
primitives (TeamCreate, SendMessage). The role slash surfaces are `/idc:think`,
`/idc:plan`, `/idc:sequence`, `/idc:build`, and `/idc:ripple`.

## 1. Canonical chain & document map

`Think → Plan → Sequence → Build`, with `Ripple` handling drift. Each role writes only
the surface listed here:

| Stage | Slash surface | Surface it writes |
|---|---|---|
| Think | `/idc:think` | `docs/considerations/` (pre-canonical) |
| Plan | `/idc:plan` | `docs/prd/`, `docs/specs/`, `docs/plans/`, `docs/plans/pillars/`, pillar matrices, planning manifest |
| Sequence | `/idc:sequence` | TRACKER ordering only |
| Build | `/idc:build` | source surfaces (per pillar `surfaces[]`), tests, `docs/workflow/operator-todos/`, status-only TRACKER bookends |
| Ripple | `/idc:ripple` | `docs/workflow/ripple/` change orders + gated canonical-doc PRs |

## 2. Tracker discipline

The tracker is selected by `backend:` in `docs/workflow/tracker-config.yaml` (the
full substrate contract — operations, schema, writer authority, bookend mechanics,
fail-closed posture — is **§6 Tracker substrate**):

- **`github`** — a GitHub Projects v2 board with eight custom fields. This repo's
  board is project number `{{TRACKER_PROJECT_NUMBER}}`, tracking work in the
  `{{GITHUB_OWNER}}/{{GITHUB_REPO}}` repository. A board item is a **candidate** when
  `Status="Active"` AND `ClaimState="Unclaimed"`, with `Phase` matching the active
  matrix phase-tag and `Pillar trace key` matching a matrix `pillar_id`. Values are
  read by name; field node IDs live in `tracker-config.yaml`.
- **`filesystem`** — a `TRACKER.md` file at the repo root. Zero external setup; good
  for getting started or for repos without a GitHub Project.

## 3. Pillar matrix & goal-recipe

Each build pillar declares its editable `surfaces[]` in the phase matrix under
`docs/workflow/pillar-matrices/`. Every build pillar plan body carries the five
goal-recipe markers: a failing test, the expected red, the minimal green, a refactor
step, and a stop-after-N-turns bound.

## 4. Role authority & forbidden writes

Each role is the sole writer of its surface. The boundaries below are load-bearing —
do not blur them.

### 4.1 Think
Pre-canonical only. Writes **only** `docs/considerations/`. Refuses source, test,
canonical-doc, and tracker writes; refuses admission or recommendation language
(admission belongs to Plan). Hands off active consideration files + open questions to
Plan.

### 4.2 Plan
Owns the PRD, architecture spec, master plan, canonical subphase plans, polished pillar
plans, per-pillar Resource Ownership tables, pair-wise clash evidence
(`docs/workflow/pillar-conflicts/`), and the phase-wide planning manifest
(`docs/workflow/phase-planning/`). Operates the **Engineer Gate**: operator approval is
required before drafting AND before merge for PRD / architecture-spec edits, and
pre-merge only for master-plan-only edits; subphase plans, pillar plans, ownership
tables, clash evidence, and the manifest are autonomous. If a clash proves the PRD,
architecture spec, or master plan is wrong, Plan files a Ripple — it never edits
upstream docs directly. Refuses source and test writes; refuses TRACKER sequencing;
refuses scope not traceable to an admitted upstream.

### 4.3 Sequence
Status / order overlay only — admits existing polished pillar plans to TRACKER order and
synthesizes the polished matrix YAML at
`docs/workflow/pillar-matrices/<phase-tag>-matrix.yaml`. Every TRACKER edit must cite an
existing plan-derived unit from a polished pillar plan; missing scope routes to Ripple or
Plan, never to TRACKER. Refuses scope invention (`scope_invention_denied`), non-idle Lane
writes (`non_idle_lane_write_denied`), admission without a polished-pillar reference
(`missing_polished_pillar_reference`), incomplete phase-wide admission
(`partial_phasewide_admission_denied`), and diff-gate violations (`diff_gate_rejected`).
Refuses PRD / spec / plan / pillar edits and all source and test writes.

### 4.4 Build
The only board-polled role. Implements the next admitted pillar against its goal-recipe,
obeying the diff-gate (`forbidden_glob_hit`, `outside_allowed_globs`, …). Writes source,
tests, implementation-PR artifacts, `docs/workflow/operator-todos/`, closeout artifacts,
and status-only TRACKER bookends. Does NOT edit the PRD, architecture spec, master plan,
subphase plans, or pillar plans. Exit gate: code review + tests + Ripple Audit; if the
implementation diverged from the pillar or the pillar diverged from upstream docs, Build
files Ripple and pauses affected work.

### 4.5 Ripple
Owns change orders under `docs/workflow/ripple/` and gated canonical / planning-doc PRs
after operator approval. Returns one of four verdicts per change order: `NO_RIPPLE |
MINOR_AUTONOMOUS | GATED | MAJOR_GATED`. Every decision declares the highest affected
layer, why higher layers do or do not change, and which downstream docs must be
synchronized in the same PR. Refuses source and test writes; refuses direct automatic
canonical edits; refuses PRD / architecture-spec edits without operator approval before
drafting and before merge.

## 5. Commit / PR conventions

Every commit carries the project's governance trailer, and PRs cite the TRACKER item or
change order they close. Never commit with `--no-verify`. If this repo has a
`CONVENTIONS.md`, its commit-trailer and PR-footer rules are authoritative.

## 6. Tracker substrate

Canonical specification of the **Tracker abstraction** that terminates the canonical
chain. Every tracker read or mutation routes through the dispatch surface
`idc:idc-skill-tracker-adapter`, which resolves the active backend from
`docs/workflow/tracker-config.yaml::backend` and routes to the matching implementation
skill (`idc:idc-skill-github-tracker-implementation` or
`idc:idc-skill-filesystem-tracker-implementation`). §2 is the operating summary; this
section is the contract those skills cite by anchor.

### 6.1 Backend selector (`tracker-config.yaml`)

Backend selection lives in `docs/workflow/tracker-config.yaml::backend`. Recognized
values: `github` (GitHub Projects v2 board; first-class) and `filesystem` (`TRACKER.md`
at the repo root; zero-setup local fallback). Per-repo configuration (project number,
cached field node IDs, Track-value allowlist) lives in the same file. Roles never
hard-code backend semantics — every call goes through the adapter.

### 6.2 Six core operations

The Tracker interface is exactly six operations. Adding a seventh or dropping one is a
contract change that requires a Ripple to admit.

| Operation | Signature | Meaning |
|---|---|---|
| `createTicket` | `(title, body, type, labels) → ticket_id` | New tracker item (GitHub issue + board item, or a `TRACKER.md` entry). |
| `setField` | `(ticket_id, field, value)` | Write one of the eight fields enumerated in §6.3. |
| `link` | `(parent_id, child_id, kind ∈ {sub, blocks})` | Sub-item or blocked-by relation. |
| `move` | `(ticket_id, status)` | Status transition (`Pending \| Active \| Blocked \| Complete`). |
| `query` | `(filter) → [ticket_id, …]` | Filtered item listing. |
| `comment` | `(ticket_id, body)` | Append a note to the item. |

**Operational ops.** The following surround the six core operations and ride the same
adapter dispatch: `export-state(--output <state.json>)` — emits a `{pillar_id: status}`
state file (string-keyed dict) for downstream tooling; `acquire-lane-lock(--lane=<lane>,
--ticket=<id>, --idempotency-key=<sha>)` — the atomic lane-lock primitive backing the
bookend-open transaction; `flip-to-filesystem(--reason=<text>, --audit-log=<path>)` —
operator-gated outage fallback (see §6.8).

### 6.3 Project schema (8 fields)

The GitHub backend's Projects v2 board carries exactly **eight** custom fields;
`tracker-config.yaml::field_ids` caches the GraphQL node IDs once provisioning
populates them.

| Field | Type | Purpose |
|-------|------|---------|
| `Status` | single-select (`Pending \| Active \| Blocked \| Complete`) | Tracker-state — Sequence-written by default; "where in the queue." Build writes Status only via the named carve-outs in §6.6. |
| `ClaimState` | single-select (`Unclaimed \| Claimed \| Running \| RetryQueued \| Released`) | Runtime claim-state — Build-written; "is a writer holding this right now." Sequence never writes ClaimState. |
| `Wave` | single-select (`Wave N` enumeration) | Implementation-wave overlay (per Sequence). |
| `Phase` | single-select (`Phase N` enumeration) | Master-plan §Phase trace. |
| `Track` | single-select | Cross-cutting workstream tag. **Operator-only** — values mutate via a Ripple change order; `tracker-config.yaml::track_values` is the enumerated source of truth. Sequence and Build never write Track. |
| `Lane` | single-select | Per-lane parallel-dispatch pointer (sole writer is Build per §6.7). |
| `Pillar trace key` | text | Polished pillar plan's filename stem (matches `pillars[].pillar_id` in the phase matrix). |
| `Domain` | single-select | Master-plan §Domain trace. |

**Enum extension SOP.** Wave / Phase / Domain are finite enumerations. When a new
phase, wave, or domain comes online, the field option MUST be pre-seeded (one
`gh project field-edit … --add-option <value>` per new value) BEFORE Sequence's TRACKER
admit attempts to set it — otherwise the write rejects because the option doesn't
exist. Skipping the pre-seed is the most common bootstrap-failure mode for a new phase.

**Label namespace.** Labels follow `phase:<N>`, `wave:<N>`, `lane:<name>`,
`domain:<name>`, plus `operator-action-blocking` (mirrors the BLOCKING operator-todo
surface), `bookend-open` / `bookend-close` (bookend lifecycle markers), `side-job`
(agent-doable-but-blocked side issues; open `side-job` issues block phase-close),
`attempt:1`–`attempt:5` (per-PR fix-loop attempt counter; see §6.5), and
`deferred_to_phase_close=<phase-tag>` (the §6.7 main-reachability deferral carve-out).

### 6.4 Claim-state vs tracker-state

Two fields, not one, because they answer different questions:

- **`Status ∈ {Pending, Active, Blocked, Complete}`** is *tracker-state* —
  Sequence-written; "where in the queue."
- **`ClaimState ∈ {Unclaimed, Claimed, Running, RetryQueued, Released}`** is
  *claim-state* — Build-written; "is a writer holding this right now."

Pairing: `Status=Pending` ↔ `ClaimState=Unclaimed`; `Status=Active` ↔ ClaimState
progresses `Claimed → Running` (and `Running → RetryQueued → Running` on per-PR
fix-loop retry); `Status=Complete` ↔ `ClaimState=Released`. Disagreement at
observation time (e.g. `Status=Complete` with `ClaimState=Running`) is a load-bearing
inconsistency that fail-closes Build dispatch. The lane pointer reads ClaimState, not
Status — `ClaimState ∈ {Claimed, Running}` is the "writer is holding this" signal.

### 6.5 Attempt counter on bookend-open

Per-PR fix-loop attempts are tracked on the item itself, not just in commit history:
(1) the bookend-open commit message carries `(attempt <n>)` — a new write packet after
a 3-attempt halt increments it; a same-packet retry does not; (2) Build's bookend-open
mutation sets the `attempt:<n>` label (single-valued — replaces any prior
`attempt:*`); (3) per-attempt review files get distinct names
(`docs/workflow/code-reviews/<YYYY-MM-DD>-pr-<N>-attempt-<n>-review.md`).

### 6.6 Writer authority matrix

Per-field writer authority for the eight §6.3 fields. This matrix is the single
source of truth.

| Field | Writer | Event | Invariant |
|---|---|---|---|
| `Status` | Sequence (default); Build (carve-out) | TRACKER admit / queue rollover (Sequence); `promote_next_eligible_wave` rollover + `complete_claimed_item` close (Build) | `Pending → Active → Complete` only; `Blocked` is operator-set out-of-band. **Carve-out:** Build is admitted as a Status writer for exactly two adapter ops — `promote_next_eligible_wave` (flip the lowest-numbered eligible Pending wave `Pending → Active` where `blocks_on` upstream is cleared AND the target phase has a matrix YAML present) and `complete_claimed_item` (`Active → Complete` for items Build claimed and merged in the current run only). **Sequence retains:** initial `Pending → Active` admission for items Build did not claim, retroactive corrections, and janitor `Active → Complete` for items Build did not claim. |
| `ClaimState` | Build (sole) | bookend-open / fix-loop / bookend-close | `Unclaimed → Claimed → Running → Released` happy path; `Running → RetryQueued → Running` on per-PR fix-loop retry. |
| `Lane` | Build (sole) | bookend-open / bookend-close | `(idle) ↔ <pillar-trace-key>` only; one non-`(idle)` per lane at a time. |
| `Pillar trace key` | Sequence | TRACKER admit | Locked post-emit; matches `pillars[].pillar_id` in the phase matrix. |
| `Wave` | Sequence | TRACKER admit | Matches the wave column in the phase matrix. |
| `Phase` | Sequence | TRACKER admit | Matches master-plan §Phase trace. |
| `Domain` | Sequence | TRACKER admit | Matches master-plan §Domain trace. |
| `Track` | Operator (Ripple-governed) | Ripple change order | Values enumerated in `tracker-config.yaml::track_values`; agents never write it. |

Build is the sole writer of the in-flight pair (`ClaimState` / `Lane`) and the named
exception writer for `Status` (the two carve-out ops above); Sequence writes the rest
of the queue layer; `Track` is operator-only.

### 6.7 Lane pointer + bookend mechanics

**Per-lane pointer.** Each active lane (one worktree OR one orchestrator session)
carries a single `Currently building` pointer — the polished pillar plan's filename
stem, or `(idle)` — stored in the `Lane` field (filesystem backend: the lane block in
`TRACKER.md`). Sequence emits `(idle)` lane blocks at admit; Build is the sole
non-`(idle)` writer (sets on bookend-open dispatch, clears on bookend-close PR merge).
Each lane has at most one non-`(idle)` pointer at any moment; multiple lanes may carry
non-`(idle)` pointers simultaneously (parallel-safe).

**Bookend events.** Bookend events resolve through the configured adapter. Filesystem
backend: commits with the `tracker:` prefix that update `TRACKER.md`. GitHub backend:
label/state mutations — open sets `ClaimState=Claimed` then `Running`, adds
`bookend-open` + `attempt:<n>` labels, sets `Lane=<lane>`; close routes through the
adapter's `complete_claimed_item` op, which verifies and applies one mutation set —
`Status=Complete`, `ClaimState=Released`, `Lane=(idle)`, issue closed — then removes
`bookend-open` and adds `bookend-close`. That `Status=Complete` write is exactly the
§6.6 Build carve-out; every other Status mutation belongs to Sequence at admit (or to
Build's `promote_next_eligible_wave` carve-out at queue rollover) — never to ad-hoc
bookend writes outside `complete_claimed_item`. Each side
of the bookend ends with verify-after-write reconciliation: read back the item state
and confirm the writes applied; on divergence, emit a reconciliation report under
`docs/workflow/audits/`, release the lock, and fail closed.

**Main-reachability invariant (deferral carve-out).** Before setting
`ClaimState=Released`, Build MUST verify the close-SHA is reachable from `origin/main`
(`git merge-base --is-ancestor <sha> origin/main`). For mid-phase waves where the
session PR is deferred to phase-close, the check may pass with a recorded
`deferred_to_phase_close=<phase-tag>` annotation on the tracker item. The annotation
MUST clear (i.e. the SHAs MUST become main-reachable) before any sibling wave whose
`blocks_on` references this item promotes to Active, and no later than phase-close.

### 6.8 Fail-closed posture + flip-to-filesystem

On backend failure (CLI exit code ≠ 0, GraphQL error, network timeout) the adapter:

1. Emits a structured failure event to the run ledger with the failing operation and
   raw error.
2. Refuses dispatch (returns non-zero so Build halts before any source-code commit).
3. Surfaces an operator decision: continue waiting, or invoke the explicit
   `flip-to-filesystem` op, which writes an audit-log entry, mutates
   `tracker-config.yaml::backend` from `github` to `filesystem` for the duration of
   the outage, and re-runs the dispatch-check via the filesystem adapter against the
   most recent `<state.json>` cached on disk.
4. Records the eventual flip back to `backend: github` after recovery as a paired
   audit-log entry. Backend cutover in either direction is operator-gated and
   audit-logged — never automatic.
