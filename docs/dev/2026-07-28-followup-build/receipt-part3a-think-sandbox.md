# Part 3a — sandbox e2e receipt (/idc:think divergent risk pass)

**Driver:** direct `codex exec --cd /Users/jeremy/dev/sandbox/ke-idc-test-repo-install
--dangerously-bypass-approvals-and-sandbox` (per this repo's CLAUDE.md — NOT a nested claude, NOT the
codex-companion `task` wrapper).
**Plugin under test:** `PLUGIN_ROOT=/Users/jeremy/dev/proj/idc-workflow-part3` (the candidate branch
`followup/part3-think-divergent-and-doctrine` @ `e8dacb2`).
**Sandbox:** install sandbox, github backend, `pathway_enforcement.mode: controlled`, baseline commit
`fbfd107f`. **Capture:** `/Users/jeremy/dev/sandbox/_idc-observability/run-part3a-think.txt` (189 KB).
**Session label:** `part3a-think`.

## What was asked

The operator's idea plus an explicit request to stress-test it — which is the opt-in trigger the new
step 3 requires. Scoped deliberately to steps 1–4 plus Output steps 1–2 (write the consideration and
draft the PRD/TRD), stopping before Output step 3. The work order requires only that "the stress-test
branches fire and their digests land in the PRD draft"; a full lifecycle drain would add spend, not proof.

## (A) The branches fired — CONFIRMED

Exactly four branches ran, with the four distinct lenses the playbook names: `user-confusion`,
`broken-expectation`, `churn`, `promised-but-missing`. Each returned candidates in the exact fixed
four-field shape — `executable_check` appears 24 times across the capture. The candidates are
substantive and grounded in the sandbox's real contents, not generic: they cite actual file paths
(`sync_agent/pyproject.toml`, `functions/deploy.sh`, `services/agent/package.json`) and actual version
values found in the tree, and every `executable_check` is a runnable command.

Read-only and zero-durable-worker rules held: the run reports every branch was prohibited from writing
files, touching tracker/board state, using the network, or spawning workers; the worktree status was
identical before and after fan-out; no tracker/board writer appears in the tool trace.

## (B) The digests landed in the PRD draft — CONFIRMED

`docs/prd/2026-07-28-release-dry-run-prd.md` carries a dedicated `## Divergent risk pass digests`
section with one digest per lens, all four named. It sits inside the draft that Output step 3 would
gate — i.e. before the human gate, as input to it, exactly as the step requires. Digests only; no whole
branch bodies were pasted in.

## Guardrails held

No PR opened, no issue created, no board mutation, nothing pushed. Verified two ways: the sandbox's
`git log` is unchanged at `fbfd107f` with only untracked new docs, and `gh pr list` / `gh issue list`
show nothing newer than 2026-07-26 (two days before this run). The only two capture matches for
mutation-shaped commands are quotations of WORKFLOW.md prose, not invocations.

## Files the run produced (all untracked, none committed)

    docs/considerations/2026-07-28-release-dry-run-considerations.md
    docs/prd/2026-07-28-release-dry-run-prd.md
    docs/specs/2026-07-28-release-dry-run-spec.md

## Unprompted honesty worth recording

The sandbox has **no tracked release/version-bump script**, so the idea as posed had no real target.
Rather than inventing one, the run recorded that as an unresolved product boundary and handed it to
Plan as an open question — and said so in the PRD's "Current product boundary" and "Open decisions for
Plan" sections. That is the behaviour the pass is meant to produce, and it came from a runtime that did
not author the prose.

## HOOK-FIDELITY CAVEAT (must be stated in any report citing this receipt)

Claude Code hooks (PreToolUse / PostToolUse / Stop / SubagentStop / SessionEnd) do **not** fire inside a
Codex process. This receipt therefore proves the *playbook* is followable and produces the required
artifacts; it does **not** exercise the Claude hook spine. For this change that is adequate, because the
work order deliberately forbids machine enforcement for this pass — there is no hook or validator in
scope to exercise. Any claim about hook behaviour would need the hook scripts invoked directly with
synthetic payloads against the artifacts the run left.
