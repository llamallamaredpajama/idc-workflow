# Claude Execution Runbook — IDC Command Integrity Repair

**Purpose:** Give one Claude Code lead a deterministic way to implement the already-written repair plan with visible teammates, independent Codex review, durable progress, and no competing rewrite of the requirements.

**Canonical implementation plan:** [`docs/dev/2026-07-12-idc-command-integrity-and-external-intake-plan.md`](./2026-07-12-idc-command-integrity-and-external-intake-plan.md)

**Plan provenance:** The canonical plan and its forensic evidence were committed in `0a4a9df` (`docs: add IDC session forensics and remediation plan`).

This file is an **execution protocol**, not a second plan. The linked 1,645-line implementation plan is the sole source of requirements, exact values, file lists, tests, task boundaries, and stop conditions. If this runbook and that plan ever disagree, the plan wins and the lead must report the conflict before changing code.

## One-line prompt to give Claude

```text
Read docs/dev/2026-07-12-idc-command-integrity-claude-execution-runbook.md in full, then execute it end-to-end. Its canonical and sole implementation spec is docs/dev/2026-07-12-idc-command-integrity-and-external-intake-plan.md; do not replace, summarize away, or reinterpret that plan.
```

## Non-negotiable operating contract

You are the lead/controller for this implementation.

1. Read the canonical plan completely before dispatching any work.
2. Execute Tasks 1 through 8 in the plan, in order. Do not parallelize implementation tasks.
3. Mechanically extract each task brief from the canonical plan. Do not hand-author a substitute task specification.
4. Allow exactly one implementation writer at a time.
5. Require test-first development, a task-scoped independent review, and a clean review loop before starting the next task.
6. Keep progress in Git and `.superpowers/sdd/progress.md`; never rely on chat memory as the record of completion.
7. Use cmux only as the visible, detached process surface. Never run `codex exec`, `claude -p`, or another long-running agent as a foreground child of the lead.
8. Do not run IDC as the outer controller for repairing IDC. In particular, do not use `/fullauto-goal`, `/idc:autorun`, or another nested autonomous workflow around this plan.
9. Do not permit direct tracker or merge improvisation. Follow the plan's sanctioned helper boundaries.
10. Do not merge, push, publish, update issue `#106`, work on issue `#154`, or repair live `knowledge-engine` state. Task 8 explicitly stops at committed, verified branch work pending separate operator authorization.

## Runtime layout

Use these roles:

| Role | Runtime | Responsibility |
|---|---|---|
| Lead/controller | Claude Opus, `xhigh` | Own the plan, sequence, ledger, handoffs, review adjudication, and final receipts. Avoid implementation edits while a teammate owns a task. |
| Task implementer | One fresh Claude teammate | Implement exactly one task with test-first development, commit it, self-review, and write a report file. |
| Task reviewer | One fresh detached Codex session, read-only | Review the complete task range for both plan compliance and code quality. Make no edits. |
| Final reviewer | One fresh detached Codex session, read-only | Review the whole implementation branch against the canonical plan. |
| Hook-fidelity verifier | Fresh sandbox-rooted Claude Code session | Prove the real `UserPromptExpansion` hook in Task 8; only after the operator confirms Anthropic spend headroom. |

Model allocation:

| Plan task | Implementer model |
|---|---|
| Tasks 1, 4, and 5 | Sonnet, `high` |
| Tasks 2, 3, 6, and 7 | Opus, `xhigh` |
| Task 8 | Opus, `xhigh`, with the lead closely supervising integration and release proof |
| Every Codex review | Explicitly use the current configured strongest reviewer model with `xhigh` reasoning effort — NOT `max` (operator directive 2026-07-16: max overthinks on review work); on this machine at authoring time, `gpt-5.6-sol` |

Do not keep eight teammates alive. Create one implementer for the current task, review that task, close or release the task panes, then create the next fresh implementer. More simultaneous writers would increase merge risk and weaken the exact task boundaries.

## Required skills

Before implementation, read and follow the current installed versions of:

- `superpowers:subagent-driven-development` — primary controller loop.
- `superpowers:using-git-worktrees` — workspace isolation and baseline proof.
- `superpowers:test-driven-development` — mandatory for every implementer.
- `superpowers:requesting-code-review` — review gate contract.
- `superpowers:verification-before-completion` — evidence before completion claims.
- `superpowers:finishing-a-development-branch` — final verification and handoff only.
- `cmux` and its multi-agent patterns reference — detached launch and visible-team rules.

The plan already exists, so do not invoke brainstorming or write a replacement plan. `superpowers:executing-plans` may be consulted for its critical preflight and blocker rules, but use `subagent-driven-development` as the active execution method because Claude teammates are available.

At the end, `finishing-a-development-branch` must not override the canonical plan's stop boundary. The allowed outcome is to keep the verified feature branch and worktree intact for the operator. Do not merge, push, or discard it.

## Workspace and startup

The lead must run inside an isolated worktree. Detect existing isolation first, as required by the worktree skill.

If the session was started with Claude's native `--worktree` support, keep that worktree. Do not create another one.

If no native isolated workspace exists and manual fallback is required, the verified project-local location is `.worktrees/`, which is already ignored:

```bash
git check-ignore -q .worktrees
git worktree add .worktrees/idc-command-integrity -b feat/idc-command-integrity
```

Never start implementation on `main`.

From the isolated worktree:

```bash
git status --short --branch
git log -3 --oneline
test -f docs/dev/2026-07-12-idc-command-integrity-and-external-intake-plan.md
git merge-base --is-ancestor 0a4a9df HEAD
bash scripts/lint-references.sh
bash tests/smoke/run-all.sh
```

Record the starting commit and paths:

```bash
IMPLEMENTATION_BASE="$(git rev-parse HEAD)"
WORKTREE="$(git rev-parse --show-toplevel)"
PLAN="$WORKTREE/docs/dev/2026-07-12-idc-command-integrity-and-external-intake-plan.md"
```

If the baseline lint or smoke suite fails, stop before implementation and report the exact failure. Do not blur a pre-existing failure into the repair branch.

Check for a durable progress ledger before dispatching Task 1:

```bash
SDD="$WORKTREE/.superpowers/sdd"
if test -f "$SDD/progress.md"; then
  cat "$SDD/progress.md"
fi
```

If the ledger contains completed tasks, verify the named commits with `git log` and resume at the first incomplete task. Never repeat a task merely because the conversation was compacted or restarted.

## Preflight plan review

Before Task 1:

1. Read the canonical plan from beginning to end.
2. Confirm it still contains Tasks 1 through 8 and its final stop condition.
3. Scan once for contradictions between tasks, global constraints, and repo instructions.
4. If a genuine contradiction would change implementation, present all such conflicts to the operator in one batch with exact plan references. Do not begin code until they are resolved.
5. If there is no blocking conflict, proceed continuously without asking whether to continue between tasks.

Do not turn this review into another architecture exercise. The plan was written from the incident forensics and is intentionally detailed.

## Exact per-task loop

Repeat this loop for plan Tasks 1 through 8, strictly serially.

### 1. Derive the brief from the real plan

Record the task base before any writer starts:

```bash
TASK_BASE="$(git rev-parse HEAD)"
```

Use the `task-brief` helper from the installed `superpowers:subagent-driven-development` skill:

```text
task-brief "$PLAN" <task-number>
```

Use the printed brief path as the task's sole detailed requirements source. The dispatch may add only:

- one sentence explaining where this task fits;
- interfaces already produced by earlier completed tasks;
- a resolution to an ambiguity already found during preflight;
- the report-file path and report format.

Do not paste earlier task histories or rewrite the task's exact values in the dispatch.

### 2. Dispatch one fresh implementer

The implementer must:

1. Read `AGENTS.md`, `CLAUDE.md`, its task brief, and only the directly relevant source files.
2. Invoke `superpowers:test-driven-development` before editing production code.
3. Follow every checklist item in the extracted task brief.
4. Demonstrate the planned red state before implementation, then green focused tests, then the task's broader checks.
5. Avoid unrelated cleanup and preserve existing user work.
6. Commit the task using the plan's stated commit step and a Conventional Commit message.
7. Write a durable report beside the brief containing:
   - status: `DONE`, `DONE_WITH_CONCERNS`, `NEEDS_CONTEXT`, or `BLOCKED`;
   - files changed;
   - commits created;
   - every verification command and its result;
   - self-review findings;
   - remaining concerns or unverified behavior.

The implementer returns only the status, commit range, one-line test summary, and concerns to the lead. Full detail belongs in the report file.

If the implementer returns `NEEDS_CONTEXT` or `BLOCKED`, follow the subagent-development skill's escalation rules. Do not force the same approach through an unresolved blocker.

### 3. Freeze writes and package the complete task range

When implementation is reported complete:

```bash
TASK_HEAD="$(git rev-parse HEAD)"
```

Verify that `TASK_BASE..TASK_HEAD` contains the expected task commit or commits. Do not use `HEAD~1`; a task may contain multiple commits.

Run the installed skill's `review-package` helper:

```text
review-package "$TASK_BASE" "$TASK_HEAD"
```

Keep all writers idle until review is clean.

### 4. Launch one independent Codex reviewer, detached and read-only

Write a reviewer prompt file under `.superpowers/sdd/`. It must tell Codex to read:

1. the task brief;
2. the implementer report;
3. the generated review package;
4. the canonical plan's Global Constraints;
5. `AGENTS.md` and `CLAUDE.md` for repo rules.

The reviewer contract is:

```text
Review only. Do not edit files, create commits, mutate GitHub, or change the worktree.
Judge both (1) exact compliance with the task brief and canonical plan and (2) code/test quality.
Trace real call paths. Treat tests that do not prove the claimed behavior as defects.
Return concrete findings with severity and file:line evidence, followed by two explicit verdicts:
- Spec compliance: PASS or FAIL
- Task quality: APPROVED or CHANGES REQUIRED
If evidence is outside the diff, label it Cannot verify and explain exactly what is missing.
Do not restate the implementation report.
```

Launch it in its own cmux workspace. The command shape is:

```bash
cmux new-workspace \
  --name "idc-review-task-${TASK_NUMBER}" \
  --cwd "$WORKTREE" \
  --command "codex exec --ephemeral --sandbox read-only -m gpt-5.6-sol -c 'model_reasoning_effort=\"xhigh\"' -C '$WORKTREE' -o '$SDD/task-${TASK_NUMBER}-review.md' - < '$SDD/task-${TASK_NUMBER}-review-prompt.md'"
```

This is intentionally a flat, detached launch. Do not run that `codex exec` directly in the lead's foreground shell.

Monitor it with bounded cmux checks such as `cmux top`, `cmux list-workspaces`, and `cmux read-screen`. Read the review file when the process exits, then close the reviewer workspace when it is no longer needed.

### 5. Resolve findings before moving on

**Terminal posture (operator directive 2026-07-16, binds Tasks 6–8 and any re-run):** the finish
line is the incident, not perfection. A finding blocks only if it is a demonstrated, exploitable
failure of an incident-class behavior (stale runtime admitted; plan units dropped; closeout forged
with fake evidence; a failed read counted as a pass; a gate closed without proof) with a concrete
repro an agent would naturally hit. Everything else is deferred hardening — ledger/known-debts,
no fix wave. Reviewers use exactly two severity buckets (`BLOCKS` with repro / `DEFERRED`), and
FAIL/CHANGES-REQUIRED verdicts are legal only when a BLOCKS finding exists. Hard cap: two
posture-governed review rounds per task; if the second still returns BLOCKS findings, stop and
bring the operator the list with a recommendation — no further wave without sign-off.

- Any `BLOCKS` finding, any `Spec compliance: FAIL`, or `Task quality: CHANGES REQUIRED` blocks the next task (subject to the terminal posture and round cap above).
- Send the complete finding set back to the same implementer for that task.
- The fixer must append its fix and focused test receipts to the existing report file and commit the fix.
- Generate a new review package from the original `TASK_BASE` to the new head.
- Re-run a fresh read-only review. Repeat until both verdicts pass.
- Record Minor findings in the progress ledger for the final whole-branch reviewer; do not silently discard them.
- If a review finding conflicts with a plan-mandated choice, present the finding and exact plan text to the operator. Neither the lead nor reviewer may silently overrule the plan.

### 6. Record durable completion

Only after the task review is clean, append a line like:

```text
Task N: complete (commits <base7>..<head7>, spec PASS, quality APPROVED, focused tests PASS)
```

Also record any deferred Minor findings. Commit history plus this ledger is the recovery map.

Then release the task's implementer/reviewer panes and begin the next task with a fresh implementer.

## Broad verification checkpoints

Focused tests run throughout. In addition:

- After Task 3: run `bash scripts/lint-references.sh` and `bash tests/smoke/run-all.sh`.
- After Task 6: run both again.
- After Task 7: run both again, including the plan's corrupt-gate repair fixture.
- During Task 8: run every release, smoke, eval, incident, sandbox, and documentation gate specified by the canonical plan.

Do not weaken, skip, or rewrite a gate merely to get green output.

## Sandbox and hook-fidelity split

Follow `CLAUDE.md` and `docs/dev/local-e2e-testing.md` at the time of execution.

### Ordinary sandbox end-to-end tests

The default sandbox driver is a **sandbox-rooted Codex run**, launched detached in its own cmux workspace. Point `PLUGIN_ROOT` at the candidate implementation worktree, not `main`. The Codex prompt must load the relevant IDC command and agent playbooks, use the sanctioned Python helpers for board operations, set the session ID required by the plan, and leave verbatim receipts in `/Users/jeremy/dev/sandbox/_idc-observability/`.

Codex can prove the normal lifecycle and can invoke hook scripts with synthetic payloads. It cannot prove that Claude Code itself fired a hook.

### Real `UserPromptExpansion` proof

Task 8 explicitly requires one real Claude Code hook proof in the update sandbox. A Codex run or piped synthetic hook payload is not a substitute.

Before launching a second Claude process, obtain explicit operator confirmation that Anthropic spend headroom is available. Then use a fresh sandbox-rooted Claude Code session loading the candidate worktree with `--plugin-dir`, following the current headless recipe in `CLAUDE.md` and the exact Task 8 steps. Capture the transcript and hook receipt in the observability directory.

If spend is not authorized or the real Claude run is unavailable, report Task 8 as blocked on hook-fidelity proof. Do not claim completion from synthetic evidence.

## Whole-branch review

After all eight task reviews are clean:

1. Re-run the complete verification set required by Task 8.
2. Generate one final review package from the recorded `IMPLEMENTATION_BASE` to the branch head.
3. Launch a fresh detached, read-only Codex reviewer on the strongest configured model.
4. Give it the canonical plan, final package, all task reports, the progress ledger, and the list of Minor findings.
5. Require exact findings plus an overall `READY` or `NOT READY` verdict.
6. If it returns findings, send the complete set to one fixer, re-run covering tests and broad gates, then obtain a fresh whole-branch review.

The final reviewer must specifically verify that the incident's failure modes are structurally blocked: stale runtime admission, hidden raw mutations, incomplete foreign-plan intake, dishonest closeout, unsafe gate ordering, and fake historical repair.

## Completion boundary

Completion means all of the following are true:

- Tasks 1 through 8 from the canonical plan are committed on the feature branch.
- Every per-task review has both required passing verdicts.
- The final whole-branch review says `READY`.
- All specified lint, smoke, eval, sandbox, hook-fidelity, and incident fixtures passed with saved receipts.
- The worktree is clean.
- The branch and worktree remain intact.

Then stop and report:

- feature branch and worktree path;
- task commit list;
- exact verification commands and outcomes;
- locations of sandbox/hook receipts;
- final review verdict;
- anything still unverified;
- the explicit fact that nothing was merged, pushed, published, repaired live, or closed on GitHub.

Do not merge, push, publish, mutate issue `#106`, touch issue `#154`, or run the live `knowledge-engine` repair until the operator separately authorizes each action.

## Operator launch recipe

Preferred launch uses Claude's native worktree support and cmux's teams shim:

```bash
cd /Users/jeremy/dev/proj/idc-workflow
cmux new-workspace \
  --name "idc-integrity-lead" \
  --cwd "/Users/jeremy/dev/proj/idc-workflow" \
  --focus true \
  --command "cmux claude-teams --worktree idc-command-integrity --model opus --effort xhigh"
```

When Claude opens, give it the one-line prompt at the top of this file.

If native worktree creation is unavailable, create the verified `.worktrees/idc-command-integrity` fallback first, then launch the same `cmux claude-teams --model opus --effort xhigh` command with that worktree as `--cwd`.
