---
name: idc-build-runbook
description: Worker-loaded runbook for the IDC Build flow. Loaded by downstream teammates (idc:idc-role-issue-implementer, idc:idc-role-integration-verifier, idc:idc-role-phase-close-adversarial-reviewer) and read on demand by the parent trampoline (${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md) when it hits a step that needs detail. The parent never absorbs this runbook body into its own context.
---

# IDC Build runbook

This runbook is the guardrails-not-train-tracks playbook for the IDC Build flow. It is loaded by downstream teammates — `idc:idc-role-issue-implementer`, `idc:idc-role-integration-verifier`, `idc:idc-role-phase-close-adversarial-reviewer` — and read on demand by the parent trampoline (`${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md`) when it hits a step that needs detail. **The parent reads telegrams (≤8 lines), ledger headers, and ≤50-line teammate summaries only; it never absorbs runbook detail into the orchestrator context.** Detail lives here so the orchestrator stays lean and the implementers stay autonomous.

Per-file responsibilities boundary:

- The parent trampoline (`idc-build.md`) executes the Phase 0 preflight + bootstrap-spawn ritual, materializes per-issue worktrees inline, spawns N issue-implementer teammates in parallel, and routes from their compact telegrams.
- This runbook holds the substrate detail: bookend protocol, matrix dispatch-check CLI, per-issue brief schema, `/goal` recipe template, per-PR ceremony, tracker state-transition writes, phase-close adversarial gate, worktree mandate, handoff schema, resume mode, halt conditions, anti-patterns, doctrine notes.
- Per-roleplayer files (`${CLAUDE_PLUGIN_ROOT}/agents/idc-role-issue-implementer.md`, `${CLAUDE_PLUGIN_ROOT}/agents/idc-role-bootstrap-researcher.md`, `${CLAUDE_PLUGIN_ROOT}/agents/idc-role-merge-deconflictor.md`, `${CLAUDE_PLUGIN_ROOT}/agents/idc-role-integration-verifier.md`, `${CLAUDE_PLUGIN_ROOT}/agents/idc-role-phase-close-adversarial-reviewer.md`) hold the per-role brief shape and skill-invocation contract; they reference this runbook for cross-cutting protocols.

## Bookend protocol

Build writes pillar **claim-state** transitions to the Tracker per pillar dispatch cycle. `ClaimState` carries the runtime claim (Build-only writer; `Unclaimed | Claimed | Running | RetryQueued | Released`) separately from `Status`'s queue-state meaning (Sequence-written for admission / queue rollover / `Active → Complete` — "where in the queue"). Build's only Status write is the narrow next-wave-rollover carve-out documented in §Phase 4.5 — Next-wave rollover; every other Status mutation stays on Sequence's writer surface per `WORKFLOW.md §6.6 Writer authority matrix`.

On the **GitHub backend** (canonical) the writes are GitHub Projects V2 mutations via `gh` CLI. On the **filesystem-backend fallback** they are equivalent edits to `TRACKER.md ## Implementation Wave Queue`. Both routes are wrapped by `idc:idc-skill-tracker-adapter` per the canonical Tracker contract; never call `gh project item-edit` or edit `TRACKER.md` directly from this flow.

### Bookend-open commit shape

Issued in the same logical operation as the `ClaimState = Claimed → Running` transition. The commit message includes the current attempt counter, the `attempt:<n>` label is set on the issue alongside `bookend-open`, and the body documents the dispatched pillar / packet:

```
tracker: open Phase <N> Stage <M> bookend (attempt <n>)

- Pillar: <pillar-trace-key>
- Issue: #<issue-num>
- Wave: <N>
- Lane: <lane-name>
- Bookend-open SHA reference for downstream review base: HEAD
```

Same-packet retry stays at the original attempt number; only fresh dispatch after a 3-attempt halt increments to `attempt:<n+1>`.

### ClaimState transitions

The full transition sequence is `Unclaimed → Claimed → Running → RetryQueued → Released`.

1. **Bookend-open — `ClaimState = Claimed` then `= Running`.** Issued in the same logical operation as the bookend-open commit on the lead worktree. On the GitHub backend:

   ```sh
   # Step 1 — Build acquires the lane: ClaimState flips Unclaimed → Claimed; lane pointer flips (idle) → <pillar-trace-key>
   gh issue edit <issue-num> --add-label "bookend-open,wave:<N>,attempt:<n>"
   gh project item-edit --id <item-id> --field ClaimState --value Claimed --field Lane --value <lane>

   # Step 2 — implementer dispatch begins: ClaimState flips Claimed → Running
   gh project item-edit --id <item-id> --field ClaimState --value Running
   ```

   On the filesystem fallback the equivalent edit flips the `## Implementation Wave Queue` pillar row's claim-state column to `Running` and flips the lane block's `Currently building: (idle)` line to `Currently building: <pillar-trace-key>`.

2. **Per-PR fix-loop retry — `ClaimState = RetryQueued` then back to `= Running`.** Between fixer-push and merge-attempt the implementer's claim is parked at `RetryQueued`; on retry it returns to `Running`. The implementer increments the `attempt:<n>` label on the issue on each re-push (single-value semantics — replace the prior `attempt:*` rather than accumulate):

   ```sh
   # Fix-loop park: ClaimState flips Running → RetryQueued; attempt label increments
   gh issue edit <issue-num> --remove-label "attempt:<n>" --add-label "attempt:<n+1>"
   gh project item-edit --id <item-id> --field ClaimState --value RetryQueued

   # Fix-loop resume: ClaimState flips RetryQueued → Running for the next merge attempt
   gh project item-edit --id <item-id> --field ClaimState --value Running
   ```

3. **Bookend-close — `ClaimState = Released`.** Issued in the same logical operation as the bookend-close commit on the implementer's branch after PR merge:

   ```sh
   # Bookend-close: ClaimState flips → Released; lane pointer flips back to (idle); issue closes
   gh issue close <issue-num>
   gh project item-edit --id <item-id> --field ClaimState --value Released --field Lane --value "(idle)"
   ```

   On the filesystem fallback the equivalent edit flips the pillar row's claim-state column to `Released` and the lane block's `Currently building: <pillar-trace-key>` line back to `Currently building: (idle)`. Status's flip from `Active → Complete` belongs to Sequence on queue rollover, NOT to Build's bookend cycle.

### Lane pointer (`Currently building`)

The lane pointer is **per-lane**, not global, and derives from `ClaimState ∈ {Claimed, Running}` — the load-bearing "implementer is holding this" signal. Each lane (worktree or orchestrator session) carries at most one non-`(idle)` pointer at a time; multiple lanes do NOT mean multiple in-flight pillars per lane. Sequence emits initial idle blocks at Tracker admit time and never writes ClaimState; Build is the sole ClaimState writer. Rule codified in `docs/workflow/CLAUDE.md §Per-lane Currently-building pointer`.

### Attempt-counter label (`attempt:<n>`)

The `attempt:<n>` label on the GitHub issue (or the equivalent attempt column on the filesystem fallback) records the current bookend cycle's attempt counter. Single-value semantics — replace the prior `attempt:*` rather than accumulate. Same-packet fix loops keep the attempt counter pinned; only fresh dispatch after a 3-attempt halt increments.

### Flag-spelling pins (verbatim against live argparse)

Fence against plan-vs-repo drift — these CLI surfaces have empirical history of being miscalled:

- `export-state` is a **subcommand** under `sync_github_tracker.py` (NOT a top-level `--export-state` flag).
- `--tracker-state` is the consumer flag on `pillar_matrix.py` (NOT `--tracker-state-path` — D5-fold).
- `--pillar` is the pillar selector flag on `pillar_matrix.py --dispatch-check` (NOT `--pillar-trace-key` — P3 drift-3).

Build NEVER writes scope to the Tracker. Bookend cycle writes are ClaimState / Lane / `attempt:<n>` only; Status writes are restricted to the §Phase 4.5 `promote_wave_status` carve-out (next-wave Pending→Active rollover at wave-close, after `VERIFIED`, before handoff). Scope-origination and every other Status mutation (admission, end-of-subphase rollover, `Active → Complete`) remain Sequence's authority.

## Matrix dispatch-check CLI

Before dispatching any pillar, Build MUST run the matrix dispatch-check via `idc:idc-skill-matrix-dispatch-check` as a hard preflight. Build's matrix consumption is **CLI-only** — Build never reads `<phase-tag>-matrix.yaml` directly. The matrix is Sequence's polish surface; Build only joins it with Tracker state via the CLI wrapped by the skill.

Build refreshes the per-dispatch Tracker state JSON FIRST via `scripts/sync_github_tracker.py export-state`. On the GitHub backend this queries the live Projects V2 board via GraphQL; on the filesystem-backend fallback the same JSON shape is emitted from `TRACKER.md` parsing. The consumer flag remains `--tracker-state` (NOT `--tracker-state-path`) either way.

Two-step CLI sequence (state refresh → dispatch check):

```sh
# Step 1 — refresh per-dispatch Tracker state JSON (GitHub backend exports via GraphQL; filesystem fallback parses TRACKER.md)
uv run python scripts/sync_github_tracker.py export-state --output "$TRACKER_STATE_PATH"
```

```sh
# Step 2 — invoke dispatch-check; pillar_matrix.py joins matrix.yaml with the refreshed state
uv run python docs/workflow/scripts/pillar_matrix.py --dispatch-check \
    --pillar=<pillar-trace-key> --tracker-state="$TRACKER_STATE_PATH" --json
```

Invoke via the Skill tool (`Skill(skill="idc:idc-skill-matrix-dispatch-check", args="pillar_trace_key=<...> tracker_state_path=<...>")`) — the skill wraps the two-step sequence above.

### Missing `Pillar trace key` fallback (mechanical backfill)

When `export-state` fails because a tracker item is missing its `Pillar trace key` field, do NOT dead-halt the iteration. Sequence writes a `<!-- pillar_trace_key: ... -->` comment into every issue body it emits (`scripts/sync_github_tracker.py` issue-creation path), so the authoritative value is recoverable mechanically:

1. Read the affected issue's body and extract the `<!-- pillar_trace_key: ... -->` comment.
2. Backfill the project field via `gh project item-edit` with that value.
3. Append a `mechanical backfill: issue=#<N> pillar_trace_key=<key>` line to the run ledger.
4. Retry `export-state` ONCE.

Comment absent from the issue body, or the retry still fails → file a BLOCKING operator-todo and halt as before. This is body→field mirroring of a Sequence-authored value — Build is not originating tracker scope, so the writer-authority matrix is untouched. (Upstream prevention lives in `idc-sequence.md` Phase 4 step 1.5 admission verification; this fallback exists for trackers broken before that step shipped.)

The CLI returns one of three verdicts:

- `safe` — pillar's `blocks_on` are all `complete` in Tracker state and no in-flight conflict on shared surfaces. Proceed with dispatch.
- `blocked-by:<pillar-id>` — at least one upstream pillar is not `complete`. Halt; pick a different pillar OR wait for upstream.
- `conflicts-with-wave-member:<pillar-id>` — another pillar in the same wave is `active` and shares a non-parallel-safe surface. Halt; serialize.

The pre-dispatch query MUST refuse dispatch if any item in the same lane is already `Active` — the lane invariant caps each lane at one non-idle pillar at a time.

### Ripple-uphill-correction path

If `--dispatch-check` returns `blocked-by` or `conflicts-with` and the rough-matrix shards in pillar plans / clash evidence appear wrong (e.g., a `blocks_on` edge that no longer reflects reality, a parallel-safe pair that should serialize, a clash that should classify as `union` rather than `serialize`), Build:

1. Halts dispatch for the affected pillar only.
2. Drafts a Ripple change-order proposal at `/tmp/idc-build/<run-id>/ripple-proposal-matrix-<pillar-trace-key>.md` describing the highest affected layer (typically pillar plan surface — Deconflict-rerun territory; sometimes subphase plan — Develop-rerun territory).
3. Surfaces the proposal to the operator and routes them to invoke `idc-ripple`.
4. Continues with non-affected pillars (don't stop the train) — single-pillar parking does not halt the whole wave.

Build NEVER edits `<phase-tag>-matrix.yaml`, pillar plans, or subphase plans directly. The Ripple process is the only path for upstream corrections from the Build role; Sequence re-runs its admission step once Ripple lands.

### Serial fallback loop (`WAVE_SERIAL_ONLY` path)

When `idc:idc-skill-matrix-dispatch-check` returns `conflicts-with-wave-member:<peer>` for every candidate in a wave AND no candidate has a `blocked-by:<external-id>` against work outside the wave, the wave is **internally conflicting but externally clear** — every issue is buildable, just not in parallel. Bootstrap aggregates this into the `WAVE_SERIAL_ONLY` verdict (see `${CLAUDE_PLUGIN_ROOT}/agents/idc-role-bootstrap-researcher.md §Telegram shape`) and the trampoline degrades to N=1 with a re-check loop. This subsection documents the loop the trampoline runs on receipt of that verdict.

**Loop pseudo-procedure** (the orchestrator runs this inline; no new agent dispatches beyond the implementer spawns):

```
1.  Receive WAVE_SERIAL_ONLY telegram from bootstrap; capture serial_safe[] + externally_blocked[].
2.  Pick one issue from serial_safe — prefer the one whose peer_conflicts list names
    the most other serial_safe entries (merging it unblocks the most peers). Ties
    broken by issue_number ascending for determinism.
3.  Materialize that one issue's worktree (Phase 1, but for N=1).
4.  Spawn ONE idc:idc-role-issue-implementer teammate for it (Phase 2, but for N=1).
5.  Read its completion telegram (Phase 3 routing applies identically — MERGED /
    CONFLICT_BLOCKED / BOOTSTRAP_RESEARCH_NEEDED / BLOCKED). On MERGED:
    a. Write the issue's bookend-close via idc:idc-skill-tracker-adapter.
    b. SendMessage the durable bootstrap-researcher: "re-assess wave after #N merged".
6.  Bootstrap re-runs §Build-mode wave assessment steps 1–4 with the merged
    issue's pillar_trace_key excluded from the candidate set. It re-emits a
    telegram — usually one of:
       - WAVE_DISPATCH_READY (peer conflicts cleared; fan out the remaining set)
       - WAVE_SERIAL_ONLY    (still serializable; loop to step 2 with new picker)
       - WAVE_BLOCKED        (rare; remaining issues now externally blocked)
7.  Branch on the fresh verdict per the §After Bootstrap route table. Continue
    until the wave drains or a genuine halt verdict surfaces.
```

**Picker heuristic — "most peers blocked on it":** for each issue `i` in `serial_safe`, compute `unblock_count(i) = |{ j in serial_safe : i in j.peer_conflicts }|`. Pick `argmax(unblock_count)`. This minimizes the expected number of serial iterations. The heuristic is documented but not load-bearing; any deterministic picker satisfies correctness — the loop terminates as long as bootstrap's re-assessment is honest about which conflicts have cleared.

**Termination guarantees:**
- Each iteration merges exactly one issue and shrinks the candidate set by one. The loop runs in at most O(|wave|) iterations.
- If a serial merge surfaces a Blocker/Major review finding that exceeds the cap-3 ceiling, the implementer telegrams `BLOCKED: review_fix_ceiling` (per implementer §Phase 5). The trampoline then halts THAT issue, removes it from the candidate set, and SendMessages bootstrap to re-assess on the remaining issues (treat as if the issue were never in the wave).
- If the implementer telegrams `CONFLICT_BLOCKED`, the parent spawns `idc:idc-role-merge-deconflictor` as usual; the loop resumes once the implementer reports `MERGED` post-resolution. The serial-loop semantics are orthogonal to the conflict-resolution path.

**What `WAVE_SERIAL_ONLY` does NOT do:**
- It does NOT silently pretend a peer-conflicted issue is `safe`. The matrix verdict is preserved.
- It does NOT touch the matrix file. If peer-conflicts in this wave indicate a Sequence-level error (e.g., wave should have been split), the trampoline still files a Ripple uphill correction per §Ripple-uphill-correction path above — those are orthogonal.
- It does NOT increase the implementer cap. Implementer-internal cap-3 fix loops, cap-12 `/goal` ceiling, and bookend-close obligations all apply identically to a serial implementer.

**When `serial_safe` has only one entry from the start:** that's the trivial N=1 case — one spawn, one MERGED, bootstrap re-assesses on an empty wave and telegrams the appropriate done-state (typically `WAVE_BLOCKED` if `externally_blocked` is non-empty, or no telegram if the wave is fully drained — operator's call to advance to the next wave).

## Per-issue brief schema

Each dispatchable issue gets its own brief written to disk by the bootstrap-researcher BEFORE any implementer is spawned. The brief is the implementer's source of truth — the spawn prompt is a thin pointer (~30 lines), and the implementer reads the brief from disk first thing.

Disk location:

```
~/.claude/projects/<harness-project-dir>/briefs/<YYYY-MM-DD>-<phase-stage-tag>/issue-<N>.md
```

Required fields (front-matter or section headers — both shapes accepted, but the implementer must be able to grep each field unambiguously):

- `issue_number` — the GitHub issue number (e.g. `162`).
- `pillar_trace_key` — the polished pillar-plan filename stem without the `-plan` suffix (e.g. `<domain>-phase-12-subphase-1-pillar-3-substrate-map`).
- `pillar_plan_path` — absolute path to the canonical pillar plan (e.g. `<governed-repo>/docs/plans/pillars/<...>-plan.md`). Implementer reads on demand for context; never absorbs the body.
- `worktree_path` — absolute path to the implementer's worktree (e.g. `.claude/worktrees/idc-build-<slug>-writer-<N>/`).
- `branch` — the implementer's branch name (`idc-build-writer/<slug>/<issue-N>`).
- `base_branch` — the orchestrator branch (`idc-build/<slug>`) — NOT `main`. Implementer PRs `--base $base_branch`.
- `bookend_open_sha` — SHA of the bookend-open commit Build authored on the orchestrator branch; the adversarial-review base for the implementer's diff. Bootstrap step 5 writes brief with `bookend_open_sha: TBD`; step 8 patches with the real SHA from step 7's commit. Briefs MUST be TBD-free before the `WAVE_DISPATCH_READY` telegram fires.
- `file_surfaces` — allowed write surfaces from the pillar plan (list of repo-relative paths or directories). Scope creep beyond this list is a halt.
- `tests_required` — named test commands the implementer must run green before merge (e.g. `uv run pytest tests/test_fence_arch_idc_agents.py`, `pnpm --dir web test`).
- `goal_recipe` — the literal `/goal` condition string the implementer issues at session start. Schema in §`/goal` recipe template below.
- `skill_matrix` — list of skills the implementer should invoke (e.g. `superpowers:test-driven-development`, `superpowers:systematic-debugging`, `superpowers:verification-before-completion`, `simplify`, plus `security-best-practices` when `[SEC]` is set).
- `[SEC]` flag — boolean; when true, the implementer invokes `security-best-practices` and the PR body documents the security review.
- `bootstrap_research_pointer` — path to the bootstrap-researcher's evidence packet for this pillar (e.g. `/tmp/idc-build/<run-id>/codebase-context-packet.md` or a per-pillar slice). The implementer reads on demand to answer "what does sibling pillar X touch?" without absorbing the pillar plan body.
- `contract_rider` — a checklist the bootstrap-researcher extracts from the pillar plan's `## Exit criteria`: every fence obligation, security contract, and wiring obligation rendered as one checkable line (`- [ ] <obligation>`). This is the #184 "M5 rider" pattern generalized — the same list the author works against, the PR body reports against, and the reviewers audit against. Run evidence: the one 12.1.5 brief that carried an explicit rider produced the cleanest first-pass code.

The brief MAY also carry optional fields: `pr_title`, `pr_body_template_path`, `bookend_close_tracker_target`, `loop_index_initial` (always 1 for a fresh dispatch), and `review_profile`:

- `review_profile: full | light` (default `full`) — risk-tiered review depth, derived by the bootstrap-researcher from the brief's `file_surfaces`: docs/markdown/tracker-only surfaces → `light`; ANY production code, tests, infra, or `[SEC]` flag → `full`. `light` = one `/code-review-custom` pass + the adversarial review; skip `/simplify` and skip repeat fix cycles for findings below Blocker. When in doubt, `full`.

## `/goal` recipe template

Every implementer issues a single `/goal` command at Phase 1 of its session. The recipe is harvested from the pillar plan by the bootstrap-researcher and threaded through the brief's `goal_recipe` field. The contract is **authored uphill at plan-time** (Engineer-Gated) and set by the implementer as a bare `/goal` — there is no per-implementer go/no-go pause. Canonical shape — six labeled elements, each a clause the `/goal` evaluator checks every turn:

```
/goal [OUTCOME] Issue #<N> (<pillar-trace-key>) is squash-merged to <base_branch>
        AND bookend-close commit landed on <branch>
      [VERIFICATION] all tests in <test-paths> pass
        AND TDD ordering evidence — failing test first, expected red, minimal green, optional refactor
        AND /code-review-custom reports 0 Blocker AND 0 Major findings
        AND /codex:adversarial-review reports 0 critical AND 0 blocker findings
        AND /simplify has been run and any material findings addressed
      [CONSTRAINTS] existing suite stays green AND no new deps AND no public-API change beyond <named> AND neighbor <X> preserved
      [BOUNDARIES] in-scope writes = <file_surfaces, from the pillar Resource Ownership table>; off-limits = everything else, esp. <named co-owned / sibling / canonical surfaces>
      [ITERATION POLICY] each failed round: record what changed + what the evidence showed + the next experiment; vary the approach, do not repeat a failed one
      [BLOCKED-STOP] stop after 12 turns OR on a requirement to write an off-limits surface OR 3 failed attempts on one hypothesis; report attempted paths + evidence + the specific blocker
```

The six elements and where each is harvested from:

- **`[OUTCOME]`** — the merge-state goal (issue squash-merged to the base branch; bookend-close commit landed).
- **`[VERIFICATION]`** — the runnable success surface: named tests pass, both review passes clear, `/simplify` ran. Harvested from the pillar plan's `## Exit criteria` block. The brief's `contract_rider` is the line-item expansion of this same harvest — the implementer checks rider items off in the PR body's `## Contract rider` section as each obligation lands.
- **`[CONSTRAINTS]`** — the don't-regress line: the existing suite stays green, no new deps, no out-of-contract public-API change, named neighbors preserved. Harvested from the `## Exit criteria` block's `[CONSTRAINTS]` don't-regress line (`idc:idc-skill-pillar-plan-shape` extends the exit-criteria gate to require it).
- **`[BOUNDARIES]`** — in-scope write surfaces vs off-limits everything-else, **derived from the pillar's `## Pillar Resource Ownership` table** (in-scope = owned write paths; off-limits = co-owned / sibling / canonical surfaces). See `idc:idc-skill-pillar-resource-ownership`. This is what lets the `/goal` evaluator catch scope-creep toward an off-limits file mid-loop instead of only at the post-hoc halt check.
- **`[ITERATION POLICY]`** — record-and-vary between failed rounds. This is **orthogonal to — never a replacement for** — `superpowers:test-driven-development` red→green→refactor ordering and the cap-3 fix-loop ceilings; both stay in force.
- **`[BLOCKED-STOP]`** — the explicit ceiling: 12 turns, an off-limits-surface write requirement, or 3 failed attempts on one hypothesis. On any, halt with the attempted-paths + evidence + specific-blocker report.

The 12-turn ceiling generalizes the 3-attempt ceiling (three failed attempts on the same hypothesis → halt + summary) to the `/goal` evaluator-turn cadence. The cap is per-brief-tunable via the `goal_recipe` field if a particular pillar warrants a different ceiling (e.g. a doc-only refactor might cap at 6 turns; a deep-stack feature might cap at 18). Default is 12.

One `/goal` per implementer session; the orchestrator does NOT set per-PR goals because the orchestrator is coordinating many implementers in parallel. The phase-close adversarial reviewer (BR-4) is read-only and does not use `/goal`.

If the brief omits a `goal_recipe` (cold dispatch without a wave handoff), the implementer falls back to assembling the six-element recipe inline from the pillar plan — `[VERIFICATION]` + `[CONSTRAINTS]` from the `## Exit criteria` block, `[BOUNDARIES]` from the `## Pillar Resource Ownership` table — same content, same source, just author-time, so the wave-handoff path and the cold-dispatch fallback produce the same shape. This fallback path is documented in `${CLAUDE_PLUGIN_ROOT}/agents/idc-role-issue-implementer.md`.

## Side-issue ladder (no-punt policy)

Canonical: `WORKFLOW.md §7.6 Side-issue ladder + operator-action filing` — this section is the Build-mechanics mirror; §7.6 wins on any conflict.

When any Build step surfaces an issue that is not the current unit's outcome — a sub-Blocker review finding, an incidental defect, a cosmetic cleanup — route it down this ladder (operator decision 2026-06-10; side issues get implemented, not punted):

1. **Needed + in-boundary → fix in the same PR.** Repair required for the issue's outcome/verification/constraints and within its `[BOUNDARIES]` is resolved in the same `/goal` loop — fold it into the current fix pass. Never deferred.
2. **Agent-doable but outside the writer's `[BOUNDARIES]` → the writer reports it to the parent; the parent spawns a side-job teammate NOW** running `/auto-goal` on the task in its own worktree/PR, with off-limits boundaries covering all in-flight pillar surfaces. The wave continues in parallel (don't stop the train). Writers never silently expand scope and never spawn teammates themselves (operator-is-lead). Before merging any main-landing side-job PR, the side-job runs the wave-overlap merge guard per `WORKFLOW.md §7.6` (intersect the PR's changed files with the active wave's owned surfaces; non-empty intersection → HOLD until wave close) as part of its `/auto-goal` `[VERIFICATION]`.
3. **Agent-doable but blocked (depends on an unmerged PR / missing substrate) → GitHub issue labeled `side-job`.** Open `side-job` issues **block phase-close** (see §Phase-close adversarial gate).
4. **Operator-console-only (creds, web-UI rituals) → markdown operator-todo (BLOCKING)** via `idc:idc-skill-file-operator-todo`, unchanged.

## Per-PR ceremony — INSIDE the implementer's session

The implementer follows this 10-step sequence under `/goal` direction. Each step is bounded; Task subagents drive sub-work so the implementer's own context stays lean.

**Review-profile tiering (B-risk):** when the brief carries `review_profile: light` (docs/markdown/tracker-only surfaces — see §Per-issue brief schema), steps 4–7 run as ONE `/code-review-custom` pass plus ONE adversarial pass: step 6 (`/simplify`) is skipped, and fix loops below Blocker severity are not repeated — sub-Blocker findings route per §Side-issue ladder in one pass (in-boundary repairs applied in that same pass). Any production code, tests, infra surface, or the `[SEC]` flag forces `full` (the sequence exactly as written). Absent key = `full`.

1. **Enter worktree, set `/goal` from brief, snapshot baseline tests.** `cd "$worktree_path"`, verify `git branch --show-current` matches `$branch`, verify `origin/$base_branch` exists, run the project's baseline test command, snapshot the green-or-red status in session memory. Issue the `/goal` from the brief's `goal_recipe` BEFORE starting TDD.

2. **TDD via `superpowers:test-driven-development` skill (red → green → refactor).** Spawn Task subagent with the TDD skill under the active `/goal` loop. Brief: write red test for the issue's first observable behavior, run, confirm red for the expected reason, implement minimal pass, run green. Repeat per behavior. `/goal` drives continuation until the recipe clears; it does not replace the failing-test-first discipline. Subagent returns digest; implementer applies the diff via Edit and commits with conventional message (`test(<issue-N>): red — ...`, `feat(<issue-N>): green — ...`, optional `refactor(<issue-N>): ...` after green).

3. **Open PR `--base $base_branch` with `Closes #<N>`.**

   ```bash
   gh pr create \
     --base "$base_branch" \
     --head "$branch" \
     --title "$pr_title" \
     --body "$(cat <<EOF
   Closes #<N>

   ## Summary
   <2-4 bullets on what this pillar packet implements>

   ## Changes
   <list of changed files + one-line per file>

   ## Tests
   <list of new / updated tests + how to run>

   ## TDD ordering
   First commit: test(<issue-N>): red — <one-line>
   Implementation commit(s): feat(<issue-N>): green — <one-line>
   Refactor commit (optional): refactor(<issue-N>): <one-line>

   ## Contract rider
   <the brief's contract_rider checklist verbatim, with per-item status:
   - [x] <obligation met — one-line evidence>
   - [ ] <obligation NOT yet met — why + where it lands>
   Author, reviewer, and adversarial pass all audit against this one list.>

   ## Security review
   <only when [SEC] flag set — security-best-practices findings + mitigations>

   Refs: pillar <pillar_trace_key>

   🤖 Generated with [Claude Code](https://claude.com/claude-code)
   EOF
   )"
   ```

   SendMessage parent `STARTED: pr=#N branch=<name>`.

4. **Spawn `/code-review-custom pr <N>` Task subagent; read findings file; triage.** Subagent writes findings to `docs/workflow/code-reviews/<YYYY-MM-DD>-pr-<N>-attempt-<n>-review.md` and returns severity counts + path. Implementer reads only the findings file (NOT the subagent's reply body). Triage by severity:

   - `Blocker` / `Major` → fix loop (step 5). Always address.
   - `Minor` / `Nit` → route per §Side-issue ladder: in-boundary → apply in this PR's fix pass; out-of-boundary agent-doable → report to parent (parent spawns the `/auto-goal` side-job teammate); blocked → `side-job` GitHub issue; operator-console-only → operator-todo. Do NOT block merge on ladder steps 2-4.
   - Zero Blocker/Major → proceed to `/simplify` (step 6).

5. **Receive-code-review skill; fix; commit; push. Cap-3 internal loops.** Spawn Task subagent with `superpowers:receiving-code-review` skill. Subagent reads the findings file, applies fixes (TDD posture — failing test first if the finding is a missing test), runs tests, returns diff digest. Implementer applies, commits (`fix(<issue-N>): ...`), pushes. Re-enter step 4 with attempt counter incremented. Three failed attempts on the same finding cluster → SendMessage parent `BLOCKED: review_fix_ceiling`, stand down for parent to escalate.

6. **`/simplify` Task subagent; address material findings; push.** Spawn Task subagent invoking the `simplify` skill against the PR diff. Returns simplification candidates. Implementer reviews — apply material findings, commit (`refactor(<issue-N>): simplify`), push. Cosmetic findings route per §Side-issue ladder (in-boundary cosmetics are just applied here). Iterate up to 3 simplify cycles or until clean.

7. **`/codex:adversarial-review --background --base <bookend_open_sha>` Task subagent; triage same way; cap-3 fix loops.** The `--background` flag is mandatory per the codex command contract — without it the slash command fires `AskUserQuestion` to choose foreground vs background, halting the autonomous loop (don't stop the train). Subagent runs codex, writes findings to `docs/workflow/code-reviews/<YYYY-MM-DD>-pr-<N>-adversarial.md`. Severity mapping per the unified IDC vocabulary: `critical → Blocker`, `high → Major`, `medium → Minor`, `low → Nit`, `next_steps → INFO`. Blocker/Major → re-enter step 5 (separate counter; still cap-3). Minor/Nit/INFO → route per §Side-issue ladder. **Auto-retry-once (dead background thread):** if the background Codex thread dies — `/codex:status` errors, reports no-such-task, or shows no progress across two polls ≥ 10 minutes apart — relaunch the identical command ONCE and note `codex_retry_count: 1` in the run record. Second death → SendMessage parent `BLOCKED: codex_review_failed`.

7.5. **Pre-merge artifact sweep (mandatory).** Before step 8, run `git status --short` and stage + commit any untracked or modified files under `docs/workflow/code-reviews/`, `docs/workflow/operator-todos/`, `docs/workflow/audits/`, `docs/workflow/handoffs/`, `docs/workflow/ledgers/`. These are per-attempt review reports, operator-todos, audits, handoffs, and ledgers the cycle subagents wrote during steps 4–7. Without an explicit commit they orphan locally when the PR squash-merges. Commit message: `chore(<issue-N>): in-flight workflow artifacts`. Push. See `WORKFLOW.md §9.1` step 4.5 for the canonical rule and the 2026-05-17 audit that surfaced 9 such orphans across PRs #163 / #164 / #166.

8. **Attempt `gh pr merge --squash --delete-branch` via worktree-merge single-shot pattern.** Pre-merge evidence gate (Phase 8.0): the per-PR adversarial findings file (`docs/workflow/code-reviews/<YYYY-MM-DD>-pr-<N>-adversarial.md`) MUST exist and show 0 Blocker + 0 Major before any merge attempt — absent or non-zero → do NOT merge; return to step 7 (absent) or step 5 (non-zero). Use Variant B per `WORKFLOW.md §9.2` (writer PRs target the orchestrator branch, not `main`). Pattern:

   ```bash
   git -C "$ORCHESTRATOR_WORKTREE_PATH" rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null && \
     cd "$MAIN_REPO_PATH" && \
     git worktree remove "$worktree_path" && \
     gh pr merge "$PR_NUM" --squash --delete-branch && \
     git fetch origin && \
     git checkout "$base_branch" && \
     git pull --ff-only && \
     git branch -D "$branch" 2>/dev/null || true && \
     git fetch --prune
   ```

   **Critical ordering:** `git worktree remove` runs BEFORE `gh pr merge --delete-branch` to avoid a worktree/branch-delete race condition — `--delete-branch` races against the worktree that still owns the local branch and `gh` refuses the local-branch delete.

   The trailing `git branch -D ... && git fetch --prune` is mandatory per `WORKFLOW.md §9.2` Banlist — reaps any leftover local writer branch ref (no-op if it never existed locally, e.g. the `-local` suffix collision case) and prunes the stale `origin/<branch>` remote-tracking ref left after `--delete-branch`. Local-branch + stale-remote-tracking accumulation is the same workflow drift as remote-branch accumulation; the 2026-05-17 audit found both.

9. **On merge conflict:** SendMessage parent `CONFLICT_BLOCKED: pr=#N file=<file> markers=<marker-summary>`, then idle. Do NOT touch the conflicted files. Do NOT run `git rebase` to "investigate." Await `RESUMED: pr=#N` SendMessage from parent (after BR-2 `idc:idc-role-merge-deconflictor` resolves the conflict on the implementer's branch). On resume: re-enter step 4 (review may need to re-run if the deconflictor's resolution changed semantics).

10. **On merge success:** write bookend-close commit (`tracker: close Phase <N> Stage <M> bookend (attempt <n>)`) — for filesystem backend on the implementer's branch as a tracker-only commit; for GitHub backend this is the `gh project item-edit ... ClaimState=Released` + `gh issue close` pair from §Bookend protocol step 3. SendMessage parent:

    ```
    ## issue-implementer telegram
    - Verdict: MERGED
    - issue: #<N>
    - pillar_trace_key: <key>
    - pr: #<PR-N>
    - merge_sha: <SHA>
    - findings_filed: <count Minor/Nit ladder-routed (in-PR fixes / side-job reports)> + <count INFO>
    - turns_used: <N> / 12
    ```

    Stand down (await `shutdown_request` from parent).

## Tracker state-transition writes (GitHub backend + filesystem fallback)

All writes route through `idc:idc-skill-tracker-adapter`. The adapter resolves the active backend via `docs/workflow/tracker-config.yaml::backend ∈ {filesystem, github}` and applies the equivalent OR-B2 pattern below.

### GitHub backend (canonical)

Bookend-open (claim acquire + lane flip + writer dispatch):

```sh
gh issue edit <issue-num> --add-label "bookend-open,wave:<N>,attempt:<n>"
gh project item-edit --id <item-id> --field ClaimState --value Claimed --field Lane --value <lane>
gh project item-edit --id <item-id> --field ClaimState --value Running
```

Per-PR fix-loop retry:

```sh
gh issue edit <issue-num> --remove-label "attempt:<n>" --add-label "attempt:<n+1>"
gh project item-edit --id <item-id> --field ClaimState --value RetryQueued
gh project item-edit --id <item-id> --field ClaimState --value Running
```

Bookend-close (release + lane idle + issue close):

```sh
gh issue close <issue-num>
gh project item-edit --id <item-id> --field ClaimState --value Released --field Lane --value "(idle)"
```

### Filesystem backend (fallback)

Equivalent edits to `TRACKER.md ## Implementation Wave Queue`:

- Bookend-open: flip the pillar row's claim-state column to `Running`; flip the lane block's `Currently building: (idle)` line to `Currently building: <pillar-trace-key>`; add `attempt:<n>` to the row's attempt column.
- Retry: increment the attempt column (single-value replace); flip claim-state to `RetryQueued`, then back to `Running` on resume.
- Bookend-close: flip the pillar row's claim-state column to `Released`; flip the lane block back to `Currently building: (idle)`; the row stays in the active wave until Sequence's queue rollover flips Status `Active → Complete`.

Each filesystem edit is committed as a tracker-only commit (`tracker: close <pillar_trace_key> packet <work_packet_id> bookend`) per `docs/workflow/CLAUDE.md §Auto-pushable bookend commits`. Pre-commit hooks remain mandatory; no `--no-verify`.

### Routing via `idc:idc-skill-tracker-adapter`

Invoke the skill rather than calling `gh` or editing `TRACKER.md` directly. The bookend transitions are NOT single named adapter ops — they are short compositions of the adapter's real six core / operational ops (`setField`, `acquire-lane-lock`, `complete_claimed_item`; see `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-tracker-adapter/SKILL.md`). Dispatch them as:

```text
# Bookend-open — acquire the lane lock, then ClaimState Claimed → Running and set Lane:
Skill(skill="idc:idc-skill-tracker-adapter", args="operation=acquire-lane-lock, lane=<lane>, ticket=<N>, idempotency-key=<sha>")
Skill(skill="idc:idc-skill-tracker-adapter", args="operation=setField, ticket_id=<N>, field=ClaimState, value=Claimed")
Skill(skill="idc:idc-skill-tracker-adapter", args="operation=setField, ticket_id=<N>, field=ClaimState, value=Running")
Skill(skill="idc:idc-skill-tracker-adapter", args="operation=setField, ticket_id=<N>, field=Lane, value=<lane>")

# Retry-park — ClaimState Running → RetryQueued, then back to Running on resume:
Skill(skill="idc:idc-skill-tracker-adapter", args="operation=setField, ticket_id=<N>, field=ClaimState, value=RetryQueued")
Skill(skill="idc:idc-skill-tracker-adapter", args="operation=setField, ticket_id=<N>, field=ClaimState, value=Running")

# Bookend-close — ClaimState → Released and Lane idle, then complete the claimed item (PR-on-main gate + Active→Complete):
Skill(skill="idc:idc-skill-tracker-adapter", args="operation=setField, ticket_id=<N>, field=ClaimState, value=Released")
Skill(skill="idc:idc-skill-tracker-adapter", args="operation=setField, ticket_id=<N>, field=Lane, value=(idle)")
Skill(skill="idc:idc-skill-tracker-adapter", args="operation=complete_claimed_item, issue=<N>, claim_handle=<handle>")
```

The skill emits the right commands for the active backend; the implementer never branches on backend in its own session logic.

## Phase 4.5 — Next-wave rollover

Substrate detail for the trampoline's Phase 4.5 step (`${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md §Phase 4.5 — Next-wave rollover`). Fires AFTER the Phase 4 integration verifier returns `VERIFIED` (and AFTER the Phase 5 phase-close adversarial gate when this is a phase boundary), and BEFORE the Phase 6 handoff write. There is no subphase-boundary or phase-boundary restriction — wave discovery and eligibility checks live inside the `promote_next_eligible_wave` op (`${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-tracker-adapter/SKILL.md`).

### Why this step lives in Build

Pre-carve-out, every wave-close handed off `next_role: sequence` so `/idc:sequence` could flip the next wave's `Status=Pending → Status=Active`. Now Build's carve-out covers any wave whose substrate is ready: `blocks_on` upstream cleared AND target phase's matrix YAML present. Wave discovery lives in the adapter (`promote_next_eligible_wave`); Build's authority is to invoke that op and route the handoff per its return value. In `--autowave` mode (`${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md §Phase 7`), the trampoline self-iterates across every Pending wave until the substrate exhausts or a halt condition fires; in non-autowave mode, the rollover advances exactly one wave and the operator chooses whether to re-invoke `/idc:build`.

Sequence retains every other Status mutation: initial admission of a phase's pillars (sets Wave-1 directly to `Active` at admit-time + queues Waves 2+ as `Pending`), retroactive corrections, and `Active → Complete` transitions. The carve-out is one mechanical step, no more — what changed is the scope of "next eligible wave" expanded from in-subphase to universal.

### Trigger preconditions

Run Phase 4.5 if and only if ALL of:

1. Phase 4 integration verifier returned `VERIFIED` (architectural fences green, repo-targeted tests green, phase-plan-named verifications green).
2. At phase boundaries: the Phase 5 phase-close adversarial gate returned APPROVE OR its fix loop landed green (per `WORKFLOW.md §8.3 "Don't stop the train"`).
3. At least one Pending wave exists whose items' `blocks_on` upstream is fully satisfied AND whose phase has a matrix YAML present.

Skip Phase 4.5 if preconditions 1 or 2 fail (re-run integration verifier or run the phase-close fixer first). If precondition 3 fails, the adapter returns `no_candidate` — in non-autowave mode, record the skip reason and advance to Phase 6 with `next_role: sequence`; in autowave mode, Phase 7's diagnostic spawn fires (see §Phase 7 substrate).

### Procedure (parent-inlined)

The trampoline runs this step itself — no teammate spawn. The orchestrator invokes the adapter once:

```text
Skill(skill="idc:idc-skill-tracker-adapter", args="op=promote_next_eligible_wave")
```

The adapter resolves the backend (per `docs/workflow/tracker-config.yaml::backend`) and dispatches universal-scope wave discovery + promotion. The `promote_wave_status(wave, phase)` op is kept as a deprecated alias for callers that already named a specific wave — new callers (including this trampoline) use the universal op.

### Handoff `next_role` matrix

| Phase 4.5 result | `next_role` | Rationale |
|------------------|-------------|-----------|
| `promoted` | `build` | Self-iteration — next `/idc:build` dispatches the now-`Active` wave. In `--autowave` mode, Phase 7 fires the next iteration automatically. |
| `no_candidate (eligible-blocked)` | `build` (autowave) / `sequence` (non-autowave) | Pending wave exists but upstream not satisfied. Autowave mode spawns the diagnostic; non-autowave routes to Sequence to file the blocker. |
| `no_candidate (substrate-missing)` | `build` (autowave) / `sequence` (non-autowave) | Pending wave is upstream-clear but matrix YAML missing. Autowave mode spawns the diagnostic; non-autowave routes to Sequence to author matrix via Plan. |
| `no_candidate (tracker-exhausted)` | `sequence` | Tracker drained; Sequence may admit new pillars or roll the phase forward. Autowave terminates cleanly. |
| `error: <error_kind>` | `build` (re-run) OR `sequence` | Adapter fail-closed envelope — record in §Open questions and let the operator route. |

### Lane invariant + idempotency

The op MUST refuse to fire if the candidate wave's lane block already shows any non-`(idle)` `Currently building:` pointer for items in that wave — the lane-invariant cap (`tests/test_arch_one_active_per_lane.py`) is preserved. The op is idempotent: re-running against an already-Active wave is a no-op (GitHub Projects V2 silently accepts a same-value `setField`; filesystem fallback short-circuits on detecting the target value).

Build NEVER writes ClaimState or Lane as part of Phase 4.5. Bookend-open dispatch (`ClaimState = Claimed → Running`, `Lane = <pillar-trace-key>`) happens at the next `/idc:build` invocation against the now-Active wave, via the existing §Bookend protocol path. Rollover is queue-state only.

## Phase-close adversarial gate

Triggered when ALL of these hold (per `WORKFLOW.md §8.3`):

- All stage PRs merged AND bookend-close commits landed.
- TRACKER `## Operator Actions BLOCKING` count is zero.
- Architectural-fitness fences green.
- The phase boundary closes (last stage of the phase completed).

Procedure:

1. **Tag the phase delta.** Phase-start SHA = first stage's bookend-open commit on the orchestrator branch. Phase-end SHA = current `origin/main` HEAD after all stage merges. The delta is the implementation surface the adversarial reviewer scrutinizes.

2. **Spawn BR-4 `idc:idc-role-phase-close-adversarial-reviewer`** (Fable 5 1M context) via `Agent({subagent_type: "idc:idc-role-phase-close-adversarial-reviewer", team_name: "<idc-team>", prompt: "..."})`. The brief carries: `phase_tag`, `phase_start_sha`, `phase_end_sha`, list of merged PRs, integration-verifier result. BR-4 runs `/codex:adversarial-review --background --base <phase-start-SHA>`. Read-only role; writes `docs/workflow/code-reviews/<YYYY-MM-DD>-phase-<N>-adversarial-review.md`.

3. **Severity mapping** per the unified IDC vocabulary (Q-cross-2 binding):

   - Codex `critical` → IDC `Blocker`
   - Codex `high` → IDC `Major`
   - Codex `medium` → IDC `Minor`
   - Codex `low` → IDC `Nit`
   - Codex `next_steps` → IDC `INFO`

4. **If any Blocker / Major** → spawn a **phase-close fixer** by reusing `idc:idc-role-issue-implementer` with `mode: phase-close-fixer` flag and the adversarial findings file as input. The brief points the implementer at the adversarial report; the implementer applies fixes through the same review-fix-merge ceremony (steps 4-10 above), opening a phase-close fix PR against `main` via Variant A of `WORKFLOW.md §9.2`.

5. **Minor / Nit / INFO findings + Codex `next_steps`** → route per §Side-issue ladder: agent-doable → the orchestrator spawns `/auto-goal` side-job teammates (phase-close scope, own worktrees/PRs); blocked → `side-job` GitHub issues; operator-console-only → operator-todo via `idc:idc-skill-file-operator-todo`. Do NOT bundle into the fix PR.

6. **Phase-transition ritual** fires only after step 4 lands the fix PR (or step 2 yielded `approve` with zero Blocker/Major) **AND zero open `side-job` GitHub issues remain for this phase** (`gh issue list --label side-job --state open` filtered to the phase — open side-jobs block phase-close; resolve them via ladder step 2 teammates or close them with evidence before the ritual fires).

### "Don't stop the train" override

The phase-close gate overrides the `codex-result-handling` skill default ("after presenting findings, stop and ask"). Critical/blocking/high are auto-fixed unless they contradict an explicit project contract; everything else routes per §Side-issue ladder and the phase-close proceeds once open `side-job` issues are cleared. Per the don't-stop-the-train posture — the train keeps moving; the operator gets a roll-up at handoff time, not a per-finding decision prompt.

## Worktree mandate (§9.2 Variant B)

Per `WORKFLOW.md §9.2`, the IDC Build flow uses Variant B for per-PR worktrees and Variant A for the session-close merge. Critical constraint: `gh pr merge` ignores git `-C` — always `cd "$MAIN"` first before invoking it.

### Branch namespace

- **Orchestrator branch:** `idc-build/<slug>` — created by the parent trampoline's Phase 0 worktree self-check; lives at `.claude/worktrees/idc-build-<slug>/`. The parent's bookend-open commit, handoff artifact, and session-close PR all originate here.
- **Implementer branches:** sibling namespace `idc-build-writer/<slug>/<issue-N>` — NEVER child refs under the orchestrator branch (e.g. `idc-build/<slug>/writer-3` is forbidden). Worktrees live at `.claude/worktrees/idc-build-<slug>-writer-<N>/`.

### Per-issue worktree materialization

Before spawning any implementer teammate, the parent materializes each writer's worktree branched FROM the orchestrator branch. Implementers do NOT auto-create their own worktrees:

```bash
ORCH_BRANCH=$(git -C "$ORCH_WT" branch --show-current)   # idc-build/<slug>
ORCH_SLUG="${ORCH_BRANCH#idc-build/}"

# Publish the orchestrator branch before implementer PRs target it.
git -C "$ORCH_WT" push -u origin "$ORCH_BRANCH"
git -C "$ORCH_WT" rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null

for ISSUE_N in $ISSUE_NUMBERS; do
  WT=".claude/worktrees/idc-build-$ORCH_SLUG-writer-$ISSUE_N"
  BRANCH="idc-build-writer/$ORCH_SLUG/$ISSUE_N"
  git worktree add -b "$BRANCH" "$WT" "$ORCH_BRANCH"   # base = orchestrator branch, NOT main
done
```

Each implementer brief carries `worktree_path`, `branch`, and `base_branch: $ORCH_BRANCH`. The implementer enters `worktree_path`, commits on `branch`, verifies `origin/$base_branch` exists, and opens its PR `--base "$base_branch"`. Writer PRs land on the orchestrator branch first; the orchestrator branch PRs to `main` once at session close via Variant A. Effect: nothing lands on `main` mid-session, so multiple parallel `/idc:build` runs stay isolated.

### Worktree-merge single-shot pattern

For per-PR merges (Variant B — implementer PR base = orchestrator branch):

```bash
git -C "$ORCHESTRATOR_WORKTREE_PATH" rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null && \
  cd "$MAIN" && \
  git worktree remove "$worktree_path" && \
  gh pr merge "<N>" --squash --delete-branch && \
  git fetch origin && \
  git checkout "$base_branch" && \
  git pull --ff-only
```

**Critical ordering:** `git worktree remove` runs BEFORE `gh pr merge --delete-branch` to avoid a worktree/branch-delete race condition. With `--delete-branch` first, the worktree still owns the local branch and `gh` refuses the local-branch delete; the merge succeeds on GitHub but the local state is partial and the next operation fails.

For the session-close merge (Variant A — orchestrator branch PR base = `main`):

```bash
cd "$MAIN" && \
  gh pr merge "$ORCH_PR_NUM" --squash --delete-branch && \
  git pull --ff-only && \
  git worktree remove ".claude/worktrees/idc-build-<slug>" && \
  git worktree prune && \
  git branch -D "idc-build/<slug>"
```

Decide which variant to use via `gh pr view "$PR_NUM" --json baseRefName -q .baseRefName`: `main` → Variant A; anything else → Variant B.

## Handoff schema

Every IDC Build run ends with a durable handoff artifact at:

```
docs/workflow/handoffs/builds/<YYYY-MM-DD-HHMM>-<tag>.md
```

The `<tag>` is the phase / stage / pillar slug (kebab-case). Same-day collision: append `-2`, `-3`.

### Auto-advance frontmatter (R6 Phase A)

Every handoff this role writes MUST open with the auto-advance frontmatter block. The seven core keys are load-bearing — names, casing, and order verbatim. The `handoff_kind` key (and its companion `paused_at_phase`) is appended after the seven core keys — never reordered into them. Two additional keys are OPTIONAL and present only when autowave is active:

```yaml
---
role: build
next_role: build
auto_advance_eligible: true
auto_advance_reason: <one-line if false>
open_questions: 0
blocking_todos: 0
pipeline: codebase
handoff_kind: wave-close   # wave-close | rotation | pause; default wave-close
paused_at_phase: <0-7>     # optional; only meaningful when handoff_kind != wave-close
resume_command: /idc:build --autowave --resume   # optional; required when handoff_kind = rotation
autowave_remaining_waves: -1   # optional; integer or -1 for unbounded; only when --autowave active
autowave_session_id: <datestamp>   # optional; ties this handoff to the parent autowave-session ledger
---
```

`open_questions` mirrors the §"Open questions / operator decisions pending" item count; `blocking_todos` mirrors BLOCKING items in operator-todo files referenced. Disagreement between frontmatter and body is a halt + audit. `pipeline ∈ {codebase, governance}` per R0 surface-based classification (Build is `codebase` by default; `next_role: build` mirrors Build's pillar-by-pillar self-iteration loop until phase close).

`autowave_remaining_waves` and `autowave_session_id` are present only when the parent run was invoked with `--autowave` (or carried prior autowave state through resume). Absent → autowave was not active for this run; Phase 7 skipped. Decrement of `autowave_remaining_waves` happens at Phase 7 Step 5 (re-invocation), so the value written to this handoff reflects the COUNT REMAINING FOR THE NEXT ITERATION. When `autowave_remaining_waves == 0`, the next iteration's Phase 0 Step 0 reads the handoff, sees the cap is exhausted, and terminates immediately.

### `handoff_kind` semantics

- `wave-close` (default) — the normal end-of-run handoff written at Phase 6; body sections per §Handoff body sections.
- `rotation` — a CLEAN termination written when the context-budget threshold (below) trips: the session ends healthy so a fresh session can resume mechanically. Frontmatter carries `next_role: build`, `auto_advance_eligible: true`, `autowave_remaining_waves` preserved (NOT decremented for an un-run wave), and the one-line `resume_command: /idc:build --autowave --resume`. Body MUST include §Pause state.
- `pause` — written on operator pause mid-phase per `${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md §Operator pause protocol`, BEFORE any cleanup or `TeamDelete`. Frontmatter carries `paused_at_phase`; body MUST include §Pause state.

### Context-budget threshold (rotation triggers)

This is the threshold halt condition 8 (§Halt conditions) and the Phase 7 Step 5 headroom guard refer to. Rotation triggers when ANY of the following hold — these are the only signals measurable from inside a session (token counts are not observable):

1. Completed autowave iterations this session ≥ `AUTOWAVE_ROTATE_AFTER` (set by the `--rotate-after N` flag at Phase 0 Step 0; default 2).
2. A harness context-compaction event or low-context warning was observed this session.
3. The orchestrator or the bootstrap-researcher self-reports context saturation.

A tripped threshold is NOT a halt — it is a clean rotation: write the handoff with `handoff_kind: rotation` (semantics above) and terminate per `idc-build.md` Phase 7 Step 2 condition 9.

### Handoff body sections

- **§Pick up here** — exact next action for the next IDC Build run (e.g. "phase-12 subphase-1 next pillar = `<pillar-id>`; bookend-open commit landed at `<sha>`; implementers spawn from briefs at `<brief-storage-path>/`"). If the run halted on Ripple, name the Ripple change order pointer.
- **§What just landed** — PR numbers + merge SHAs, bookend commits, phase-close adversarial review path (if applicable), integration verifier result, operator-todos BLOCKING count.
- **§Verification (drift detection for resume)** — main HEAD SHA, last PR merged, worktrees expected, alive teammates expected, operator-uncommitted edits in main, memory files written, operator-todos BLOCKING count for closing phase, architectural-fitness fences status, scratch run dir, canonical admission PR / SHA (if any), reviewed scratch plan path (if any).
- **§Open questions / operator decisions pending** — anything the per-PR or phase-close gate flagged for operator judgment.
- **§Notes for resume** — Ripple change orders the next session must clear; deferred operator-todos rolled up at closeout.
- **§Pause state** — REQUIRED whenever `handoff_kind != wave-close`; see below.

### §Pause state (required when `handoff_kind` ≠ `wave-close`)

Schematizes the mid-run state that previously had to be reconstructed ad hoc. Every item is required (write `none` explicitly when empty):

- **Alive teammates + assignments** — each teammate name, its role, and the issue/work unit it holds.
- **In-flight PRs** — PR number + branch + which implementer phase each PR's owner is in.
- **Claimed-but-unmerged issues** — issue number + current ClaimState for every item Build claimed but did not complete.
- **Worktree paths** — every live worktree this run created (`git worktree list` snapshot).
- **Briefs dir** — path to the per-issue briefs for this wave.
- **Scratch dir** — the run's scratch directory path.
- **Exact next safe action** — the single concrete step the resuming session should take first.

### Build's auto-push + tracker-pointer-update obligation (Q-build-1)

Special-case among the 7 IDC roles: Build is the ONLY IDC role that auto-pushes its handoff and updates the Tracker `## Active Handoff` pointer (via `idc:idc-skill-tracker-adapter` — `gh` CLI mutations on the GitHub backend; equivalent `TRACKER.md` edits on the filesystem fallback) in the same logical operation as the handoff file write. Other IDC roles' handoffs do NOT auto-push and do NOT update the Tracker pointer. The Build-specific behavior is load-bearing for the bookend-close-equivalent operation at run end.

Path discipline: handoff artifacts live under `docs/workflow/handoffs/builds/`. The directory name is `handoffs/` (no hyphen, per canonical CLAUDE.md doc-layout) and that is the only spelling permitted in any reference written by this role.

## Resume mode

When the parent trampoline is invoked via `/idc:build --resume` or with prompt prefix `RESUME:`, run resume bootstrap:

1. **Read TRACKER header + `## Active Handoff` section.** Use `idc:idc-skill-tracker-adapter` to fetch the canonical Active Handoff pointer on either backend.
2. **Read the active handoff doc referenced from `## Active Handoff` in full.** The handoff carries the §Verification stanza with drift-detection checks.
3. **Run §Verification stanza checks the handoff specifies:** `git fetch --prune origin`, `git log --oneline <recorded-HEAD>..origin/main`, `git worktree list`, `git status --short`, ls memory files, optional fitness-fence run if claim is "green" and operator hasn't already verified, operator-todos BLOCKING count.
4. **Spawn `idc:idc-role-bootstrap-researcher` in resume mode** with prompt prefix `RESUME: <run-id>` — receive resume packet with drift findings, current wave's parallel-safe set, and per-issue brief paths. If the active handoff's `handoff_kind` is `pause` or `rotation`, pass its §Pause state section to the resume-mode bootstrap-researcher verbatim — alive-teammate, in-flight-PR, and ClaimState recovery start from that section, and the "exact next safe action" line seeds the resume packet.
5. **Decide halt-vs-continue based on the explicit drift report.** If resume state is missing, stale, or contradicts the recorded handoff verification block, halt with `BLOCKED` and surface the drift to the operator.

## Phase 7 — Autowave loop substrate

Substrate detail for the trampoline's Phase 7 step (`${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md §Phase 7 — Autowave loop`). Fires only when `AUTOWAVE_MODE=true` and the Phase 6 handoff has been written + pushed.

### Loop-driver arming + stall recovery

Mirrors the trampoline's Phase 7 Step 0 (`${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md §Phase 7 — Autowave loop`, Step 0 — Arm the loop driver). On the FIRST autowave iteration of a session, the trampoline arms `/loop /idc:build --autowave --resume` — self-paced, with a 60-minute long-fallback wakeup — as the self-resume safety net. Wakeup semantics:

- **Iteration healthy** (liveness probes pass; recent teammate telegrams observed) → no-op; reschedule the next wakeup.
- **Stall signature** (no progress since the prior wakeup AND teammates idle/paused — the account-usage-limit signature) → re-drive: resend pending SendMessages, respawn dead teammates per the zombie protocol.
- **Iteration complete** → the trampoline's existing Steps 1–5 run.

An account-usage-limit pause freezes the whole session; the first wakeup after the limit window resets auto-resumes the run with no operator action. Every row in the §Termination matrix below disarms the loop driver — no termination path, clean or halt, leaves an armed loop behind; rotation rows keep `resume_command: /idc:build --autowave --resume` as the fresh-session fallback. Boundary: `/loop` is the cross-iteration resume + stall-recovery surface only — never a substitute for SendMessage signaling inside Phases 2–4.

### Termination matrix

The trampoline's Phase 7 Step 2 termination check enumerates nine halt conditions. Substrate detail per condition:

| Halt condition | Detected via | Action |
|----------------|--------------|--------|
| `next_role: build` + `auto_advance_eligible: false` | Handoff frontmatter read | Surface §Open questions; exit cleanly. |
| `next_role: ripple` | Handoff frontmatter read | Ripple is operator-gated; exit and let the operator route to `/idc:ripple`. |
| `blocking_todos > 0` | Handoff frontmatter + `docs/workflow/operator-todos/` BLOCKING scan | Exit; the diagnostic teammate or in-flight halt already filed the todo. |
| `AUTOWAVE_REMAINING == 0` after decrement | Parent-session variable | Clean cap-reached exit; useful for `--max-waves N` testing. |
| Tracker-drift detected | `op=export-state` snapshot diff (Step 3 routine below) | Halt with `TRACKER_DRIFT_DETECTED`; write diff to autowave-session ledger. |
| Phase 5 phase-close fixer failed 3× | Phase 5 internal state | Existing halt condition #6 from §Phase-close adversarial gate. |
| Operator interrupt | Harness-level | Out of band; not detected by this section. |
| `no_candidate (tracker-exhausted)` | Phase 4.5 adapter return | Clean tracker-exhaustion exit. |
| Rotation budget reached | §Context-budget threshold (iterations ≥ `AUTOWAVE_ROTATE_AFTER`, compaction event, or self-reported saturation) | CLEAN termination, not a halt: write handoff with `handoff_kind: rotation` (+ §Pause state, `resume_command`), preserve `autowave_remaining_waves`, exit. |

Every row in this matrix also disarms the `/loop` driver (§Loop-driver arming + stall recovery) as part of its exit action; the rotation row's `resume_command` line remains the fresh-session fallback.

### Tracker-drift snapshot routine

Between iterations, capture and diff tracker state:

```text
Skill(skill="idc:idc-skill-tracker-adapter", args="op=export-state output=<autowave-session-dir>/tracker-snapshot-<iter>.json")
```

Compare to `<autowave-session-dir>/tracker-snapshot-<iter-1>.json`. Allowed mutations (per Phase 4.5 + Build per-issue ceremony):
- Status: just-promoted wave items flip `Pending → Active`.
- ClaimState: just-merged wave items cycle `Claimed → Running → Released`.
- Bookend labels: added/removed on just-merged items.
- Wave/Phase/Lane: unchanged on rows the just-merged wave touched.

Any mutation outside this list is foreign drift. Common causes: operator hand-edited the tracker mid-autowave; concurrent `/idc:sequence` run; tracker substrate corruption. Halt with `TRACKER_DRIFT_DETECTED`; write the diff to the autowave-session ledger so the operator can triage.

### Diagnostic spawn

On Phase 4.5 returning `no_candidate (eligible-blocked)` or `no_candidate (substrate-missing)` AND `AUTOWAVE_MODE=true`, Phase 7 spawns the diagnostic teammate (`${CLAUDE_PLUGIN_ROOT}/agents/idc-role-wave-blocker-diagnostic.md`):

```text
Agent({
  subagent_type: "idc:idc-role-wave-blocker-diagnostic",
  team_name: "idc-build-<slug>",
  name: "wave-blocker-diagnostic",
  mode: "bypassPermissions",
  prompt: "You are wave-blocker-diagnostic. Read your brief at <scratch_dir>/diagnostic-brief.md and your playbook at ${CLAUDE_PLUGIN_ROOT}/agents/idc-role-wave-blocker-diagnostic.md. Run the routine end-to-end and SendMessage me one TRACKER_EXHAUSTED / HALTED_AT_BLOCKING_TODO / RIPPLE_REQUIRED / SUBSTRATE_MISSING / BLOCKED telegram."
})
```

The brief at `<scratch_dir>/diagnostic-brief.md` carries: `parent_team`, `scratch_dir`, `autowave_session_dir`, `tracker_snapshot_path`, `previous_snapshot_path`, `operator_todos_dir`, `ripple_dir`, `repo_root`, the adapter response, and the datestamp. See `${CLAUDE_PLUGIN_ROOT}/agents/idc-role-wave-blocker-diagnostic.md §2 Inputs` for the full field list.

The diagnostic writes evidence to `docs/workflow/audits/<YYYY-MM-DD>-autowave-diagnostic-<datestamp>.md` and (unless the verdict is `TRACKER_EXHAUSTED`) files a BLOCKING operator-todo at `docs/workflow/operator-todos/<datestamp>-autowave-halt.md`. The autowave halt flows through the `blocking_todos > 0` precondition on the next loop iteration — NOT through the diagnostic's telegram. The diagnostic gathers evidence; the loop respects the BLOCKING-todo gate.

### Iteration-cap shape

`AUTOWAVE_REMAINING` is initialized at Phase 0 Step 0 from `--max-waves N` (defaults to `-1` for unbounded). Decrement happens at Phase 7 Step 5 (re-invocation), BEFORE the next iteration is dispatched. Resume from interrupted autowave: Phase 0 Step 0 reads `autowave_remaining_waves` from the just-written handoff and recovers the count.

### Autowave-session ledger

The top-level autowave-session ledger lives at `docs/workflow/ledgers/<YYYY-MM-DD>-autowave-session-<AUTOWAVE_SESSION_ID>-ledger.md`. One line per iteration:

```
iter=<N> wave=<wave-id> phase=<phase-tag> pr=<PR#> sha=<merge-sha> halt_reason=<none|<enum>>
```

Final halt line:

```
HALT_AT_ITER=<N> reason=<enum> ledger_complete=true
```

The ledger is written incrementally — each iteration appends one line at Phase 7 Step 5 before either re-invocation or termination. On termination, the final HALT line is appended.

## Halt conditions

Halt only on:

1. `TeamCreate`, `SendMessage`, or `TeamDelete` unavailable.
2. Repo root is not a git repository, or `git status` fails.
3. Bootstrap-researcher returns `NEEDS_BUILDOUT` / `TOP_LEVEL_REPLAN_REQUIRED` / `SCAFFOLD_ONLY` / `BLOCKED` for every candidate in the wave.
4. Plan / pillar contradiction: implementation evidence proves the pillar is wrong → halt and file Ripple via `idc-ripple`.
5. Per-PR review-fix loop hits the 3-attempt ceiling per finding cluster.
6. Phase-close adversarial gate returns critical / blocking / high findings the fixer cannot resolve in 3 loops.
7. Operator says stop / wrap / halt / `/sum` / equivalent.
8. Context-budget threshold per §Handoff schema.

Do NOT halt on:

- Medium / low / nit findings — route per §Side-issue ladder; keep moving.
- Conflicts during merge — spawn BR-2 `idc:idc-role-merge-deconflictor` from the parent; implementer idles and resumes on `RESUMED:` SendMessage.
- Routine integration-verifier hiccups — re-run, spawn deconflict if needed, file fix PR.
- Single-pillar matrix-dispatch-blocked verdicts — continue with non-affected pillars (don't stop the train).

## Anti-patterns

The Build flow has empirical history of these failure modes. Each is named so reviewers and roleplayers can flag them by tag.

- **Spawning team-joining teammates from implementers.** Forbidden — operator-is-lead invariant. Implementers may use read-only Task subagents internally; team-joining `Agent({team_name: ...})` calls are NOT allowed.
- **Absorbing pillar plan body into implementer context.** Use the `bootstrap_research_pointer` surface in the brief. The bootstrap-researcher owns plan reads; the implementer reads packet-scoped slices on demand via grep.
- **Editing canonical docs** (PRD, master architectural spec, master implementation plan, subphase plans, pillar plans, root or per-directory CLAUDE.md, AGENTS.md) from inside an implementer session. Doc edits route through Ripple (governance pipeline).
- **Editing TRACKER scope.** Scope/order updates originate from Sequence, not Build. Build writes ClaimState / Lane / `attempt:<n>` plus the narrow Phase 4.5 `promote_wave_status` Status carve-out only; any other Status mutation is scope creep.
- **Skipping the bookend-close commit** after a PR merges. Lane pointer stays stuck on the merged pillar; next dispatch fails the lane-invariant check.
- **Auto-merging with Blocker / critical findings outstanding.** The cap-3 fix loop must clear Blocker/Major BEFORE merge. Minor/Nit/INFO route per §Side-issue ladder and merge proceeds.
- **Exceeding cap-3 fix loops per review type.** Three failed attempts on the same finding cluster → SendMessage parent `BLOCKED: review_fix_ceiling`. Do NOT loop indefinitely.
- **Using `--no-verify` or `--no-gpg-sign`** when committing. Hooks remain mandatory. On hook failure: fix the underlying issue, re-stage, NEW commit (never `--amend` after hook failure).
- **Running `gh pr merge` from inside the worktree.** `gh pr merge` ignores git `-C`. Always `cd "$MAIN"` first.
- **Worktree removal AFTER `gh pr merge --delete-branch`.** Races against the local branch the worktree still owns; `gh` refuses the local-branch delete. Remove worktree FIRST.
- **Halting on Minor / Nit findings.** Route per §Side-issue ladder; keep the train moving.
- **Resolving merge conflicts in the implementer session.** Implementer STOPS on conflict, SendMessages parent `CONFLICT_BLOCKED`, idles. Parent spawns BR-2 deconflictor (Fable 5 / 1M-context / ultrathink).

## Doctrine notes

One-line operating invariants for this flow (runtime-portable).

- Operator-is-lead; implementers do not spawn team-joining teammates.
- Autonomous-by-default; Minor/Nit findings route per §Side-issue ladder; single-pillar parking does not halt the wave.
- `git worktree add` does NOT change shell pwd; `cd <worktree>` is the next step or chain `cd <path> &&` on every git command.
- Three failed attempts on the same hypothesis trigger a structured halt + summary; this generalizes to the 12-turn `/goal` evaluator ceiling.
- Single-shot worktree cleanup pattern (`cd "$MAIN"`, then chain); `gh pr merge` ignores git `-C`.
- Every PR runs implementer (with internal Task subagents for review/fix/simplify/adversarial) → merge → cleanup → shutdown; the per-PR cycle lives INSIDE the implementer session.
- File-based briefs + autonomous decisions; pillar plan body lives on disk; implementers grep-read their packet's section, never absorb the whole plan.
- Implementer work runs as a TEAMMATE (own context, own worktree); the ~600s Task watchdog is too tight for the full lifecycle.
- Review reports / audits go to files at `docs/workflow/code-reviews/` and `docs/workflow/audits/`; never inline into the orchestrator's pane.
- Every stage opens AND closes with a TRACKER commit; bookend-close is part of the implementer's success path.
- The phase-close adversarial gate overrides the codex-result-handling default; auto-fix critical/high; route the rest per §Side-issue ladder; zero open `side-job` issues before the phase-transition ritual.
- Verify the implementer is alive within ~30s via `ps aux | grep '@<team>'` + `cmux tree --all`; don't loop spawns past 2 attempts. A respawn auto-renames to `<name>-2` (the dead entry holds the original name): flip the ghost `isActive: false` in the team config immediately, never SendMessage the ghost name (it fabricates a `~/.claude/teams/default/` dead-letter inbox), and write one ledger + final-handoff line — "`<name>` = silent-spawn ghost, work done by `<name>-2`; it shows as a running teammate in this session until restart — cosmetic, ignore." The ghost survives /clear, TeamDelete, and team-dir deletion; only a session restart clears it (upstream claude-code #42391/#34614, open as of 2026-06-10).
