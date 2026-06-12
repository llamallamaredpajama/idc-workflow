---
name: codex-idc-think
description: Use when running the Codex-native IDC Think role for an IDC-governed repo.
---

# Codex IDC Think

## Runtime Contract

This is the Codex adapter for the Claude Teams `/idc:think` workflow. Codex does not have durable cmux teammates, so the parent session fills the operator-facing brainstorm role and uses bounded subagents only for compact orientation or research packets.

Use `../../agents/idc-think.md` (relative to this skill directory inside the idc-workflow plugin) as the donor contract for authority boundaries, output shape, and active consideration queue semantics. Do not invoke the Claude Teams playbook directly from Codex.

## Phase 0 — Worktree isolation (MANDATORY)

Before any orientation read or operator-facing brainstorm begins, this skill must be running in an isolated worktree branched off `main`, not directly on `main`. The mandate matches the Claude IDC roles per `WORKFLOW.md §9.2 — Worktree mandate per role`; running any IDC role on `main` directly is forbidden so parallel sessions stay isolated.

1. **Self-check.** `git branch --show-current` MUST NOT return `main` or `master`. If it does, halt and either:
   - Instruct the operator to invoke this skill from a non-`main` starting branch, OR
   - Auto-create a worktree:
     ```bash
     git worktree add -b codex-think/<slug> .claude/worktrees/codex-think-<slug>
     cd .claude/worktrees/codex-think-<slug>
     ```
   `cd` into the worktree immediately — `git worktree add` does NOT change shell pwd.
2. **Record at session start** — capture the branch + worktree path in `<scratch>/codex-cleanup-manifest.md` per §Branch and worktree cleanup below.
3. **Cleanup at session close** uses Variant A of `WORKFLOW.md §9.2` — see §Branch and worktree cleanup below for the full chain.

Branch prefix is `codex-think/<slug>`. Worktree path is `.claude/worktrees/codex-think-<slug>/`. (Codex has no writer teammates, so no per-writer worktrees / Variant B; one worktree per Codex IDC run.)

## Authority

Allowed writes:

- Active queue files at `docs/considerations/<YYYY-MM-DD>-<topic>-considerations.md`.
- Optional handoff under the repo's current consideration-handoff convention, only when useful.
- Scratch files under `/tmp/idc-think/<run-id>/`.
- Optional `docs/research/` files only after explicit operator approval.

Forbidden writes:

- PRD, architecture spec, master plan, subphase plans, pillar plans, tracker state, source code, tests.
- Archive moves unless the operator explicitly says the consideration was processed or should be archived.
- Admission or implementation verdicts.

## First Move: Compact Orientation

Start with a bounded read-only orientation subagent when the topic needs repo grounding. The orientation packet must stay compact and include:

- likely topic and run type
- active top-level consideration candidates from `docs/considerations/*.md`
- source files / docs checked
- highest-signal repo context
- unresolved questions
- recommended next operator-facing question

If subagents are unavailable, do the same read inline and stop at a compact packet. Do not absorb full canonical docs or large consideration files into the parent context.

## Brainstorm Shape

The Codex parent is the brainstormer:

- Ask one open clarifying question at a time.
- Let the operator lead the exploration.
- Use bounded subagents for heavy reading or current-state checks.
- Attribute factual claims to operator input, repo source, or research source.
- Do not impose decision-point trees, candidate walks, recommendations, adoption verdicts, or admission verdicts.

## Active Consideration Queue

Before final synthesis:

1. Scan top-level `docs/considerations/*.md`.
2. Exclude `README.md` and `archived-considerations/`.
3. Compare the current session against active file titles, frontmatter, headings, and open decisions.
4. If a matching active file exists, rewrite that file with the merged concise synthesis.
5. If no match exists, create `docs/considerations/<YYYY-MM-DD>-<topic>-considerations.md`.
6. Keep the result at or below 100 lines.
7. Ensure `queue_status: active-unprocessed` is present.

Active files are organized by unresolved topic, not by session. Once Plan processes a consideration, it leaves the active queue; archive with `git mv` by default unless the operator explicitly requests hard deletion.

## Consideration File Shape

Each active file includes:

- `## Frame`
- `## Named Ideas`
- `## Context Notes`
- `## Open Decisions`
- `## Engineering Implications`
- `## Source Pointers`
- `## Next Role Questions`

Use concise bullets. Preserve distinct ideas; remove duplicate explanation and stale session scaffolding. Do not write a raw ledger or transcript.

## Optional Research Persistence

Research findings are scratch by default. Ask before writing any persisted research file. If the operator declines or does not answer, keep only source pointers in the consideration file.

## Closeout

End with the active consideration path, whether it was merged or new, and remaining open decisions. Hand off to `codex-idc-plan` only when the operator asks for admission work.

## Branch and worktree cleanup

Codex lacks `TeamDelete` semantics, so worktree + branch cleanup is the parent's responsibility — but parents have historically left branches dangling on the remote (see `docs/workflow/audits/2026-05-14-codex-orphan-branch-sweep-audit.md` for the cleanup of 17+ such branches). Every run of this skill MUST follow the cleanup discipline below.

1. **Record at session start.** Capture the branch name + worktree path at session start in `<scratch>/codex-cleanup-manifest.md`:
   ```markdown
   # Codex cleanup manifest — codex-idc-think
   - branch: codex-think/<slug>
   - worktree_path: .claude/worktrees/codex-think-<slug>/
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
