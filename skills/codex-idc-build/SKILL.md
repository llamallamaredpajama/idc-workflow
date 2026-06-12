---
name: codex-idc-build
description: "Use when running the Codex-native IDC Build role for an IDC-governed repo."
---

# Codex IDC Build

## Runtime Contract

This is the Codex/pi adapter for the Claude Teams IDC Build playbook. The source-of-truth runbook is:

`../../agents/idc-build-runbook.md` (relative to this skill directory inside the idc-workflow plugin)

**Mandatory startup:** preserve the Build trampoline. The Codex parent does NOT read the runbook in full, active plans, Tracker bodies, PRD/spec/master-plan, or pillar/subphase plan bodies before bootstrap. The parent does only minimal repo/tool preflight, worktree isolation, and bootstrap spawn/entry; long reads move to `idc-role-bootstrap-researcher` (or the Codex-native equivalent bootstrap worker) and return as a compact telegram plus disk packet/brief paths.

Read `../../agents/idc-build-runbook.md` on demand only after bootstrap, and only for the specific downstream section needed (bookends, matrix gates, briefs, `/goal` recipes, PR ceremony, tracker writes, phase-close gates, worktrees, handoffs, resume, halts, anti-patterns, or doctrine notes). The runbook remains normative; it is not a startup substrate for the parent context.

Do not execute `../../agents/idc-build.md` from Codex. It is the Claude-side donor trampoline; its startup discipline is normative for Codex parity. Codex runs as the Build parent and must preserve the same observable contract without absorbing the donor agent body or runbook into parent context at startup.

**Parent responsibilities:** Phase 0 preflight, bootstrap/resume, dispatch readiness, per-issue worktree materialization, tracker bookend writes, worker routing, conflict escalation, phase-close gate, handoff + audit closeout.

**Worker responsibilities:** bounded implementation, tests, reviews, fixes, simplify/adversarial loops, PR merge attempt, bookend-close telegram. Workers read disk briefs first and keep replies compact.

Use `idc-codex-team` when durable local multi-worker coordination is available. If not available, execute the same worker loops sequentially in isolated worktrees; do not drop gates or merge obligations.

## Protocol Constants

These are invariants. **Never paraphrase, abbreviate, or omit any entry.**

**Tracker state machine — complete sequence, every transition required:**

```
Unclaimed → Claimed → Running → RetryQueued → Released
```

- `RetryQueued` is a mandatory intermediate state; it must appear explicitly in every state-transition description.
- No transition may be skipped, reordered, or merged with another.

**Bookend commit message format — exact wording, no alternatives:**

```
tracker: open Phase <N> Stage <M> bookend (attempt <n>)
tracker: close Phase <N> Stage <M> bookend (attempt <n>)
```

**Matrix dispatch-check CLI flag spellings — exact spelling required:**

| Correct | Wrong |
|---------|-------|
| `export-state` (subcommand, no `--`) | `--export-state` |
| `--tracker-state` | `--tracker-state-path` |
| `--pillar` | `--pillar-trace-key` |

## Authority

Allowed writes:

- Source, tests, and implementation artifacts for sequence-admitted pillar work only.
- `docs/workflow/operator-todos/`.
- Review reports under `docs/workflow/code-reviews/`.
- Build handoffs under `docs/workflow/handoffs/builds/`.
- Tracker bookend transitions via `idc-skill-tracker-adapter` only: `ClaimState`, lane pointer, and `attempt:<n>`.
- Scratch files under `/tmp/idc-build/<run-id>/`.

Forbidden writes:

- PRD, architecture spec, master implementation plan, subphase plans, pillar plans, root/per-directory `CLAUDE.md`, and `AGENTS.md`.
- Tracker scope, queue `Status`, or wave ordering. Sequence owns scope and `Status`; Build owns runtime `ClaimState` only.
- Direct `gh project item-edit` or direct `TRACKER.md` mutation from Build logic. Route through `idc-skill-tracker-adapter`.

## Substrate redirection — shared roleplayer agents loaded inline

Codex Build consumes the shared Claude roleplayer files instead of maintaining forked behavior. Read the applicable role file and inline its body into the worker prompt/brief at dispatch time:

- `../../agents/idc-role-bootstrap-researcher.md` — wave assessment, per-issue brief authoring, resume packet.
- `../../agents/idc-role-issue-implementer.md` — per-issue implementation + PR ceremony.
- `../../agents/idc-role-merge-deconflictor.md` — code-semantic merge conflicts only.
- `../../agents/idc-role-integration-verifier.md` — post-batch arch-fitness + repo-test sweep.
- `../../agents/idc-role-phase-close-adversarial-reviewer.md` — phase-close adversarial gate.

Do **not** use the old Codex-only `idc-role-writer` / `idc-role-fixer` split for normal Build. The runbook's issue-implementer owns writer, review, fix, simplify, adversarial, merge, and bookend-close loops inside one worker lifecycle.

Required skills at step boundaries:

- `idc-skill-matrix-dispatch-check` — mandatory pre-dispatch CLI gate.
- `idc-skill-tracker-adapter` — every bookend/retry/handoff pointer tracker mutation.
- `idc-skill-file-operator-todo` — Minor/Nit/INFO side jobs and operator-only actions.
- `idc-skill-ripple-verdict` + `idc-skill-drift-evidence` — upstream contradiction or stale matrix evidence.
- `idc-skill-planning-substrate` — brief-on-disk/thin-prompt discipline when available.
- `superpowers:test-driven-development`, `superpowers:receiving-code-review`, `superpowers:verification-before-completion`, `superpowers:systematic-debugging` — implementation/review/fix posture.
- `security-best-practices` when the brief's `[SEC]` flag is true.

## Procedure

### Phase 0 — Worktree isolation (MANDATORY)

Build must not run directly on `main`/`master`.

1. Self-check: `git branch --show-current` must not be `main` or `master`.
2. If on `main`, create and `cd` into an orchestrator worktree:
   ```bash
   git worktree add -b idc-build/<slug> .claude/worktrees/idc-build-<slug> main
   cd .claude/worktrees/idc-build-<slug>
   ```
3. Push the orchestrator branch and verify upstream before writer PRs target it.
4. Record branch/worktree in `/tmp/idc-build/<run-id>/codex-cleanup-manifest.md`.

Use the runbook's Variant B for per-issue writer PRs: writer branches target the orchestrator branch first; the orchestrator branch PRs to `main` once at session close.

### Startup trampoline and workflow steps

1. Perform only minimal preflight: confirm repo root, branch/worktree state, dirty tree status, and availability of the chosen Codex/team execution primitive. Do not read active plans, Tracker bodies, canonical docs, or the full runbook in this step.
2. If on `main`/`master`, create and enter the orchestrator worktree as above. Record branch/worktree in `/tmp/idc-build/<run-id>/codex-cleanup-manifest.md`.
3. Start bootstrap or resume through `idc-role-bootstrap-researcher` (or the Codex-native bootstrap worker) before any long reads. The bootstrap worker owns active-wave discovery, active handoff reads, root `CLAUDE.md`, `WORKFLOW.md`, touched subdir `CLAUDE.md` files, admitted pillar plan reads, matrix checks, evidence packet writing, and per-issue brief authoring.
4. Route only from the bootstrap telegram: `WAVE_DISPATCH_READY`, `WAVE_SERIAL_ONLY`, `WAVE_BLOCKED`, or `BLOCKED`. Parent context reads telegrams, packet paths, and brief paths; it does not inline-absorb pillar, phase, or canonical-doc bodies.
5. After bootstrap returns, read only the specific runbook section needed for the next downstream action. Never read the runbook in full as a parent bootstrap step.
6. Run `idc-skill-matrix-dispatch-check` before every pillar dispatch. Never read matrix YAML directly.
7. For each dispatchable issue, materialize writer worktree from the orchestrator branch and ensure the brief contains all required fields.
8. Dispatch `idc-role-issue-implementer` workers in parallel when matrix-safe; otherwise use the serial fallback loop.
9. Route worker telegrams only: `STARTED`, `MERGED`, `CONFLICT_BLOCKED`, `BOOTSTRAP_RESEARCH_NEEDED`, `BLOCKED`.
10. On conflict, spawn `idc-role-merge-deconflictor`; implementer idles until `RESUMED:`.
11. After all wave work drains, run `idc-role-integration-verifier`.
12. If the phase boundary closes, run `idc-role-phase-close-adversarial-reviewer`; auto-fix Blocker/Major, file Minor/Nit/INFO.
13. If implementation proves upstream drift, park affected pillar, draft Ripple proposal, and continue unaffected pillars.
14. Close with role-run audit if available, then Build handoff with auto-push and active-handoff tracker pointer update.

## Bookend protocol

Build writes runtime **claim-state** transitions, never queue `Status`.

Transition sequence (see Protocol Constants — must include every state):
`Unclaimed → Claimed → Running → RetryQueued → Released`

- **Bookend-open:** same logical operation as orchestrator bookend-open commit. Add labels `bookend-open,wave:<N>,attempt:<n>`, set `ClaimState=Claimed`, set `Lane=<lane>`, then `ClaimState=Running`.
- **Fix-loop retry:** replace prior `attempt:*` with `attempt:<n+1>`, set `ClaimState=RetryQueued`, then back to `Running` for the next merge attempt. Same-packet fix loops keep the original bookend attempt unless the runbook's retry rule says fresh dispatch.
- **Bookend-close:** after PR merge, close issue, set `ClaimState=Released`, and set lane pointer to `(idle)`.

Commit shapes (see Protocol Constants — exact wording required):

```text
tracker: open Phase <N> Stage <M> bookend (attempt <n>)
tracker: close Phase <N> Stage <M> bookend (attempt <n>)
```

Lane pointer is per-lane: one non-`(idle)` pillar per lane. `attempt:<n>` has single-value semantics.

Flag-spelling pins:

- `sync_github_tracker.py export-state` is a subcommand, not `--export-state`.
- `pillar_matrix.py` consumes `--tracker-state`, not `--tracker-state-path`.
- `pillar_matrix.py --dispatch-check` selects with `--pillar`, not `--pillar-trace-key`.

## Matrix dispatch-check CLI

Before dispatch, invoke `idc-skill-matrix-dispatch-check`. The skill wraps this required two-step sequence:

```bash
uv run python scripts/sync_github_tracker.py export-state --output "$TRACKER_STATE_PATH"
uv run python docs/workflow/scripts/pillar_matrix.py --dispatch-check \
  --pillar=<pillar-trace-key> --tracker-state="$TRACKER_STATE_PATH" --json
```

Verdicts:

- `safe` — dispatch may proceed.
- `blocked-by:<pillar-id>` — park affected pillar; choose another or wait.
- `conflicts-with-wave-member:<pillar-id>` — serialize; do not parallelize that pair.

If matrix evidence appears stale or wrong, Build drafts `/tmp/idc-build/<run-id>/ripple-proposal-matrix-<pillar>.md`, routes operator to `idc-ripple`, and keeps unaffected work moving.

If all candidates conflict only with wave peers and none are externally blocked, enter `WAVE_SERIAL_ONLY`: pick one deterministic issue, dispatch N=1, merge it, ask bootstrap to reassess, repeat until the wave drains or a true halt verdict appears.

## Per-issue brief schema

Bootstrap writes one disk brief per dispatchable issue before worker spawn:

`~/.claude/projects/<governed-repo-project-slug>/briefs/<YYYY-MM-DD>-<phase-stage-tag>/issue-<N>.md`

Required fields:

- `issue_number`
- `pillar_trace_key`
- `pillar_plan_path`
- `worktree_path`
- `branch`
- `base_branch` — orchestrator branch, not `main`
- `bookend_open_sha`
- `file_surfaces`
- `tests_required`
- `goal_recipe`
- `skill_matrix`
- `[SEC]` flag
- `bootstrap_research_pointer`

Optional: `pr_title`, `pr_body_template_path`, `bookend_close_tracker_target`, `loop_index_initial`.

The worker prompt is a thin pointer to this brief. Workers read the brief first and read pillar-plan/bootstrap slices on demand, not whole canonical bodies.

## `/goal` recipe template

Each implementer starts with exactly one goal-equivalent loop. In Claude this is `/goal`; in Codex encode the same stop condition in the worker brief and enforce it in the parent. The shape is the six-element completion contract — identical to the Claude path's `../../agents/idc-build-runbook.md §`/goal` recipe template` — so a Codex Build run loops against the same complete contract, catching scope-creep (`[BOUNDARIES]`) and neighbor-regression (`[CONSTRAINTS]`) mid-loop rather than only at a post-hoc halt check.

Canonical recipe:

```text
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

`[CONSTRAINTS]` is harvested from the pillar plan's `## Exit criteria` block; `[BOUNDARIES]` is derived from its `## Pillar Resource Ownership` table. Default ceiling is 12 evaluator turns (`[BLOCKED-STOP]`). Three failed attempts on the same finding cluster halt that worker with `BLOCKED: review_fix_ceiling`. The `[ITERATION POLICY]` element is orthogonal to the TDD red→green→refactor ordering (per the per-PR ceremony below) and to the cap-3 fix ceiling — never a replacement. This is portable plain text — no Workflow or `/goal`-tool dependency; Codex encodes the same stop condition in the worker brief.

## Per-PR ceremony — INSIDE the implementer's session

The issue-implementer owns the PR lifecycle:

1. Enter `worktree_path`; verify branch, upstream base, and baseline tests.
2. Use TDD: red test → expected red → minimal green → refactor, committing in order.
3. Open PR against `base_branch` with `Closes #<N>`, TDD ordering, tests, security section when `[SEC]`.
4. Run `code-review-custom` and read the findings file.
5. Fix Blocker/Major via receiving-code-review posture; cap at 3 loops per finding cluster.
6. Run simplify; apply material findings; file cosmetic findings to operator-todos.
7. Run Codex adversarial review as `/codex:adversarial-review --background --base <bookend_open_sha>`; the literal `--background` flag is mandatory so the command cannot surface an execution-mode `AskUserQuestion`. Map severities: `critical→Blocker`, `high→Major`, `medium→Minor`, `low→Nit`, `next_steps→INFO`.
8. Merge with Variant B single-shot: remove writer worktree before `gh pr merge --delete-branch`, then fetch and fast-forward the orchestrator branch.
9. On merge conflict: send `CONFLICT_BLOCKED`, do not touch conflicted files, await parent deconflictor.
10. On merge success: perform bookend-close, send ≤8-line `MERGED` telegram, stand down.

## Tracker state-transition writes (GitHub backend + filesystem fallback)

All writes go through `idc-skill-tracker-adapter`:

```text
Skill(skill="idc-skill-tracker-adapter", args="op=bookend_open issue=<N> attempt=<n> pillar=<key> lane=<lane>")
Skill(skill="idc-skill-tracker-adapter", args="op=retry_park issue=<N> attempt=<n+1>")
Skill(skill="idc-skill-tracker-adapter", args="op=bookend_close issue=<N> pillar=<key>")
```

GitHub backend emits `gh issue` / Projects V2 mutations. Filesystem fallback edits `TRACKER.md ## Implementation Wave Queue` equivalently and commits tracker-only bookend commits. Hooks remain mandatory; never use `--no-verify`.

## Phase-close adversarial gate

Run when all stage PRs have merged, bookend-close landed, blocking operator actions are zero, arch-fitness fences are green, and the phase boundary closes.

1. Compute phase delta: phase-start SHA = first stage bookend-open; phase-end SHA = current post-merge head.
2. Dispatch `idc-role-phase-close-adversarial-reviewer` to run `/codex:adversarial-review --background --base <phase-start-SHA>` and write `docs/workflow/code-reviews/<YYYY-MM-DD>-phase-<N>-adversarial-review.md`.
3. Map severities with the same vocabulary as per-PR adversarial review.
4. Auto-fix Blocker/Major through issue-implementer in `phase-close-fixer` mode.
5. File Minor/Nit/INFO to operator-todos; do not block phase close.

All Build invocations of `/codex:adversarial-review` must include either `--background` or `--wait`; bare invocations are forbidden because they ask the operator to choose an execution mode. This gate overrides any default "present findings and stop" behavior. Keep the train moving unless a Blocker/Major cannot be fixed within cap-3 or contradicts canonical contract.

## Worktree mandate (§9.2 Variant B)

Branch namespace:

- Orchestrator: `idc-build/<slug>` at `.claude/worktrees/idc-build-<slug>/`.
- Writers: `idc-build-writer/<slug>/<issue-N>` at `.claude/worktrees/idc-build-<slug>-writer-<N>/`.

Materialize writers from the orchestrator branch before worker spawn:

```bash
ORCH_BRANCH=$(git -C "$ORCH_WT" branch --show-current)
ORCH_SLUG="${ORCH_BRANCH#idc-build/}"
git -C "$ORCH_WT" push -u origin "$ORCH_BRANCH"
for ISSUE_N in $ISSUE_NUMBERS; do
  WT=".claude/worktrees/idc-build-$ORCH_SLUG-writer-$ISSUE_N"
  BRANCH="idc-build-writer/$ORCH_SLUG/$ISSUE_N"
  git worktree add -b "$BRANCH" "$WT" "$ORCH_BRANCH"
done
```

Variant B writer merge:

```bash
git -C "$ORCHESTRATOR_WORKTREE_PATH" rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null && \
  cd "$MAIN" && \
  git worktree remove "$worktree_path" && \
  gh pr merge "$PR_NUM" --squash --delete-branch && \
  git fetch origin && \
  git checkout "$base_branch" && \
  git pull --ff-only
```

Variant A session-close merge:

```bash
cd "$MAIN" && \
  gh pr merge "$ORCH_PR_NUM" --squash --delete-branch && \
  git pull --ff-only && \
  git worktree remove ".claude/worktrees/idc-build-<slug>" && \
  git worktree prune && \
  git branch -D "idc-build/<slug>"
```

`gh pr merge` ignores git `-C`; always `cd "$MAIN"` first. For writer PRs, remove the writer worktree before `--delete-branch`.

## Handoff schema

Every Build run writes:

`docs/workflow/handoffs/builds/<YYYY-MM-DD-HHMM>-<tag>.md`

Frontmatter keys and order are load-bearing:

```yaml
---
role: build
next_role: build
auto_advance_eligible: true
auto_advance_reason: <one-line if false>
open_questions: 0
blocking_todos: 0
pipeline: codebase
---
```

Body sections:

- `§Pick up here`
- `§What just landed`
- `§Verification (drift detection for resume)`
- `§Open questions / operator decisions pending`
- `§Notes for resume`

Build uniquely auto-pushes its handoff and updates the Tracker `## Active Handoff` pointer via `idc-skill-tracker-adapter` in the same logical operation. Other IDC roles do not.

## Resume mode

On `/idc:build --resume` or `RESUME:`:

1. Fetch the canonical Active Handoff pointer via `idc-skill-tracker-adapter`.
2. Read the active handoff in full.
3. Run its verification stanza: fetch/prune, inspect commits since recorded HEAD, worktrees, status, memory files, optional fences, operator-todo BLOCKING count.
4. Dispatch bootstrap-researcher in resume mode.
5. Continue only if drift report matches the handoff; otherwise halt `BLOCKED` with evidence.

## Halt conditions

Halt only on:

1. Worker/team primitives unavailable and no sequential isolated fallback can preserve gates.
2. Repo root invalid or git status fails.
3. Bootstrap returns `NEEDS_BUILDOUT`, `TOP_LEVEL_REPLAN_REQUIRED`, `SCAFFOLD_ONLY`, or `BLOCKED` for every wave candidate.
4. Implementation evidence contradicts pillar/upstream canonical docs; file Ripple.
5. Per-PR review/fix loop hits 3 attempts on the same finding cluster.
6. Phase-close Blocker/Major cannot be fixed in 3 loops.
7. Operator says stop/wrap/halt/`/sum`.
8. Context-budget threshold requires handoff.

Do not halt on Minor/Nit/INFO findings, merge conflicts, routine verifier hiccups, or single-pillar matrix blocks when other pillars remain dispatchable.

## Anti-patterns

- Implementers spawning team-joining teammates.
- Absorbing whole pillar-plan bodies into worker context.
- Editing canonical docs from Build.
- Editing Tracker scope or queue Status.
- Skipping bookend-close.
- Auto-merging with Blocker/Major outstanding.
- Looping past cap-3.
- Using `--no-verify` / `--no-gpg-sign`.
- Running `gh pr merge` from a writer worktree or before removing the writer worktree.
- Halting on Minor/Nit/INFO.
- Resolving merge conflicts inside the implementer session instead of routing to merge-deconflictor.

## Doctrine notes

Carry these durable Build behaviors forward in Codex form (each is embodied
elsewhere in this skill and in the runbook):

- **Team-spawn constraint** — spawn teammates only via TeamCreate + Agent (with `team_name`); an implementer never spawns team-joining teammates.
- **Don't stop the train** — keep work moving on Minor/Nit/INFO findings, routine verifier hiccups, and single-pillar matrix blocks; halt only per §Halt conditions.
- **cd into the worktree immediately** — `git worktree add` does not change shell pwd, so `cd` into the new worktree before any work.
- **3-attempt ceiling** — stop after 3 failed attempts on the same hypothesis / finding cluster and report attempted paths + evidence + the blocker.
- **Worktree merge from main** — run `gh pr merge` from the main checkout (it ignores `git -C`); for writer PRs remove the writer worktree before `--delete-branch`.
- **PR review→fix protocol** — read the findings file, fix Blocker/Major via receiving-code-review posture, cap at 3 loops per finding cluster.
- **Orchestrator context discipline** — read telegrams, packet paths, and brief paths only; never inline-absorb pillar / phase / canonical-doc bodies into parent context.
- **Teammates for large-scale work** — use durable teammates (TeamCreate + Agent with `team_name`), never Task subagents, for parallel scale — Task subagents cannot hold durable context, coordinate with peers, or be messaged mid-run.
- **Save long reports to files** — write long reports to disk and pass paths, not bodies.
- **Bookend tracker commits** — open/close tracker bookend commits around each stage of plan execution.
- **Phase-close adversarial gate** — run the phase-close adversarial gate before closing a phase boundary.
- **Guard silent teammate-spawn failure** — verify every teammate spawn actually succeeded before relying on it.

## Output Requirements

Build closeout must report:

- Admitted pillar(s), issue(s), and tracker trace key(s).
- PRs, merge SHAs, bookend-open/bookend-close references.
- Files changed.
- Tests/checks/reviews run with paths to long reports.
- Operator todos created/closed and blocking count.
- Ripple obligations or parked pillars.
- Handoff path, cleanup manifest path, and whether cleanup remains required.
- Next safe IDC role or next tracker item.

## Codex parity notes

Parity means observable Build outcomes match the runbook: same tracker state transitions, same dispatch gates, same per-issue briefs, same review/fix/simplify/adversarial loop, same worktree merge order, same phase-close gate, same handoff frontmatter, same resume drift checks, same halt envelope.

If this skill and `../../agents/idc-build-runbook.md` disagree, follow the runbook and update this skill before proceeding.

## Branch and worktree cleanup

Record cleanup state at session start:

```markdown
# Codex cleanup manifest — codex-idc-build
- branch: idc-build/<slug>
- worktree_path: .claude/worktrees/idc-build-<slug>/
- main_checkout: <governed-repo>
- pushed_at: <timestamp-if-pushed>
- writer_worktrees:
  - issue: <N>
    branch: idc-build-writer/<slug>/<N>
    worktree_path: .claude/worktrees/idc-build-<slug>-writer-<N>/
```

On normal completion, use the Variant A session-close merge pattern in §Worktree mandate and ensure writer worktrees have already been removed by their merge loops.

On abort/crash/operator stop, surface the manifest path and cleanup-required signal. Every SUCCESS/BLOCKED telegram must include:

```text
cleanup_manifest_path: /tmp/idc-build/<run-id>/codex-cleanup-manifest.md
cleanup_required: true|false
```

`cleanup_required:false` only if all merge/cleanup steps completed successfully.
