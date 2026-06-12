---
name: idc-skill-filesystem-tracker-implementation
description: 'Use when an IDC tracker operation must read or mutate the filesystem-backed tracker.'
---
# idc:idc-skill-filesystem-tracker-implementation (QS-1)

Filesystem backend implementation of the portable Tracker interface. Pairs with `idc:idc-skill-github-tracker-implementation` (GitHub Projects V2 backend) under the dispatch surface `idc:idc-skill-tracker-adapter`. Per `WORKFLOW.md §6.2 Six core operations`, the filesystem backend wires the interface to a markdown TRACKER body — emitting a proposed new TRACKER body string given the current TRACKER body + a target-layout descriptor. Owns the bootstrap-fence preservation contract, 3-tier shape, lane-block syntax, and bookend-class refusal.

This skill is the surface that `tracker-config.yaml::backend = filesystem` resolves through. The adapter is the entry point; this skill is never called directly from an IDC role under the new dispatch model — always go through `idc:idc-skill-tracker-adapter` so backend swaps remain transparent. The legacy single-method emit surface (QS-1 wave-queue-edit) is preserved as the filesystem backend's implementation of `setField` / `move` / wave-queue mutations against the markdown TRACKER body. The actual disk write is to a scratch path (`output_path`); the caller (QR-4) hands the staged file to QR-5 for review and the parent `idc:idc-sequence` orchestrator commits.

Renamed from `idc-skill-tracker-wave-queue-edit` at OR-A3 of the tracker GitHub-migration governance pipeline. <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->

## When to invoke

- ONLY from inside `idc:idc-skill-tracker-adapter` after the adapter has resolved `<repo_root>/docs/workflow/tracker-config.yaml::backend` to `filesystem` — primary dispatch path under the new portable Tracker interface.
- Inside the orchestrator inline (substrate: `idc:idc-skill-filesystem-tracker-implementation` or `idc:idc-skill-github-tracker-implementation` via `idc:idc-skill-tracker-adapter`) Phase 3 — legacy primary use site (deep / janitor / fix-loop modes); preserved through the cutover so existing janitor flows keep working until Engineer's §Phase 5 cutover flips `tracker-config.yaml::backend` to `github`.
- Inside the `idc:idc-sequence` parent orchestrator's tracker-edit step when QR-4 is unavailable (degenerate fallback).
- NOT inside QR-5 — QR-5 reviews QS-1's output via QS-2; it never re-emits.
- NOT inside `idc:idc-build` — Build's TRACKER edits (bookend-close, `Currently building` non-`(idle)` updates) bypass this skill. Build writes TRACKER directly with its own bookend-close discipline.
- NEVER from inside an IDC role directly under the new dispatch model — those callers go through the adapter so the filesystem⇄github backend flip remains transparent.

## Input contract

| Field | Shape |
|-------|-------|
| `current_tracker_path` | absolute path to current `TRACKER.md` on disk (typically `<repo-root>/TRACKER.md`) |
| `target_layout` | structured descriptor (see "Target layout schema" below) |
| `mode` | `deep` \| `janitor` \| `fix-loop` |
| `output_path` | absolute path where the proposed TRACKER body is written (typically `<scratch_dir>/proposed-tracker.md`); must be a SCRATCH path (not `TRACKER.md` itself) |

### Target layout schema

```yaml
target_layout:
  bootstrap_header:
    preserve_verbatim: true   # MUST be true; load-bearing
    expected_first_line: "# Implementation Tracker"   # caller-asserts; skill validates
    expected_label: "Recently completed"   # the bootstrap-fence-pinned label
  active_phase_block:
    heading: "## Active Phase: <slug>"   # active-wave-stays-detailed-pinned
    fine_grained_tasks: [<list of T-numbered checkbox markdown lines>]
    pillars: [<list of pillar references with status checkboxes>]
  completed_milestone_block:
    heading: "## Recently completed"
    milestones: [<≤10 milestone-checkbox lines>]
  wave_queue_block:
    heading: "## Implementation Wave Queue"
    waves:
      - wave_id: "wave-1"
        purpose: <one line>
        pillars: [<pillar-trace-key>, ...]
      - wave_id: "wave-2"
        ...
    lane_block:
      - lane_id: "lane-1"
        lane_name: <slug>
        currently_building: "(idle)"   # ALWAYS (idle) — Build owns non-(idle); skill REFUSES non-(idle)
      - ...
  operator_actions_block:
    heading: "## Operator Actions"
    blocking: [<one-line BLOCKING entries>]
    side_jobs_count: <int>
  footer_pointers:
    preserve_verbatim: true   # caller asserts; skill copies as-is
```

## Output contract

- **Proposed TRACKER body written** to `output_path` — the full new TRACKER.md as one string. Caller (QR-4) reads back and stages.
- **Return packet:** `{output_path, byte_delta_summary, sections_changed[], bookend_class ∈ {bookend-open, pure-janitor, fix-loop-no-bookend}, bootstrap_fence_preserved: bool}`.

The skill does NOT write to `TRACKER.md` itself. Caller commits.

## Procedure

### Step 1 — Read current TRACKER

Read `current_tracker_path`. Parse into sections by H2 boundary scanning:
- **Bootstrap header** — lines 1 through the first `^---$` horizontal rule. Capture verbatim.
- **Active phase block** — `## Active Phase: ...` through next H2.
- **Completed milestones block** — `## Recently completed` through next H2.
- **Wave queue block** (if present) — `## Implementation Wave Queue` through next H2.
- **Operator actions block** — `## Operator Actions` through next H2.
- **Footer pointers** — everything after the last H2.

### Step 2 — Bootstrap-fence pre-validation (HALT-CLASS)

Validate:
1. First 30 lines of current TRACKER contain `target_layout.bootstrap_header.expected_first_line` (default: `# Implementation Tracker`). If not → halt with `BLOCKED: bootstrap_first_line_drift`.
2. First 30 lines contain `target_layout.bootstrap_header.expected_label` (default: `Recently completed`). If not → halt with `BLOCKED: bootstrap_label_drift`.
3. The bootstrap header ends with a closing `---` horizontal rule. If not → halt with `BLOCKED: bootstrap_closing_rule_missing`.

These three pre-checks ensure `tests/test_arch_tracker_bootstrap.py` will continue to pass after the emission.

### Step 3 — Bookend-class classification (REFUSAL gate)

Classify `target_layout` as bookend-open / pure-janitor / fix-loop-no-bookend:

| Condition | Classification |
|-----------|----------------|
| `mode=deep` AND new wave admitted (target_layout.wave_queue_block.waves contains a wave_id not in current TRACKER) | `bookend-open` |
| `mode=deep` AND active-pillar set transitions (a previously pending pillar moves to the lane block) | `bookend-open` |
| `mode=deep` AND first emission of `## Implementation Wave Queue` for this scope | `bookend-open` |
| `mode=janitor` | `pure-janitor` |
| `mode=fix-loop` | `fix-loop-no-bookend` |
| TARGET LAYOUT ASKS TO MARK A PILLAR `Currently building: <non-(idle)>` | **REFUSE** with `BLOCKED: bookend_close_attempted` (Build's authority) |
| TARGET LAYOUT ASKS TO STRIKE THROUGH A PILLAR (active → complete transition) | **REFUSE** with `BLOCKED: bookend_close_attempted` (Build's authority) |

Lane-block check: every `currently_building` value in `target_layout.wave_queue_block.lane_block` MUST be the literal string `(idle)`. Any other value → halt with `BLOCKED: bookend_close_attempted`.

### Step 4 — Emit proposed TRACKER body

Compose the new TRACKER body in this order:

1. **Bootstrap header (verbatim from current).** Copy lines 1 through the closing `---` horizontal rule of the current bootstrap header byte-for-byte. Do NOT modify, even if `target_layout.bootstrap_header` carries a different `expected_label` (the caller's expectations are validation hints, not edit instructions).

2. **Active phase block.** Compose from `target_layout.active_phase_block`:
   - Heading: `## Active Phase: <slug>` (verbatim).
   - Fine-grained tasks: emit each T-numbered checkbox line in declared order. Active-wave-stays-detailed rule — these stay expanded, never compacted to pointer-only.
   - Pillars: emit each pillar reference line.
   - Insert a single blank line between each sub-block.

3. **Completed milestone block** (if present in `target_layout`):
   - Heading: `## Recently completed`.
   - Milestones: ≤10 lines, one per milestone. Cap at 10 — if `target_layout.completed_milestone_block.milestones[]` has more than 10, halt with `BLOCKED: completed_milestones_exceed_cap` (caller must fold older milestones into the parent phase plan). The 5–10 range matches root `CLAUDE.md §Tracker Discipline` rolling-spotlight rules.

4. **Implementation Wave Queue block** (if present in `target_layout`):
   - Insert AFTER the closing `---` horizontal rule of the bootstrap header. NEVER before. (Validated by Step 2 + this placement step.)
   - Heading: `## Implementation Wave Queue`.
   - Per wave, emit:
     ```
     ### Wave <N> — <purpose>
     - <pillar-trace-key-1>
     - <pillar-trace-key-2>
     ```
   - Lane block at the end of the section:
     ```
     ### Lanes

     - **lane-1 (<lane-name>)** — `Currently building: (idle)`
     - **lane-2 (<lane-name>)** — `Currently building: (idle)`
     ```

5. **Operator Actions block** (preserve current OR apply target_layout updates):
   - Heading: `## Operator Actions`.
   - BLOCKING entries: one line each.
   - Side-jobs roll-up: `Side-jobs: <count>` line.

6. **Footer pointers** (verbatim from current). Preserve everything after the last H2 of the current body, byte-for-byte.

### Step 5 — Post-emission validation

Re-scan the emitted body and verify:
- First 30 lines byte-identical to current TRACKER's first 30 lines.
- "Recently completed" label appears in first 30 lines (or the canonical fence-named anchor).
- `## Implementation Wave Queue` (if present) appears AFTER the bootstrap closing `---` horizontal rule.
- Every `Currently building:` line in the lane block has value exactly `(idle)`.
- Active phase block has at least one T-numbered checkbox OR pillar reference (non-empty).

If ANY check fails → halt with the corresponding BLOCKED reason. Atomicity rule: do NOT write `output_path` if validation fails. Either the run produces a complete valid body, or it produces only a halt-stub.

### Step 6 — Write `output_path` + return

Write the validated body to `output_path` (scratch). Compute:
- `byte_delta_summary` — `<+N -M>` where N = bytes added, M = bytes removed vs current.
- `sections_changed[]` — list of section names where any line changed.
- `bookend_class` — from Step 3 classification.
- `bootstrap_fence_preserved` — `true` (always; halt would have fired otherwise).

Return the packet to the caller.

## Halt conditions

| Halt | Source step | Recovery hint |
|------|-------------|---------------|
| `BLOCKED: bootstrap_first_line_drift` | Step 2 | Caller checks current TRACKER's first line against expected; may be a stale fence anchor in the brief |
| `BLOCKED: bootstrap_label_drift` | Step 2 | Caller checks fence label; may need to update brief to match actual current label |
| `BLOCKED: bootstrap_closing_rule_missing` | Step 2 | Current TRACKER has no `^---$` after bootstrap; caller routes to Ripple to repair |
| `BLOCKED: bookend_close_attempted` | Step 3 | Caller is QR-4 in fix-loop mode mistakenly applying bookend-close fixes; Build's authority — refuse |
| `BLOCKED: completed_milestones_exceed_cap` | Step 4 sub-step 3 | Caller folds older milestones into parent phase plan; tries again with ≤10 |
| `BLOCKED: wave_queue_placement_invalid` | Step 5 | Target layout asks to insert wave queue before bootstrap horizontal rule; refuse |
| `BLOCKED: lane_block_non_idle` | Step 5 | Lane block has non-`(idle)` value; refuse (Build's authority) |
| `BLOCKED: active_phase_block_empty` | Step 5 | Active phase block has no T-numbered tasks AND no pillar refs; caller must populate |
| `BLOCKED: output_path_is_canonical` | Step 6 | `output_path` resolves to `TRACKER.md` itself; refuse — must be scratch |
| `BLOCKED: output_write_failed` | Step 6 | Permission / disk error |

## Banlist (load-bearing)

- **NEVER write to `TRACKER.md` directly.** `output_path` MUST be a scratch path (typically `<scratch_dir>/proposed-tracker.md`). The caller stages, reviewer reviews, parent commits.
- **NEVER emit a non-`(idle)` `Currently building:` value.** Build's authority. Refuse with halt.
- **NEVER emit a strikethrough or completed-checkbox-flip on an active pillar.** Bookend-close — Build's authority.
- **NEVER reorder or modify the bootstrap header.** First 30 lines are pinned by `tests/test_arch_tracker_bootstrap.py`. Byte-for-byte preservation is the contract.
- **NEVER insert `## Implementation Wave Queue` BEFORE the bootstrap closing horizontal rule.** Always after.
- **NEVER compact the active phase block to pointer-only.** Active-wave-stays-detailed.
- **NEVER omit the lane block when emitting `## Implementation Wave Queue`.** Lane block (`Currently building: (idle)` lines) is part of the wave-queue contract; QR-3 emits it at admit-time and this skill preserves verbatim across re-emissions.

## `promote_wave_status` op (filesystem fallback)

When the active backend is `filesystem` and Build's §Phase 4.5 next-wave rollover dispatches `promote_wave_status` through the adapter, the filesystem implementation runs an equivalent edit against the markdown `TRACKER.md ## Implementation Wave Queue` block. The op:

1. Reads `TRACKER.md` and locates the target wave's pillar rows under `### Wave <N> — <purpose>`.
2. Refuses if any item in the target wave has an open `blocks_on` upstream (mirrors the github backend's precondition; checked against the filesystem-recorded upstream references).
3. Flips each pillar row's `Status` column from `Pending` to `Active` — same byte-discipline rules as the rest of this skill (active-wave-stays-detailed; bootstrap-header verbatim; lane-block `(idle)` invariant).
4. Writes the proposed body to scratch `output_path`; the caller (Build) commits via the normal tracker-only commit flow (`tracker: promote Wave <N> Pending → Active`).

Filesystem is a local-only fallback for repos whose `tracker-config.yaml` selects it (`backend: github` is the primary first-class path). The op exists so the adapter contract is uniform across backends.

## `complete_claimed_item` op (filesystem fallback)

When the active backend is `filesystem` and Build dispatches `complete_claimed_item(issue, claim_handle)` through the adapter after a wave-completed item's PR has merged to main, the filesystem implementation runs an equivalent atomic single-row edit against the markdown `TRACKER.md ## Implementation Wave Queue` block. Canonical op envelope (mirrors the adapter registration in `idc:idc-skill-tracker-adapter/SKILL.md`): **atomically marks one wave-completed item Complete after Build's PR merges to main. Inputs: `issue`, `claim_handle`. Mutations: `Status: Active → Complete`, `ClaimState: → Released`, `Lane: → (idle)`, close issue. Idempotent. Refuses: no lane lock / PR not merged to main / Status=Pending.**

This op is **spec-only** at this skill-cycle — the deferred-implementation [ASSUMED] gap-resolution that applied to the github backend's `complete_claimed_item` applies identically here. Wire-up to a concrete filesystem row-edit primitive (and to `gh issue close` invocation, see Step 2 below) lands in a follow-on pillar.

### Step 1 — Pre-flight (read-only verification)

1. Load the tracker row for `issue` from the filesystem TRACKER source. On this backend the canonical layout is `TRACKER.md` itself — specifically, the per-pillar row(s) under the relevant `### Wave <N> — <purpose>` heading inside `## Implementation Wave Queue` (see "Target layout schema" → `wave_queue_block.waves[]`). If the project's filesystem layout has been extended to per-row files (none in current governed/sibling repos), the same row-load is performed against that path; resolve via `tracker-config.yaml` if a `row_layout` selector is added in a future cycle.
2. Verify `claim_handle` matches the lane-lock token recorded in the row's `Lane` field. The token is whatever opaque string Build wrote when it claimed the lane; equality is byte-exact. Mismatch → **refuse** with `BLOCKED: lane_lock_mismatch`.
3. For each linked PR / commit referenced in the row (typically a `PR:` / `Merge SHA:` annotation line under the pillar entry), verify reachability from `origin/main` via `git merge-base --is-ancestor <sha> origin/main`. Any non-reachable ref → **refuse** with `BLOCKED: pr_not_merged_to_main`.
4. If the row's `Status` is already `Complete` → short-circuit success (idempotent re-entry). Return the same packet shape an end-of-op success would emit, with `mutated: false`.
5. If the row's `Status` is `Pending` → **refuse** with `BLOCKED: status_pending` (Sequence's `Pending → Active` admission must run before completion is allowed).

All four refuse-cases are read-only — no mutation, no scratch write, halt-stub only.

### Step 2 — Mutation (single atomic file edit)

1. Rewrite the matched row to set `Status=Complete`, `ClaimState=Released`, `Lane=(idle)`. This is a single localized edit inside the wave-queue block — surrounding rows, the bootstrap header, the active phase block, the completed milestone block, the operator actions block, and the footer pointers are all preserved byte-for-byte (same byte-discipline rules as the rest of this skill; active-wave-stays-detailed, bootstrap-header verbatim, lane-block `(idle)` invariant).
2. Use the backend's existing row-edit primitive — the same single-section rewriter Step 4 of the main `Procedure` uses to emit the `## Implementation Wave Queue` block. Do not invent a new primitive; the wave-queue emitter already round-trips the row shape this op needs to mutate. The diff is scoped to the three fields on the target row.
3. **GitHub issue closure is decoupled on this backend.** Unlike the github backend (where issue state is the tracker), filesystem rows reference issues only by ID/URL annotation; closing the GitHub issue is not part of the row edit. If the project's `WORKFLOW.md §6` requires the issue to be closed on completion, the **caller** invokes `gh issue close <issue>` separately after this skill returns. This skill records the requirement in the return packet (`issue_close_required: bool`) but never shells out to `gh`.
4. Write the rewritten body to scratch `output_path` (NEVER to `TRACKER.md` itself — same atomicity rule as the rest of this skill: a complete valid body or only a halt-stub). The caller (Build) commits via the normal tracker-only commit flow (`tracker: complete <pillar-trace-key> (#<issue>)`).

### Halt additions for `complete_claimed_item`

| Halt | Source step | Recovery hint |
|------|-------------|---------------|
| `BLOCKED: lane_lock_mismatch` | Step 1 sub-step 2 | Caller passed wrong `claim_handle` for this row; verify Build's recorded lane token before retry |
| `BLOCKED: pr_not_merged_to_main` | Step 1 sub-step 3 | At least one linked PR/commit is not reachable from `origin/main`; merge first, then retry |
| `BLOCKED: status_pending` | Step 1 sub-step 5 | Row's Status=Pending; Sequence must admit (`Pending → Active`) before Build can complete |
| `BLOCKED: row_not_found` | Step 1 sub-step 1 | No row matched `issue` in the wave-queue block; caller passed wrong issue OR row was already removed (unexpected — investigate) |

## Authority boundaries

- Read+validate+emit-only on the filesystem TRACKER body — never commits, never mutates `TRACKER.md` directly (writes to scratch `output_path` only).
- Never mutates `docs/workflow/tracker-config.yaml::backend` outside the adapter's explicit `flip-to-filesystem` op surface.
- Never decides backend selection — the per-repo `tracker-config.yaml` is the source of truth; the adapter routes here only when `backend: filesystem`.
- Never spawns teammates.
- Never reads or writes canonical docs (PRD, master architectural spec, master implementation plan, subphase plans, pillar plans).

## Cross-references

- Adapter dispatch surface: `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-tracker-adapter/SKILL.md` (governance-pipeline edit; landed at OR-A1).
- Sibling backend (GitHub Projects V2): `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-github-tracker-implementation/SKILL.md` (NEW at OR-A2).
- Portable interface spec: `WORKFLOW.md §6 Tracker substrate` (six-method contract, project schema, label namespace, bookend mechanics, fail-closed posture, cutover runbook reference).
- Per-repo backend selector: `docs/workflow/tracker-config.yaml` (P1 — `backend: filesystem`; Engineer §Phase 5 cutover flips to `github`).
- Caller (legacy primary use site): the orchestrator inline (PR-5 fold; see substrate skills) Phase 3 (QR-4).
- Sibling reviewer skill: `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-plan-review/SKILL.md` (QS-2; reads QS-1's output).
- Bootstrap fence: `tests/test_arch_tracker_bootstrap.py` (canonical specification of first-30-lines + "Recently completed" label invariants).
- Lane-block authority matrix: `docs/workflow/CLAUDE.md §Per-lane Currently-building pointer` (Sequence emits `(idle)`; Build owns non-`(idle)`).
- Active-wave-stays-detailed: root `CLAUDE.md §Tracker Discipline`.
- Source plan: `docs/workflow/plans/workflow-changes/2026-05-08-tracker-github-migration-plan.md` (rename rationale at OR-A3 transactional batch).
- Source authority (legacy QS-1): `docs/workflow/audits/2026-05-07-idc-role-skill-coverage/per-role/sequence.md §QS-1`.

## Codex parity note

Codex sibling `codex-idc-sequence` invokes this skill identically — same input packet shape, same output proposed-body path. The bootstrap-fence preservation + 3-tier shape + bookend-class refusal are codex-runtime-agnostic. For Codex specifically: because the Skill tool resolves via each runtime's substrate catalog (Codex resolves bare names through the `~/.agents/skills` chain), a Codex parent calling `Skill(skill="idc-skill-filesystem-tracker-implementation", args="...")` (or going through `idc-skill-tracker-adapter` and resolving to this implementation) gets the same emission contract; the proposed-body path is then read by a Codex bounded subagent for QS-2 review. <!-- lint-allow: bare slugs by design — this sentence describes the Codex runtime, where idc: namespacing does not exist -->
