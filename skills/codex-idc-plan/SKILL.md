---
name: codex-idc-plan
description: "Use when running the Codex-native IDC Plan role for an IDC-governed repo: convert admitted considerations into the canonical planning chain (PRD/spec/master + subphase + pillar + matrix) in a single drafting pass through the Engineer Gate."
---

# Codex IDC Plan

## Runtime Contract

This is the Codex adapter for the Claude Teams `idc-plan` playbook. Do not edit
or invoke `../../agents/idc-plan.md` (relative to this skill directory inside the
idc-workflow plugin) from Codex. Use it only as the donor
contract for authority boundaries.

Plan replaces the prior Engineer + Develop + Deconflict trio per the workflow
consolidation (Phase 2 PR-4); see
`docs/workflow/code-reviews/2026-05-09-workflow-consolidation-design.md §D.1`
for the design rationale. The Plan role absorbs the cognitive work; matrix and
concurrency stay structural with Sequence.

Codex does not have Claude Teams teammates. Run this as a parent-led Codex
workflow with bounded Codex subagents. Do not model subagents as long-lived
tmux/cmux teammates. When spawning subagents, include the role boundary in the
prompt; do not assume a subagent has loaded this skill.

## Phase 0 — Worktree isolation (MANDATORY)

Before any absorption / drafting work begins, this skill must be running in an isolated worktree branched off `main`, not directly on `main`. The mandate matches the Claude IDC roles per `WORKFLOW.md §9.2 — Worktree mandate per role`; running any IDC role on `main` directly is forbidden so parallel sessions stay isolated.

1. **Self-check.** `git branch --show-current` MUST NOT return `main` or `master`. If it does, halt and either:
   - Instruct the operator to invoke this skill from a non-`main` starting branch, OR
   - Auto-create a worktree:
     ```bash
     git worktree add -b codex-plan/<slug> .claude/worktrees/codex-plan-<slug>
     cd .claude/worktrees/codex-plan-<slug>
     ```
   `cd` into the worktree immediately.
2. **Record at session start** — capture the branch + worktree path in `<scratch>/codex-cleanup-manifest.md` per §Branch and worktree cleanup below.
3. **Cleanup at session close** uses Variant A of `WORKFLOW.md §9.2` — see §Branch and worktree cleanup below.

Branch prefix is `codex-plan/<slug>`. Worktree path is `.claude/worktrees/codex-plan-<slug>/`.

## Three-phase shape

Plan runs as a single model session that absorbs scope, emits the cumulative
draft set, and gates only at PRD/arch-spec/master-plan merge. The full
phase contract lives in `../../agents/idc-plan.md`; mirror that shape
verbatim in the Codex parent.

| Phase | What happens |
|-------|--------------|
| **1 — Absorb scope** | Verify repo state, parse invocation inputs, read considerations + relevant canonical sections + sibling subphase/pillar plans inline (1M-context model holds it). Optional `idc-skill-planning-substrate` dispatch when scope > 1M. Considerations triage via `idc-skill-considerations-admissibility-review`. Pre-drafting Engineer Gate (PRD/spec only) via `idc-skill-planning-substrate` with `gate_mode: engineer, action: drafting`. Governance trace audit via `idc-skill-governance-trace-audit` for subphase/pillar runs. Prior-art pattern read via `idc-skill-prior-art-pattern-read`. |
| **2 — Emit** | Single drafting pass produces (in one model session): PRD/spec/master-plan diffs (when admitted; gated); subphase plans at `docs/plans/subphases/` (each with inline `§Rough Pillars` section); polished pillar plans at `docs/plans/pillars/` (each with `### Pillar Resource Ownership` table); pair-wise clash evidence at `docs/workflow/pillar-conflicts/` (only when clashes exist); polished matrix YAML at `docs/workflow/pillar-matrices/<phase-tag>-matrix.yaml` + 3 derived siblings (DAG / parallel-safety / waves). Per-PR review pass via `idc-skill-plan-review` + `idc-skill-plan-adversarial-review` on the cumulative draft. 3-loop ceiling on Blocker/Major findings via `idc-skill-plan-patch-from-findings`. |
| **3 — Pre-merge gate** | Pre-merge Engineer Gate via `idc-skill-planning-substrate` with `gate_mode: engineer, action: pre_merge`. PRD/arch-spec/master-plan admissions require operator approval; subphase/pillar/matrix-only PRs proceed under the standard per-PR review-fix-merge cycle. Master plan + subphase + pillar + matrix all in one PR (one commit ideal; chain-ordered acceptable when unreviewable). |

## The Engineer Gate (only operator gate this role surfaces)

Per the default-no-gate posture, the Engineer Gate is the only operator gate
Plan surfaces. All other proposed gates are rejected — the per-PR
`code-review-custom` reviewer, the phase-close `codex:adversarial-review`, and
`tests/test_arch_*.py` fences cover everything else.

| Edit surface | Pre-drafting gate | Pre-merge gate |
|--------------|-------------------|----------------|
| `docs/prd/prd.md` | **Required** | **Required** |
| `docs/specs/master-architectural-spec.md` | **Required** | **Required** |
| `docs/plans/master-implementation-plan.md` | None | **Required** |
| Subphase / pillar / matrix / clash-evidence / ownership tables | None | None |

The gate may be relaxed to pre-merge-only in a future PR if the both-gate
posture proves annoying. Master-plan-only behavior is the precedent for that
relaxation.

## Authority

Allowed writes:

- `docs/prd/prd.md` (gated; pre-drafting + pre-merge operator approval)
- `docs/specs/master-architectural-spec.md` (gated; pre-drafting + pre-merge operator approval)
- `docs/plans/master-implementation-plan.md` (gated; pre-merge operator approval)
- `docs/plans/subphases/<domain>-phase-<n>-subphase-<n>-<slug>-plan.md`
- `docs/plans/pillars/<domain>-phase-<n>-subphase-<n>-pillar-<n>-<slug>-plan.md`
- `docs/workflow/pillar-conflicts/<pillar-a>-<pillar-b>-pillar-conflicts.md`
- `docs/workflow/pillar-matrices/<phase-tag>-matrix.yaml` and the 3 derived siblings
- `docs/workflow/audits/<YYYY-MM-DD>-<slug>-planning-admission-audit.md`
- Handoff under the repo's current handoff convention, usually
  `docs/workflow/handoffs/{phases,subphases,pillars}/<YYYY-MM-DD-HHMM>-<tag>.md`
- Scratch files under `/tmp/idc-plan/<run-id>/`

Forbidden writes:

- Source code or tests
- TRACKER ordering / status (`idc-sequence`'s authority)
- `CLAUDE.md`, `AGENTS.md`, per-directory `CLAUDE.md` files (those route through `codex-idc-ripple`)
- PRD or arch-spec without operator approval BEFORE drafting AND BEFORE merge

If current repo instructions name different artifact paths, follow the repo
instructions and preserve this role's write boundary.

## Required traces

Every artifact carries an explicit upstream trace. Without a clean trace the
artifact is non-canonical and MUST NOT land:

- **PRD / arch spec / master plan diffs** — admission audit cites the considerations files absorbed and/or operator directive.
- **Subphase plans** — `Upstream Master Plan Domain/Phase:` field naming the admitted master-plan §Domain/§Phase.
- **Pillar plans** — three trace fields: `Upstream Subphase:`, `Upstream Master Plan Domain/Phase:`, `§Rough Pillars Source:`.
- **Clash evidence** — fixed-format header naming both pillar IDs.
- **Matrix YAML** — every row references a polished pillar ID.

Missing trace → halt and surface, not invent.

## Anti-patterns

- **Insert intermediate planning subagents between the parent and the work.**
  Plan does the cognitive work itself. Use Codex subagents only for genuinely
  context-heavy reads (codebase-context-curator when scope > 1M, plan
  adversarial-review). Do not chain "considerations triage subagent" →
  "governance audit subagent" → "subphase drafter subagent" →
  "pillar polisher subagent" — those are all skill calls Plan invokes inline.
- **No §Rough Pillars handoff ceremony.** Plan emits §Rough Pillars inline in
  subphase plans AND polishes them into pillar plan files in the same model
  session. The §Rough Pillars section is preserved as a durable trace from
  subphase to pillar (fence-pinned by
  `tests/test_arch_idc_workflow.py::test_subphase_and_pillar_trace_headers_exist`);
  only the inter-role handoff ceremony dies.
- **No §Wave-Orchestrator Handoff six-sub-section block.** That ceremony died
  with Develop's collapse. TRACKER placement recommendations live in the
  handoff body's §Pick up here / §Notes for resume sections.
- **Originate canonical scope.** Considerations admissions trace to a
  `docs/considerations/` file or operator directive; subphase plans trace to
  admitted master-plan §Domain/§Phase; pillar plans trace to a `§Rough Pillars`
  entry in their upstream subphase.
- **Edit TRACKER ordering.** Out of scope; Sequence's authority. Plan declares
  "downstream ripple plan" in PR body; Sequence admits to TRACKER.
- **Edit upstream docs directly when a clash proves them wrong.** File a
  Ripple change-order proposal at `/tmp/idc-plan/<run-id>/draft-ripple-<slug>.md`,
  park the affected pillar(s), surface to the operator. The Ripple process
  is the only path for upstream changes from Plan.
- **Skip the audit artifact for PRD/spec/master admissions.** Every admission
  run lands `docs/workflow/audits/<YYYY-MM-DD>-<slug>-planning-admission-audit.md`,
  even halt verdicts.
- **Auto-merge PRD/arch-spec PRs.** Pre-merge operator approval is a hard gate.
- **Surface gates other than the Engineer Gate.** Default-no-gate posture
  applies to every Plan run.

## Procedure

1. Capture the operator prompt + cwd + invocation flags
   (`--considerations <path>`, `--master-section "<domain>/<phase-N>"`,
   `--subphase <path>`, `--directive "<one-liner>"`, `--scope`, `--slug`).
2. Verify Codex subagent availability if the run will dispatch any (default:
   no dispatch — the 1M-context model holds the canonical chain inline).
3. Read scope inline: TRACKER substrate (GitHub Project N items via
   `gh project item-list` or `TRACKER-archive.md` for legacy grep), root +
   per-directory `CLAUDE.md`, the named master-plan section + adjacent sections,
   supporting considerations files, and live code/tests where the inputs make
   concrete claims. Optional dispatch: `idc-skill-planning-substrate`
   when scope > 1M.
4. Run considerations triage if the run absorbs landed considerations:
   `Skill(skill="idc-skill-considerations-admissibility-review")` per file.
   Reject-out-of-scope routes back to `codex-idc-think` for re-scoping.
5. Pre-drafting Engineer Gate (PRD/spec only):
   `Skill(skill="idc-skill-planning-substrate")` with
   `gate_mode: engineer, action: drafting`. ESCALATE → surface the
   boundary-language string and capture pre-drafting approval explicitly
   before Phase 2.
6. Governance trace audit for subphase/pillar runs:
   `Skill(skill="idc-skill-governance-trace-audit")`. Verdict ≠ `ADMITTED`
   → halt; route the operator to admit the upstream first.
7. Prior-art pattern read:
   `Skill(skill="idc-skill-prior-art-pattern-read")`.
8. Single drafting pass — emit the cumulative draft set to
   `/tmp/idc-plan/<run-id>/draft-*.md` (or `.yaml`) using the appropriate
   skills per artifact:
   - PRD/spec/master diffs: `idc-skill-canonical-doc-authoring` per target doc
   - Subphase plans: `idc-skill-canonical-doc-authoring` + `idc-skill-rough-pillars-section` per pillar
   - Pillar plans: `idc-skill-pillar-plan-shape` + `idc-skill-pillar-resource-ownership`
   - Clash evidence: `idc-skill-pillar-clash-analysis` + `idc-skill-clash-evidence`
   - Matrix YAML: `idc-skill-pillar-matrix-synth` (all three views)
9. Per-PR review pass — invoke
   `Skill(skill="idc-skill-plan-adversarial-review")` (Codex
   `/codex:adversarial-review` wrapper) and
   `Skill(skill="idc-skill-plan-review")` against the cumulative
   draft set. Blocker/Major union → invoke
   `Skill(skill="idc-skill-plan-patch-from-findings")` to emit a versioned
   next-draft. 3-loop ceiling. Minor/Nit findings file as side-jobs to
   `docs/workflow/operator-todos/`.
10. Audit artifact for PRD/spec/master admissions:
    `Skill(skill="idc-skill-canonical-admission-audit", args="mode=audit-write")`
    (formerly `idc-skill-engineering-admission-audit-write`; folded into <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->
    `idc-skill-canonical-admission-audit` per Phase 2D PR-7). Lands
    BEFORE the admission PR opens (separate commit on the admission branch).
11. Stage canonical artifacts in ONE PR (one commit ideal). Open the PR.
12. Pre-merge gate:
    `Skill(skill="idc-skill-planning-substrate")` with
    `gate_mode: engineer, action: pre_merge`. PRD/spec/master admissions
    ESCALATE; surface for explicit operator approval before `gh pr merge`.
13. Standard per-PR review-fix-merge-deconflict cycle. Prose merge-marker
    conflicts route to `idc-skill-pr-deconflict-resolve`; code-semantic
    conflicts (rare for Plan PRs, which are markdown + YAML) route to the
    `idc:idc-role-merge-deconflictor` Claude-side teammate equivalent (Codex
    runs the resolution inline with extra care).
14. Write the handoff at the appropriate path:
    - PRD / spec / master-plan admission → `docs/workflow/handoffs/phases/`
    - Subphase plan(s) → `docs/workflow/handoffs/subphases/`
    - Pillar plan(s) → `docs/workflow/handoffs/pillars/`
    Frontmatter is the seven-key auto-advance block (`role: plan, next_role: sequence, ...`).
15. End with a concise handoff signal. The handoff does NOT auto-invoke
    `codex-idc-sequence`. Operator advances the chain.

## Parent Context Budget

- Parent may read compact packets, file headers, targeted snippets, and the
  full canonical chain (the 1M-context model holds it).
- Parent should NOT absorb pasted plan / canonical-doc / source-code bodies
  into a teammate brief — route through the codebase-context-curator skill
  if the run is large enough to need it.
- Reviewers read drafts from disk; the parent receives findings counts +
  paths, not bodies.
- Every research dispatch (rare in Plan runs) must ask for sources checked
  and a concise result.

## Output Requirements

Each PR body MUST include:

- Highest affected layer declaration (PRD / arch spec / master plan / subphase / pillar)
- Downstream ripple plan (which TRACKER work this triggers; whether `codex-idc-ripple` files separately or the change is fully self-contained)
- Architectural-fitness obligations (named `tests/test_arch_*.py` files added or updated, OR explicit "no fence trigger" declaration)
- Considerations file pointers absorbed
- Operator gates exercised (pre-drafting approval timestamp if PRD/spec; pre-merge approval pending)

## Goal parity (Claude-side)

Claude Code's `/goal` command (session-scoped Stop hook) is the iteration driver on the Claude side; Codex CLI has no direct analog. Parity comes from three Codex primitives:
- Pillar plans authored by this skill carry TDD-shaped `exit_criteria` (test commands + lint + fence paths), enforced by `idc-skill-pillar-plan-shape` step 5. Build adapters (Claude or Codex) read the same lines.
- Codex Build's writer/fixer subagents iterate red→green→refactor via `superpowers:test-driven-development` until the same `exit_criteria` conditions surface green in their context, then push.
- Codex's `Don't stop the train` doctrine + `auto_push=true` handoff close the loop without operator nudges.

Net: a pillar plan authored on Codex is execution-compatible with a Claude-side Build run (and vice versa).

## Branch and worktree cleanup

Codex lacks `TeamDelete` semantics, so worktree + branch cleanup is the parent's responsibility — but parents have historically left branches dangling on the remote (see `docs/workflow/audits/2026-05-14-codex-orphan-branch-sweep-audit.md` for the cleanup of 17+ such branches). Every run of this skill MUST follow the cleanup discipline below.

1. **Record at session start.** Capture the branch name + worktree path at session start in `<scratch>/codex-cleanup-manifest.md`:
   ```markdown
   # Codex cleanup manifest — codex-idc-plan
   - branch: codex-plan/<slug>
   - worktree_path: .claude/worktrees/codex-plan-<slug>/
   - main_checkout: <governed-repo>
   - pushed_at: <timestamp-if-pushed>
   ```
2. **On normal completion** — invoke the worktree-merge single-shot pattern verbatim per `WORKFLOW.md §9.2`:
   ```bash
   cd "$MAIN" && \
     gh pr merge "$PR_NUM" --squash --delete-branch && \
     git pull --ff-only && \
     git worktree remove "$WT_PATH" && \
     git worktree prune && \
     git branch -D "$BRANCH"
   ```
3. **On abort, crash, or operator stop** — Codex surfaces the manifest path + cleanup-required signal in its SUCCESS / BLOCKED telegram. The operator (not Codex) runs the cleanup manually using the manifest:
   ```bash
   cd "$MAIN" && \
     git worktree remove "$WT_PATH" && \
     git worktree prune && \
     git branch -D "$BRANCH" && \
     git push origin --delete "$BRANCH"  # only if pushed
   ```
4. **Telegram requirement.** Every SUCCESS / BLOCKED telegram from Codex MUST include `cleanup_manifest_path: <scratch>/codex-cleanup-manifest.md` AND `cleanup_required: true|false` (`false` only if the worktree-merge single-shot pattern completed in step 2). This is the **declared parent's responsibility** — operator silence on cleanup is interpreted as "Codex completed it" only when `cleanup_required: false`.
