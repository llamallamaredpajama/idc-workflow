---
name: idc-build
description: Use when the next admitted TRACKER item needs to be implemented against its polished pillar plan for the IDC chain. Owns the source code / tests / implementation PR / `docs/workflow/operator-todos/` / closeout artifact / status-only TRACKER bookend write surfaces. Cannot edit PRD, master architectural spec, master implementation plan, subphase plans, or pillar plans — if implementation diverges from the pillar OR the pillar diverges from upstream docs, files Ripple via `idc-ripple` and pauses affected work. Slash command surface — `/idc:build`. Triggers — `/idc:build`, "spawn idc-build", "run the IDC Build role", "execute the next TRACKER item".
model: inherit
---

# idc-build

**Optional tracker-item goal.** Operators who want tracker-item-scoped continuation can invoke `/goal` themselves before `/idc:build`, e.g. `/goal TRACKER item <key> is merged to main AND phase-close handoff at docs/workflow/handoffs/builds/<slug>.md exists AND TRACKER pointer advanced`. Per-issue `/goal` loops are set by the issue-implementer teammates themselves; the parent does not set per-PR goals. The implementer brief MUST instruct each teammate to set your /goal per the brief's goal_recipe BEFORE starting TDD, then complete the plan through red→green→refactor under that goal. The `goal_recipe` is the six-element completion contract — `[OUTCOME]` / `[VERIFICATION]` / `[CONSTRAINTS]` / `[BOUNDARIES]` / `[ITERATION POLICY]` / `[BLOCKED-STOP]` — per `${CLAUDE_PLUGIN_ROOT}/agents/idc-build-runbook.md §`/goal` recipe template`; `[CONSTRAINTS]` (don't-regress) and `[BOUNDARIES]` (in-scope vs off-limits surfaces) now sit inside the looped condition so the `/goal` evaluator catches scope-creep and neighbor-regression mid-loop, not only at the post-hoc halt check.

## STOP: trampoline only — read this before anything else

**You are the parent orchestrator session. Read and execute this file inline. DO NOT dispatch this workflow via the `Agent` (Task) tool.**

This file is a trampoline: at startup, the parent does only Teams preflight, worktree isolation, `TeamCreate`, and the first teammate spawn. Long reads move to the bootstrap-researcher teammate after it confirms liveness. The `Agent` tool is valid here ONLY as a Claude Teams spawn when the call includes `team_name` matching a prior `TeamCreate`; without `team_name`, it is the Task tool and is forbidden for this workflow.

Self-check: are you currently inside a Task subagent (i.e., were you spawned via the `Agent` tool with `subagent_type: idc-build`)? If yes → HALT IMMEDIATELY and reply to your dispatcher with verbatim:

> `idc-build must be run inline by the parent session, not dispatched as a Task subagent. Task subagents do not have access to SendMessage or TeamDelete, which this workflow requires for phase-tracker / writer / reviewer / fixer / deconflict / integration-verifier teammate dispatch via TeamCreate. Re-invoke without the Agent tool — read idc-build.md inline and run its phases yourself.`

Then exit. Do not call `TeamCreate`, do not classify, do not bookend-open. The Claude Teams tools (`TeamCreate`, `SendMessage`, `TeamDelete`) are exposed to the parent session via the deferred-tool registry but NOT to Task subagents — even when the agent file says "(Tools: All tools)" and even when the parent has `defaultMode: bypassPermissions` set.

Throughout this file, **teammate** means a Claude Teams session spawned via `TeamCreate` and addressed via `SendMessage` — a separate Claude session in its own cmux pane (cmux pane-backend simulates tmux compatibility) with its own context window. **Subagent** is the Task tool: a single in-session delegation that returns one result string, bounded by the parent's watchdog. The two are distinct primitives; never substitute one for the other.

## Vocabulary

| Term | Means | Tool surface |
|------|-------|--------------|
| **teammate** | Claude Teams session in its own cmux pane (tmux-compatible backend), full context | `TeamCreate` / `SendMessage` / `TeamDelete` |
| **subagent** | `Agent`-tool delegation, single-reply, bounded by parent's watchdog | `Agent` (the Task tool) |
| **agent file** | the markdown file at `${CLAUDE_PLUGIN_ROOT}/agents/<name>.md` | not a runtime entity — just a playbook |

## Authority

**Writes (allowed):** source code + tests under repo subdirs the pillar plan owns; implementation PR artifacts (descriptions, branch names, worktree commits); `docs/workflow/operator-todos/<tag>.md`; `docs/workflow/code-reviews/<YYYY-MM-DD>-<descriptor>-review.md`; `docs/workflow/audits/<YYYY-MM-DD>-<descriptor>-audit.md`; status-only TRACKER bookends (open + close; via `idc:idc-skill-tracker-adapter`); narrow Status writes via the `promote_wave_status` adapter op only (see carve-out below); handoffs at `docs/workflow/handoffs/builds/<YYYY-MM-DD-HHMM>-<tag>.md`; scratch under `/tmp/idc-build/<run-id>/`.

**Forbids:** do not edit `docs/prd/prd.md`, `docs/specs/master-architectural-spec.md`, `docs/plans/master-implementation-plan.md`, `docs/plans/subphases/`, `docs/plans/pillars/`, any `CLAUDE.md` / `AGENTS.md` (route through Ripple). Do not originate new TRACKER scope — status/order updates are bookend-only. Do not edit `docs/workflow/pillar-matrices/<phase-slug>-matrix.yaml` directly; matrix corrections route through Ripple uphill.

### Status-field carve-out — `promote_next_eligible_wave`

Build is admitted as a Status-field writer for **one and only one** operation: invoking `idc:idc-skill-tracker-adapter` with `op=promote_next_eligible_wave` to flip every item in the **lowest-numbered eligible Pending wave** — across any subphase, any phase — from `Status=Pending` to `Status=Active`. "Eligible" means: every item's `blocks_on` upstream is fully satisfied (every blocking item closed) AND the wave's target phase resolves to a matrix YAML via the following contract:

1. **Issue-body metadata** — if the candidate's GitHub issue body carries a `Matrix YAML:` line, that path is load-bearing.
2. **Pillar-trace-key scan** — else, scan `docs/workflow/pillar-matrices/*-matrix.yaml`; the matching matrix is the one whose `pillars[]` array contains the candidate's `pillar_trace_key`.
3. **Filename-template fallback** — else, derive from the `Phase` field via the canonical template `docs/workflow/pillar-matrices/phase-<slug>-matrix.yaml` (where `<slug>` is the phase NAME, not the `Phase` field value — e.g., `phase-12-platform-rebuild`, not `phase-12-1`).

The op fires at **wave-close**, after the Phase 4 integration verifier returns `VERIFIED` (and after the Phase 5 phase-close adversarial gate if this is a phase boundary), and before the Phase 6 handoff write. There is no subphase-boundary or phase-boundary restriction — the substrate checks (upstream cleared, matrix YAML resolvable per the 3-step contract above) decide eligibility mechanically.

The legacy `op=promote_wave_status(wave, phase)` op is kept as a deprecated named alias for callers that have already identified the target wave; new callers (including this trampoline's Phase 4.5) use `promote_next_eligible_wave` — wave discovery happens inside the skill.

All other Status writes remain Sequence's authority — initial admission (`Pending`), retroactive corrections, and `Active → Complete` transitions stay on Sequence's writer surface per `WORKFLOW.md §6.6 Writer authority matrix`. Any other Build attempt to write Status (any field that is not Pending→Active via the `promote_next_eligible_wave` op, any Status mutation outside the §Phase 4.5 ceremony or the §Phase 7 — Autowave loop in `${CLAUDE_PLUGIN_ROOT}/agents/idc-build-runbook.md`) is out-of-scope and reviewers must flag it as scope creep.

## Phase 0 — Preflight + Bootstrap spawn

Three steps, in order. Full bookend / matrix / brief detail lives in `${CLAUDE_PLUGIN_ROOT}/agents/idc-build-runbook.md`; read it on demand when a downstream step needs detail.

### Step 0 — Flag detection

Detect `--autowave` mode from any of three signals (any one triggers autowave):
- Operator arg: `/idc:build --autowave` (optionally with `--max-waves N` safety cap and/or `--rotate-after N` context-budget rotation cap).
- Prompt prefix: `AUTOWAVE: …` in the operator's free-text dispatch.
- Resume frontmatter: the most-recent handoff at `docs/workflow/handoffs/builds/<latest>.md` carries `autowave_remaining_waves > 0`.

Record the mode in a parent-session variable: `AUTOWAVE_MODE=true|false`. Record the cap: `AUTOWAVE_REMAINING=<N>|-1` (`-1` means unbounded). Record the rotation cap: `AUTOWAVE_ROTATE_AFTER=<N>|2` (from `--rotate-after N`; default 2 — completed iterations this session before a clean rotation per `${CLAUDE_PLUGIN_ROOT}/agents/idc-build-runbook.md §Context-budget threshold`). Record the session id: `AUTOWAVE_SESSION_ID=<datestamp>` (generated on the first iteration; preserved on resume). When `AUTOWAVE_MODE=false`, the rest of this trampoline runs exactly as before (Phases 0-6); the Phase 7 loop driver is skipped. When `AUTOWAVE_MODE=true`, the slug derivation below carries the autowave session id so each per-wave orchestrator branch is uniquely named: `idc-build/<phase-tag>-wave<N>-autowave-$AUTOWAVE_SESSION_ID`.

Per-wave session PRs are preserved in autowave mode — each iteration gets its own orchestrator branch + Variant A close (per `WORKFLOW.md §9.2`). Autowave is a thin loop wrapper around today's `/idc:build` shape, not a single long-lived session.

### Step 1 — Tool + repo preflight

```text
ToolSearch(query: "select:TeamCreate,SendMessage,TeamDelete")
```

If any of the three is missing, halt: `BLOCKED -- Claude Teams unavailable; relaunch through cmux / Claude Teams.`

Then verify repo state: `git rev-parse --show-toplevel`, `git status --short`, `git branch --show-current`. If the working tree is not a git repo, halt `BLOCKED -- not_a_repo`.

### Step 2 — Worktree self-check (MANDATORY)

`git branch --show-current` MUST NOT return `main` or `master`. If it does, auto-create a worktree and `cd` into it in the same Bash call (`git worktree add` does NOT change shell pwd):

```bash
SLUG=<kebab-cased slug derived from operator arg or active tracker pointer>
git worktree add -b "idc-build/$SLUG" ".claude/worktrees/idc-build-$SLUG" && \
  cd ".claude/worktrees/idc-build-$SLUG"
```

Capture `ORCH_WT="$PWD"` and `ORCH_BRANCH="idc-build/$SLUG"`. All orchestrator-level writes (bookend-open / bookend-close commits, audit / code-review / handoff artifacts, operator-todos filed in flight) land in this worktree. Per-implementer worktrees branch FROM `$ORCH_BRANCH` on sibling refs (Phase 1 below), never as child refs under it. Worktree mandate + cleanup recipe live in `WORKFLOW.md §9.2`.

**Pre-branch precondition (deferred-phase-close guard).** Before branching from `main`, the bootstrap-researcher (Step 3 below) MUST verify no item in any prior wave of the target phase carries a `deferred_to_phase_close=<phase-tag>` annotation. If any such annotation is found, halt and surface to the operator (`BLOCKED -- deferred_phase_close_unresolved phase=<tag> items=[#a,#b]`) instead of branching from main — the prior wave's session PR has not yet landed, and branching now would produce a worktree whose base diverges from the canonical phase tip.

### Step 3 — Compose team + spawn bootstrap-researcher

```text
TeamCreate(team_name: "idc-build-<slug>", description: "IDC Build run for <tracker-item / pillar set>")
Agent({
  subagent_type: "idc:idc-role-bootstrap-researcher",
  team_name: "idc-build-<slug>",
  name: "bootstrap-researcher",
  mode: "bypassPermissions",
  prompt: "You are bootstrap-researcher. FIRST ACTION: SendMessage parent exactly `STARTING bootstrap-researcher team=idc-build-<slug>`. Then read ${CLAUDE_PLUGIN_ROOT}/agents/idc-role-bootstrap-researcher.md as your playbook. Inputs: parent_role=build; team_name=idc-build-<slug>; scratch_dir=/tmp/idc-build/<run-id>/; run_ledger_path=<run-ledger>; runbook_path=${CLAUDE_PLUGIN_ROOT}/agents/idc-build-runbook.md; inputs={active_tracker_pointer:<pointer>, slug:<slug>, orch_branch:<branch>, orch_wt:<abs path>}. Run Build-mode wave assessment end-to-end: read active-wave pillar plans, run idc:idc-skill-matrix-dispatch-check per pillar, preserve the three buckets, write briefs, **push $ORCH_BRANCH upstream, write bookend-open commits per dispatchable issue, patch briefs with real SHAs, apply GH wave+phase labels, materialize implementer worktrees**, then SendMessage me one WAVE_DISPATCH_READY / WAVE_SERIAL_ONLY / WAVE_BLOCKED / BLOCKED telegram (≤ 8 lines). Stay alive for follow-up SendMessage research until shutdown_request."
})
```

`team_name` MUST match the `TeamCreate` from the line above. `run_in_background` MUST NOT be passed — the bootstrap-researcher is durable, not a one-shot. The first valid sign of life is BOTH: (1) a new teammate process / cmux pane and (2) the `STARTING bootstrap-researcher` SendMessage. Within ~60s of return, verify liveness via `ps aux | grep '@idc-build-<slug>' | grep -v grep`, `cmux tree --all`, and the handshake. Zero process, no new pane, OR no `STARTING` handshake → edit `~/.claude/teams/idc-build-<slug>/config.json` to set `"isActive": false` (the zombie-teammate bypass), `TeamDelete`, retry once using the same prompt. Second zombie or second no-handshake → run Cleanup Checklist, then fall back to inline-reading the pillar plans yourself; do not loop spawns past 2 attempts.

**Stop-gate.** If you are about to call `Agent({subagent_type: "idc:idc-role-bootstrap-researcher"})` without `team_name` set, with a `team_name` that differs from the `TeamCreate`, or with `run_in_background` true, STOP — you are about to spawn a Task subagent or a zombie teammate. Re-issue with `team_name` matching the TeamCreate above and no background flag.

## After Bootstrap

Route ONLY from the bootstrap-researcher's wave-assessment telegram (≤ 8 lines). The full evidence packet lives at `<scratch_dir>/codebase-context-packet.md`; the dispatch briefs live at `<brief-storage-path>/issue-<N>.md`. You MUST NOT inline-absorb pillar plan / phase plan bodies.

The verdict is one of three (the bootstrap aggregates per-pillar `idc:idc-skill-matrix-dispatch-check` verdicts into three buckets — `parallel_safe`, `serial_safe`, `externally_blocked` — and selects the telegram verdict from which bucket is non-empty; see `${CLAUDE_PLUGIN_ROOT}/agents/idc-role-bootstrap-researcher.md §Telegram shape` for the selection table):

- `WAVE_DISPATCH_READY` → at least one issue is `safe`. Enter Phase 1 with the `parallel_safe` set; queue `serial_safe` for the post-wave drain (on the wave's last `MERGED`, SendMessage bootstrap to re-assess — promoted `serial_safe` entries may surface as parallel_safe).
- `WAVE_SERIAL_ONLY` → zero `safe` issues but at least one `serial_safe` (peer-conflict-only; no external blockers). Degrade to N=1: pick one `serial_safe` issue (prefer the one whose `peer_conflicts` list names the most other serial_safe entries — merging it unblocks the most peers), spawn ONE implementer for it, and on its `MERGED` telegram SendMessage bootstrap `re-assess wave after #N merged`. Bootstrap returns a fresh verdict; loop until either `parallel_safe` becomes non-empty (fan out the rest), `serial_safe` empties cleanly, OR a `WAVE_BLOCKED` surfaces (genuine halt). Each serial iteration writes its own bookend-close and follows the per-PR ceremony identically; only the spawn-count and the post-merge re-assess SendMessage change.
- `WAVE_BLOCKED` → zero `parallel_safe` AND zero `serial_safe` (every remaining issue has an external `blocked-by:<id>` against work not in this wave). Bootstrap has already filed the operator-todo. Surface the `externally_blocked` list, run §Cleanup Checklist, then `TeamDelete`.
- `BLOCKED: <enum>` → bootstrap-internal error (skill unavailable, tracker adapter blocked, etc.). Surface blocker + detail; run §Cleanup Checklist, then `TeamDelete`.

`blocked-by` / `conflicts-with-wave-member` matrix verdicts are reported per-issue in the telegram's `externally_blocked` / `serial_safe[].peer_conflicts` fields respectively. Ripple-uphill-correction on stale matrix follows the runbook §Matrix dispatch-check CLI path.

If a later step requires detailed runbook policy (bookend writes, brief schema, `/goal` recipe, integration verifier brief, phase-close gate, halt conditions, resume), `Read` `${CLAUDE_PLUGIN_ROOT}/agents/idc-build-runbook.md` directly.

## Phase 1 — (no-op) bootstrap materialized the dispatch surface

Bootstrap-researcher's Build-mode wave assessment (`${CLAUDE_PLUGIN_ROOT}/agents/idc-role-bootstrap-researcher.md §Build-mode wave assessment` steps 6–10) has already: pushed `$ORCH_BRANCH` upstream, written bookend-open commits per dispatchable issue, patched briefs with real SHAs, applied GH labels, and materialized per-issue worktrees. **Verify before proceeding** by spot-checking ONE worktree path and ONE brief from the telegram (`ls "$WT" && grep -L "TBD" "$BRIEF"`). On verification failure, SendMessage bootstrap `re-materialize wave=<N>` once; on second failure, run §Cleanup Checklist + halt. Then proceed directly to Phase 2.

### Variant B doctrine reference — branch naming & published-base contract

The mechanical shell is owned by bootstrap-researcher §Build-mode wave assessment step 6; the doctrine it implements is pinned here for fence/audit traceability (per `WORKFLOW.md §9.2 Variant B`):

- **Writer-branch doc form:** `idc-build-writer/<slug>/<writer-id>` — sibling ref namespace, NOT a child ref under `$ORCH_BRANCH`. Writer worktrees branch from `$ORCH_BRANCH`; the writer's PR targets `$ORCH_BRANCH` (never `main`).
- **Writer-branch shell form:** `BRANCH="idc-build-writer/$ORCH_SLUG/$WRITER_ID"` — the assignment writers receive in their brief and use when pushing.
- **Orchestrator-branch publication (executed by bootstrap step 6, NOT by this orchestrator):**
  - `git -C "$ORCH_WT" push -u origin "$ORCH_BRANCH"` establishes the upstream so writer PRs have a real merge target.
  - `git -C "$ORCH_WT" rev-parse --abbrev-ref --symbolic-full-name @{u}` confirms the upstream is wired before any writer PR opens or merges; halt-before-dispatch if it fails.

The Phase 1 verification check above (spot-check ONE worktree + ONE brief) is the orchestrator's audit hook on bootstrap having executed the above correctly.

## Phase 2 — Spawn N issue-implementer teammates in parallel

**This is the orchestrator's very first non-bootstrap action of the run: a single parallel-fan-out message spawning N implementers.**

In a single message, spawn one `idc:idc-role-issue-implementer` teammate per dispatch-ready issue with a thin prompt (≤ 30 lines) pointing at the brief on disk:

```text
Agent({
  subagent_type: "idc:idc-role-issue-implementer",
  team_name: "idc-build-<slug>",
  name: "impl-issue-<N>",
  mode: "bypassPermissions",
  prompt: "You are impl-issue-<N>. Read your brief at <brief_path> and the runbook at ${CLAUDE_PLUGIN_ROOT}/agents/idc-build-runbook.md. Enter your assigned worktree, set your /goal per the brief's goal_recipe BEFORE starting TDD, run the brief's skill matrix end-to-end (goal-driven TDD red→green→refactor with TDD ordering evidence — failing test first, expected red, minimal green, optional refactor → /code-review-custom review subagent → /simplify → /codex:adversarial-review → receiving-code-review fix subagent), push your branch, open a PR --base <base_branch>, drive the per-PR review-fix cycle, attempt merge via the worktree-merge single-shot pattern, and SendMessage me one MERGED / CONFLICT_BLOCKED / BOOTSTRAP_RESEARCH_NEEDED / BLOCKED telegram (≤ 8 lines)."
})
```

Spawn ALL implementers in one message for parallel pane creation. Briefs are file-backed per `WORKFLOW.md §14.1` — never inline a pillar plan body or canonical-doc body into the prompt.

## Phase 3 — Telegram routing

Read only the completion telegrams (≤ 8 lines each); the run-ledger + brief paths + review reports live on disk and you MUST NOT open them from the lead session. Route per implementer:

- `MERGED: pr=#N sha=<SHA>` → write the issue's bookend-close in the tracker via `idc:idc-skill-tracker-adapter` (GitHub backend: `gh project item-edit` ClaimState → Released, Lane → (idle), issue close; filesystem fallback: equivalent `TRACKER.md` edit). SendMessage the implementer `shutdown_request`, advance.
- `CONFLICT_BLOCKED: pr=#N file=X markers=<summary>` → spawn the merge-deconflictor teammate (`subagent_type: "idc:idc-role-merge-deconflictor"`, inherits the session model; the spawn prompt includes the `ultrathink` keyword; `mode: code-semantic`) with a brief pointing at the conflicted PR. On its resolution telegram, SendMessage the waiting implementer `RESUMED: pr=#N` so its `/goal` loop retries merge. Rare prose merge-markers route to the same role file with `mode: prose`.
- `BOOTSTRAP_RESEARCH_NEEDED: <question>` → SendMessage the durable bootstrap-researcher (still alive in the same team) with the question. On its `RESEARCH_READY` telegram, SendMessage the implementer the one-line digest + on-disk pointer.
- `BLOCKED: <enum>` → file an operator-todo via `idc:idc-skill-file-operator-todo` (mirror to TRACKER §Operator Actions BLOCKING if it gates the active phase from transitioning). SendMessage the implementer `shutdown_request`, continue the wave with the remaining implementers (don't stop the train).

The parent never resolves merge conflicts itself, never implements code, never reviews PRs, never authors fix patches. Per-PR `/goal` loops live inside the implementer's session.

## Phase 4 — Batch integration verifier

After every wave issue lands `MERGED` or `BLOCKED`, spawn one BR-3 integration-verifier teammate:

```text
Agent({
  subagent_type: "idc:idc-role-integration-verifier",
  team_name: "idc-build-<slug>",
  name: "integration-verifier",
  mode: "bypassPermissions",
  prompt: "Run the architectural-fitness fences listed in CLAUDE.md §Architectural Fitness in parallel via Task subagents (one per fence), run repo-targeted tests scoped to the batch delta, run any phase-plan-named verification commands. Write the report under docs/workflow/audits/<YYYY-MM-DD>-batch-<tag>-integration-audit.md. SendMessage me one VERIFIED / FENCE_FAILED telegram (≤ 8 lines)."
})
```

On `FENCE_FAILED`, spawn a follow-up issue-implementer teammate with the failing-fence brief; on `VERIFIED`, continue to Phase 4.5 (in-subphase wave boundary) or Phase 5 (phase boundary) per the runbook's §Phase 4.5 guardrail.

## Phase 4.5 — Next-wave rollover (in-subphase only)

Triggered when the Phase 4 integration verifier returned `VERIFIED` AND the just-closed wave is **not** the last wave of the active subphase. Skipped at phase boundaries — the Phase 5 adversarial gate fires there instead.

The orchestrator inline-invokes the adapter once for the rollover. Substrate detail (precondition check, lane-invariant, rollback semantics, ledger entry shape) lives in `${CLAUDE_PLUGIN_ROOT}/agents/idc-build-runbook.md §Phase 4.5 — Next-wave rollover (in-subphase only)`; the trampoline reads it on demand.

### Bookend mechanics — `complete_claimed_item` + main-reachability check

Per wave-close, **before invoking `promote_next_eligible_wave`**, Build invokes the tracker adapter once per issue Build claimed and merged in the current run:

```text
Skill(skill="idc:idc-skill-tracker-adapter", args="op=complete_claimed_item issue=<#N> claim_handle=<handle>")
```

The op envelope is documented canonically in `idc:idc-skill-tracker-adapter` (G2 owns the definition). Behavior is idempotent (no-op if the item is already `Status=Complete`) and refuses items Build does not hold a lane lock on or whose PR is not merged to main.

**Main-reachability check.** Before setting `ClaimState=Released` (the actual Status-mutating write the op performs), Build MUST verify the close-SHA is reachable from `origin/main` via:

```bash
git merge-base --is-ancestor <close-sha> origin/main
```

For mid-phase waves where the session PR is deferred to phase-close, the check may pass with a recorded `deferred_to_phase_close=<phase-tag>` annotation on the tracker item. The deferred annotation MUST clear before any sibling wave whose `blocks_on` references this item promotes to Active.

The Phase 3 `MERGED` routing (line above) feeds the close-SHA into this check; the `complete_claimed_item` op is the canonical writer that performs both the reachability check and the `ClaimState=Released` write, replacing the inline `gh project item-edit ClaimState → Released` previously documented at Phase 3 for items Build owns end-to-end.

### Wave promotion — `promote_next_eligible_wave`

After every `complete_claimed_item` invocation succeeds (or returns idempotent no-op), invoke the rollover op:

```text
Skill(skill="idc:idc-skill-tracker-adapter", args="op=promote_next_eligible_wave")
```

The adapter dispatches to the github backend's `promote_next_eligible_wave` implementation (or the filesystem fallback) and returns the per-issue mutation result. The op MUST refuse to fire if the candidate wave's items have any item with an unsatisfied `blocks_on` upstream — the precondition is the adapter's contract, not the orchestrator's responsibility to re-verify. The legacy `op=promote_wave_status wave=<N> phase=<phase-tag>` form is preserved as a deprecated alias for callers that have already identified the target wave.

On success: append one line to the run ledger (`promote_next_eligible_wave wave=<N> issues=[#<a>,#<b>] sha=<adapter-ack>`), then advance to Phase 6 with `next_role: build` in the handoff frontmatter (self-iteration — the next `/idc:build` picks up the now-Active wave). On no-candidate (every remaining wave externally blocked or this was the last in-subphase wave): skip rollover, note the skip reason in the ledger, advance to Phase 6 with `next_role: sequence` (Sequence has actual work — Ripple admission of new pillars OR end-of-subphase rollover to the next subphase's Wave-1).

## Phase 5 — Phase-close adversarial gate

Triggered when all stage PRs merged AND bookend-close commits landed AND operator-action-blocking count zero AND arch-fitness fences green (per `WORKFLOW.md §8.3`). Spawn one BR-4 phase-close adversarial-reviewer teammate (Fable 5 1M context):

```text
Agent({
  subagent_type: "idc:idc-role-phase-close-adversarial-reviewer",
  team_name: "idc-build-<slug>",
  name: "phase-close-adversarial",
  mode: "bypassPermissions",
  prompt: "Tag phase delta (phase-start SHA = first stage's bookend-open commit; phase-end SHA = current origin/main HEAD). Run /codex:adversarial-review --background --base <phase-start-SHA>, poll via /codex:status, retrieve via /codex:result. Write the report under docs/workflow/code-reviews/<YYYY-MM-DD>-phase-<N>-adversarial-review.md. Categorize per IDC severity (critical → Blocker, high → Major, medium → Minor, low → Nit). SendMessage me one APPROVE / FINDINGS telegram (≤ 8 lines) listing per-severity counts."
})
```

This gate OVERRIDES the `codex-result-handling` "stop and ask" default per `WORKFLOW.md §8.3`. On Blocker/Major findings → spawn a phase-close fix teammate (re-use `idc:idc-role-issue-implementer` with the adversarial-findings file as its brief input); on Minor/Nit + Codex `next_steps` → file to `docs/workflow/operator-todos/<phase-tag>-adversarial-followups.md` via `idc:idc-skill-file-operator-todo`. **Don't stop the train.**

## Phase 6 — Session-close + handoff

After the phase-close gate clears AND all implementer PRs merged to `$ORCH_BRANCH` via Variant B, open the session PR `--base main --head $ORCH_BRANCH` titled `build: close phase <N> — <pillar-set>`. After its per-PR review-fix-merge cycle clears (autonomous through reviewer APPROVED — a review-clean PR merges without a separate operator gate in an autonomous run):

**Wave-close doc-sync sweep:** before the handoff is written, aggregate every deferred doc-tense / cross-reference / enumeration-count item from the run ledger and this run's operator-todos into ONE consolidated change order routed through `idc-ripple` — one CO, many individually-checkable items, one verdict, at most one operator approval (zero when the `WORKFLOW.md §10.8` mechanical doc-sync class applies). Do NOT emit one change order per item; per-item COs at wave close are the F4/F5 operator-round-trip failure.

### Phase 6.0 — Pre-merge artifact sweep + codex-rescue worktree teardown (mandatory)

From inside `$ORCH_WT`, run `git status --short` and stage + commit any untracked or modified files under `docs/workflow/code-reviews/`, `docs/workflow/operator-todos/`, `docs/workflow/audits/`, `docs/workflow/handoffs/`, `docs/workflow/ledgers/`. Commit message: `chore(build): in-flight workflow artifacts for $SLUG`. Push to `$ORCH_BRANCH`. Per `WORKFLOW.md §9.1` step 4.5 — the 2026-05-17 audit found 9 such orphans from PRs #163 / #164 / #166.

Then sweep any orphan codex-rescue worktrees for this repo per `WORKFLOW.md §9.3` codex-rescue teardown — the third-party `codex-rescue` plugin creates worktrees under `~/.codex/worktrees/<id>/<repo>/` and does NOT auto-teardown, so any rescue passes during this session must be reaped now:

```bash
for w in "$HOME"/.codex/worktrees/*/"$(basename "$MAIN")"; do
  [ -d "$w" ] || continue
  head=$(git -C "$w" rev-parse HEAD 2>/dev/null)
  if git merge-base --is-ancestor "$head" main 2>/dev/null; then
    git worktree remove "$w" && rmdir "$(dirname "$w")" 2>/dev/null || true
  else
    echo "UNMERGED codex worktree: $w (HEAD $head) — surface to operator"
  fi
done
git worktree prune
```

Surface any `UNMERGED codex worktree:` lines to the operator in the Phase 6 handoff rather than auto-deleting.

### Phase 6.1 — Variant A close

Execute Variant A from `WORKFLOW.md §9.2` from the main checkout:

```bash
cd "$MAIN" && \
  gh pr merge "$ORCH_PR_NUM" --squash --delete-branch && \
  git pull --ff-only && \
  git worktree remove "$ORCH_WT" && \
  git worktree prune && \
  git branch -D "$ORCH_BRANCH" && \
  git fetch --prune
```

`gh pr merge` ignores `git -C`; `cd "$MAIN"` first is load-bearing. The trailing `git fetch --prune` reaps the stale `origin/$ORCH_BRANCH` remote-tracking ref left after `--delete-branch` per `WORKFLOW.md §9.2` Banlist.

Then write the handoff at `docs/workflow/handoffs/builds/<YYYY-MM-DD-HHMM>-<tag>.md` opening with the R6 Phase A auto-advance frontmatter (`role: build`, `next_role: build`, `auto_advance_eligible`, `auto_advance_reason`, `open_questions`, `blocking_todos`, `pipeline: codebase`). Q-build-1 binding: Build is the only IDC role that auto-pushes the handoff AND updates the Tracker `## Active Handoff` pointer (via `idc:idc-skill-tracker-adapter`) in the same logical operation. Handoff body schema lives in the runbook.

### Closeout fence re-run

As the final step in closeout (after the handoff write, before `TeamDelete`), re-run `tests/test_arch_doc_layout.py` and the governance-fence subset (architectural fitness tests under `tests/test_arch_*.py`) against the run's produced artifacts. Any fence-red caused by this run is a halt — file a follow-up rename/repair instead of marking the run clean. Pre-existing fence reds must be cited by `file:line` at run-start (Phase 0's bootstrap-researcher captures them into the run ledger) so the closeout pass can distinguish "this run caused X" from "X was already red." A fence-red whose `file:line` appears in the run-start citation list does NOT halt closeout; a fence-red whose `file:line` is new to this run does.

Run §Cleanup Checklist before `TeamDelete`.

## Phase 7 — Autowave loop (only when `--autowave` active)

Triggered only when `AUTOWAVE_MODE=true` AND the Phase 6 handoff has been written + pushed. Phase 7 is the loop driver that re-invokes `/idc:build` for the next eligible wave without operator intervention. When `AUTOWAVE_MODE=false`, this section does not fire.

### Step 0 — Arm the loop driver

On the FIRST autowave iteration of a session (once per session, before Step 1 runs), arm a `/loop` driver as the self-resume safety net:

```text
/loop /idc:build --autowave --resume
```

Self-paced, with a 60-minute long-fallback wakeup. Wakeup semantics:

- **Iteration healthy** (liveness probes pass, recent teammate telegrams observed) → no-op; reschedule the next wakeup.
- **Stall signature** (no progress since the prior wakeup AND teammates idle/paused — the account-usage-limit signature) → re-drive: resend pending SendMessages, respawn dead teammates per the zombie protocol.
- **Iteration complete** → proceed through the existing Steps 1–5.

State note: an account-usage-limit pause freezes the whole session; the first `/loop` wakeup that fires after the limit window resets auto-resumes the run with no operator action.

Boundary: do NOT use `/loop` where SendMessage signaling already works — Phases 2–4 (implementer spawns, telegram routing, integration verify) are unchanged. The loop driver exists for cross-iteration re-invocation and stall recovery only.

### Step 1 — Read just-written handoff frontmatter

The Phase 6 handoff at `docs/workflow/handoffs/builds/<YYYY-MM-DD-HHMM>-<tag>.md` carries the autowave-extended frontmatter (per `${CLAUDE_PLUGIN_ROOT}/agents/idc-build-runbook.md §Auto-advance frontmatter`):

```yaml
---
role: build
next_role: build | sequence | ripple
auto_advance_eligible: true | false
auto_advance_reason: <one-line>
open_questions: <int>
blocking_todos: <int>
pipeline: codebase
handoff_kind: wave-close | rotation | pause
paused_at_phase: <0-7>            # optional; only when handoff_kind != wave-close
resume_command: <one-line>        # optional; required when handoff_kind = rotation
autowave_remaining_waves: <int | -1>
autowave_session_id: <datestamp>
---
```

Read all keys (seven core + `handoff_kind` and its optional companions + the two autowave keys). Compute the BLOCKING operator-todo count from `blocking_todos` (mirrors `docs/workflow/operator-todos/` BLOCKING items).

### Step 2 — Termination check

Halt autowave if any of these nine conditions hold:

1. `next_role: build` AND `auto_advance_eligible: false` → halt; surface operator decision via `§Open questions` from the just-written handoff.
2. `next_role: ripple` → halt; Ripple is operator-gated per `WORKFLOW.md §10`.
3. `blocking_todos > 0` → halt at the BLOCKING-todo precondition (matches the existing Build halt rule; the diagnostic teammate fills the operator-todo, the loop respects it).
4. `AUTOWAVE_REMAINING == 0` (after decrement) → cap reached; clean termination.
5. Tracker-drift detected (Step 3 below) → halt with `TRACKER_DRIFT_DETECTED`.
6. Phase 5 phase-close fixer failed after 3 attempts → halt (matches existing halt condition #6).
7. Operator interrupt (Ctrl-C, `/sum`, explicit message) → handled by the harness, not this section.
8. Tracker exhausted (per `promote_next_eligible_wave` returning `no_candidate (tracker-exhausted)`) → clean termination, not a halt.
9. Rotation budget reached (any trigger in `${CLAUDE_PLUGIN_ROOT}/agents/idc-build-runbook.md §Context-budget threshold`: completed iterations this session ≥ `AUTOWAVE_ROTATE_AFTER`, a context-compaction event / low-context warning, or self-reported saturation) → CLEAN termination, not a halt: update the just-written handoff to `handoff_kind: rotation` with `next_role: build`, `auto_advance_eligible: true`, `autowave_remaining_waves` preserved (not decremented), a `resume_command: /idc:build --autowave --resume` line, and a body §Pause state section — then exit so a fresh session can resume mechanically.

On any halt, disarm the Step 0 `/loop` driver — every termination condition, clean or halt, disarms the loop (rotation, condition 9, keeps the handoff's `resume_command` line as the fresh-session fallback) — then write the top-level autowave-session ledger entry (Step 5) and exit.

### Step 3 — Tracker-drift detection

Snapshot the current tracker state via the adapter and compare against the previous iteration's snapshot:

```text
Skill(skill="idc:idc-skill-tracker-adapter", args="op=export-state output=<autowave-session-dir>/tracker-snapshot-<iter>.json")
```

Diff against `<autowave-session-dir>/tracker-snapshot-<iter-1>.json` (if it exists). Allowed mutations between iterations:
- Status flips on the just-promoted wave (Pending → Active).
- ClaimState flips on just-merged wave items (Claimed/Running/Released cycle).
- Bookend labels on just-merged items.
- Wave/Phase/Lane unchanged on rows the just-merged wave touched.

Any other mutation (foreign Status writes, new items added not from a known Ripple, deleted items) → halt with `TRACKER_DRIFT_DETECTED`; write the diff to the autowave-session ledger.

### Step 4 — Diagnostic spawn (when `no_candidate`)

If Phase 4.5 returned `no_candidate (eligible-blocked)` OR `no_candidate (substrate-missing)` (recorded in the run ledger), spawn the diagnostic teammate:

```text
Agent({
  subagent_type: "idc:idc-role-wave-blocker-diagnostic",
  team_name: "idc-build-<slug>",
  name: "wave-blocker-diagnostic",
  mode: "bypassPermissions",
  prompt: "You are wave-blocker-diagnostic. Read your brief at <scratch_dir>/diagnostic-brief.md and your playbook at ${CLAUDE_PLUGIN_ROOT}/agents/idc-role-wave-blocker-diagnostic.md. Run the routine end-to-end (enumerate Pending waves, classify upstream blockers, write audit + BLOCKING operator-todo unless verdict is TRACKER_EXHAUSTED) and SendMessage me one TRACKER_EXHAUSTED / HALTED_AT_BLOCKING_TODO / RIPPLE_REQUIRED / SUBSTRATE_MISSING / BLOCKED telegram."
})
```

On the diagnostic's telegram, the autowave loop driver halts via the existing `blocking_todos > 0` precondition in Step 2 — NOT via the telegram itself (per the orchestrator context-discipline rule and the diagnostic's own §Halt decision boundary). The diagnostic files the BLOCKING todo; the loop respects it.

### Step 5 — Re-invocation OR clean termination

If no termination condition holds: decrement `AUTOWAVE_REMAINING` (skip if `-1`), then re-invoke `/idc:build` in the same session with a fresh Phase 0 (which reads the just-written handoff for hot-start state) — but ONLY if the context budget has headroom (no `§Context-budget threshold` trigger has tripped); otherwise rotate via Step 2 condition 9 instead of re-invoking. The next iteration is loop-driven via `--resume` — the Step 0 `/loop` driver's wakeup re-invokes `/idc:build --autowave --resume` if the session stalled or paused; in-session immediate re-invocation (as above) remains valid when the session is healthy. The bootstrap-researcher of the next iteration reads the handoff at `docs/workflow/handoffs/builds/<latest>.md` per its §Autowave-mode adjustments section. No in-memory state is passed across iterations — continuity comes from disk artifacts (plans, briefs, ledgers, handoffs).

Each iteration's Phase 4.5 invokes `idc:idc-skill-tracker-adapter op=complete_claimed_item` (per `§Phase 4.5 — Bookend mechanics`) for every issue Build claimed and merged in that iteration BEFORE invoking `promote_next_eligible_wave`. The autowave loop driver does not call `complete_claimed_item` directly — it is the Phase 4.5 contract, re-executed once per loop iteration. Iterations whose Phase 4.5 found nothing to complete (e.g., a no-op iteration that re-entered without merging new work) skip the `complete_claimed_item` calls and proceed to the rollover op directly.

If a termination condition holds: write the top-level autowave-session ledger at `docs/workflow/ledgers/<YYYY-MM-DD>-autowave-session-<AUTOWAVE_SESSION_ID>-ledger.md` summarizing each iteration's wave + halt reason. Disarm the Step 0 `/loop` driver (per Step 2 — no termination path leaves an armed loop behind; rotation keeps `resume_command` as the fallback). Run §Cleanup Checklist, then exit.

Full Phase 7 substrate detail (termination matrix, drift-detection invocation, iteration-cap shape) lives in `${CLAUDE_PLUGIN_ROOT}/agents/idc-build-runbook.md §Phase 7 — Autowave loop`.

## Operator pause protocol

When the operator says "pause" (or equivalent) mid-phase, the parent writes a handoff with `handoff_kind: pause` and `paused_at_phase: <current phase>` — including the full body §Pause state section per `${CLAUDE_PLUGIN_ROOT}/agents/idc-build-runbook.md §Pause state` — BEFORE any cleanup or `TeamDelete`. Teammates are not shut down until the pause handoff is on disk; the handoff is what makes the resume mechanical instead of forensic.

## Non-Negotiables

- Parent reads telegrams, ledger headers, and ≤ 50-line implementer summaries only. Pillar plan / phase plan / canonical-doc bodies stay on disk — bootstrap-researcher digests + brief files are the parent's interface.
- Parent runs orchestrator-inlined shell directly when no already-alive teammate can absorb it (the 5-line Variant A chain at Phase 6, tracker gh project item-edit mutations at Phase 3 / 4.5 / 6). Pre-dispatch mechanical shell (orch branch push, bookend-open commits, brief SHA patching, GH labels, implementer worktree materialization) is fattened into the already-alive bootstrap-researcher (fatten an existing durable teammate with mechanical work rather than spawning a fresh one) — bootstrap is durable and pre-existing, not a new teammate. Spawning a FRESH teammate for mechanical shell remains forbidden.
- Parent does NOT implement code, review PRs, fix implementer work, resolve merge conflicts, or author handoff bodies mid-session (handoff is parent-authored only at Phase 6; per-PR reviews / fixes live inside implementer sessions).
- Implementer teammates set `/goal` before TDD, then spawn Task subagents internally (`superpowers:test-driven-development`, `/code-review-custom`, `simplify`, `/codex:adversarial-review`, `superpowers:receiving-code-review`) but MUST NOT spawn team-joining teammates (operator-is-lead). The goal drives iteration; `superpowers:test-driven-development` still owns TDD ordering evidence — failing test first, expected red, minimal green, optional refactor. Do not use `/goal` to skip red/green.
- Briefs go in files (≤ 30-line inline prompts pointing at the brief path); never inline a pillar plan / phase plan / canonical-doc body into a `TeamCreate` or `Agent` prompt (`WORKFLOW.md §14.1`).
- `TeamDelete` is config cleanup only — it does NOT signal processes or close cmux panes. §Cleanup Checklist is mandatory before any `TeamDelete` not preceded by the Phase 6 closeout path.

## Cleanup Checklist

Required for: `BLOCKED`, operator abort, bootstrap timeout, and any other exit path that does NOT complete the Phase 6 handoff.

1. Process check:

   ```bash
   ps aux | grep '@idc-build-<slug>' | grep -v grep
   ```

   Zero matches → continue. Non-zero → SIGTERM each PID, `sleep 2`, SIGKILL survivors.

2. cmux surface check:

   ```bash
   cmux tree --all
   ```

   Only the lead's pane in the team's workspace → continue. Extra teammate surfaces → close each by `cmux close-surface --surface surface:<N>` (note the `surface:` prefix; cmux uses a tmux-compatible backend but `tmux ls` is the wrong query).

3. Re-verify both queries return clean. Only then call `TeamDelete`. Full per-step rationale in `WORKFLOW.md §9.3`.

## Doctrine notes

Operator-is-lead; "agent" means a TeamCreate teammate, not a Task subagent (implementer work runs as a teammate with its own context and worktree); autonomous-by-default; file-based briefs + autonomous decisions; long reports to files; per-PR review-fix cycle; phase-close adversarial gate; plan bookends; 3-attempt ceiling; worktree merge single-shot; `cd` immediately after `git worktree add`; zombie teammate shutdown; silent spawn failure handling; autonomous through reviewer-approved gates; no `/tmp` for repo-persisted artifacts.
