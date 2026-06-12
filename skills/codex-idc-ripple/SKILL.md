---
name: codex-idc-ripple
description: "Use when running the Codex-native IDC Ripple role for an IDC-governed repo: file change orders and draft gated canonical or planning-doc synchronization when work discovers drift."
---

# Codex IDC Ripple

## Runtime Contract

This is the Codex adapter for the Claude Teams `idc-ripple` playbook. Do not edit
or run `../../agents/idc-ripple.md` (relative to this skill directory inside the
idc-workflow plugin) from Codex. Use it only as the donor
contract for authority boundaries.

Run as the parent Codex session. Use Codex subagents for bounded drift ingestion,
impact analysis (single classifier returning `downstream_sync_map` as a return
field — see Q-rip-2 below), CLAUDE.md tree audit, change-order draft, and review.
The parent owns operator gates and final change-order text.

### Substrate model — Codex inline-read pattern (Option 2)

Per `appendices/codex-drift-ripple.md` Option 2 (inline-read, recommended
short-term) — each Codex subagent dispatch reads the corresponding shared
roleplayer agent body from `../../agents/` OR skill body from `../../skills/`
(relative to this skill directory inside the idc-workflow plugin)
at run time and uses it as the subagent's prompt. Skill slugs resolve via
each runtime's substrate. Adopting this pattern means the Codex parent invokes
the same multi-step composition as the Claude `idc:idc-role-change-order-author`
roleplayer but renders each step as a Codex subagent call.

## Authority

Allowed writes:

- `docs/workflow/ripple/<change-order-slug>-ripple.md`
- Gated PR edits for affected canonical/planning docs after required operator
  approval
- Optional handoff under `docs/workflow/handoffs/ripples/`
- Run-audit at `docs/workflow/audits/<YYYY-MM-DD-HHMM>-ripple-run-audit.md` (via
  CS-1)
- Scratch files under `/tmp/idc-ripple/<run-id>/`

Forbidden writes:

- Source code or tests
- TRACKER scope invention
- Automatic PRD or architecture-spec edits without operator approval before
  drafting and again before merge
- Hyphenated `hand-offs/` paths (anti-pattern; only `handoffs/` is permitted)

## Substrate consumed (shared with Claude side)

Per Q-rip-2 (Codex sibling B aligns to A) and `appendices/codex-drift-ripple.md`
substrate-redirection scope:

| Substrate | Purpose |
|-----------|---------|
| RS-1 `idc-skill-drift-evidence` | Phase 1 ingester contract |
| RS-2 `idc-skill-ripple-verdict` | 4-value verdict + `downstream_sync_map` return field + four-condition `MINOR_AUTONOMOUS` gate verbatim. **Replaces the prior split `canonical-impact-analyst` + `downstream-sync-mapper` Codex subagents per Q-rip-2** — one classifier, single round-trip |
| RS-3 `idc-skill-ripple-verdict` | Tree drift detection + 4 scope-classification rules verbatim per Q-rip-3 |
| RS-4 `idc-skill-change-order-shape` | Templated change-order shape — schema validation + verbatim emit |
| RS-5 `idc-skill-plan-review` | Phase 3 review (5 ripple-shape dimensions) |
| PR-1 `idc-role-change-order-author` | Multi-step composition workflow body (inline-read into Codex change-order-author subagent) |
| CS-1 `idc-skill-run-audit` | Run-audit emit | <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->
| CS-2 `idc-skill-role-handoff` | Handoff emit (`kind=ripples`) | <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->
| CS-4 `idc-skill-ripple-verdict` | Surface-based pipeline classification + binary verdict |
| CS-5 `idc-skill-planning-substrate` | `gate_mode: ripple` operator-approval gatekeeper |
| WD-1 `idc-skill-plan-adversarial-review` | Phase 3 codex-adversarial-reviewer (wraps `/codex:adversarial-review`) |

## Procedure

### Phase 0 — Worktree isolation (MANDATORY)

Before any drift-evidence read or change-order draft begins, this skill must be running in an isolated worktree branched off `main`, not directly on `main`. The mandate matches the Claude IDC roles per `WORKFLOW.md §9.2 — Worktree mandate per role`; running any IDC role on `main` directly is forbidden so parallel sessions stay isolated.

1. **Self-check.** `git branch --show-current` MUST NOT return `main` or `master`. If it does, halt and either:
   - Instruct the operator to invoke this skill from a non-`main` starting branch, OR
   - Auto-create a worktree:
     ```bash
     git worktree add -b codex-ripple/<slug> .claude/worktrees/codex-ripple-<slug>
     cd .claude/worktrees/codex-ripple-<slug>
     ```
   `cd` into the worktree immediately.
2. **Record at session start** — capture the branch + worktree path in `<scratch>/codex-cleanup-manifest.md` per §Branch and worktree cleanup below.
3. **Cleanup at session close** uses Variant A of `WORKFLOW.md §9.2` for `MINOR_AUTONOMOUS` (operator-driven on Codex per the asymmetry below) / `GATED` / `MAJOR_GATED`; for `NO_RIPPLE` reap the worktree without `gh pr merge` (no PR exists). See §Branch and worktree cleanup below.

Branch prefix is `codex-ripple/<slug>`. Worktree path is `.claude/worktrees/codex-ripple-<slug>/`.

### Workflow steps

1. Read the drift source, repo instructions, and the highest suspected affected
   layer.
2. Use Codex read-only subagents for the impact-analysis arc (each subagent's
   prompt is the inline-read body of the shared substrate file):
   - `drift-evidence-ingester` — inline-reads `../../skills/idc-skill-drift-evidence/SKILL.md` (relative to this skill directory inside the idc-workflow plugin) body. Returns drift summary + repo-evidence excerpts + canonical-claim excerpts + severity + surface classification.
   - `canonical-impact-analyst` — **single classifier** that inline-reads `../../skills/idc-skill-ripple-verdict/SKILL.md` body. Returns `{verdict, pipeline, highest_affected_layer, downstream_sync_map, architectural_fitness_obligations, rationale, operator_approvals_required, ledger_destination?}`. **Per Q-rip-2: there is no separate `downstream-sync-mapper` subagent** — the `downstream_sync_map` is a return field on this classifier (collapsed from the prior split per Q-rip-2 binding decision). The Codex parent does NOT dispatch a second subagent for downstream-sync mapping.
   - `claude-md-tree-auditor` — invoked CONDITIONALLY when the proposed-edit-paths touch a CLAUDE.md surface OR when the impact-classifier returns `highest_affected_layer ∈ {root-claude-md, subdir-claude-md, claude-md-tree-restructure}`. Inline-reads `../../skills/idc-skill-ripple-verdict/SKILL.md` body. Returns CLAUDE.md tree drift findings + 4 scope-classification rules check.
3. Compose the proposed canonical edits text — full diff against live docs,
   scoped to the highest affected layer per the impact-classifier's verdict.
   Chain-ordered when single PR would be unreviewable.
4. Invoke the change-order-shape skill — inline-read
   `../../skills/idc-skill-change-order-shape/SKILL.md` body. Stage the
   draft at `/tmp/idc-ripple/<run-id>/draft-ripple.md`. The skill validates
   schema (Pipeline ∈ {governance, codebase}, Verdict ∈ {NO_RIPPLE,
   MINOR_AUTONOMOUS, GATED, MAJOR_GATED}, both citation fields, CLAUDE.md tree
   impact). Halt and re-invoke on `schema_validation: FAILED`.
5. Phase 3 review — dispatch TWO reviewers in parallel against the scratch
   draft (mirrors A's structure per Q-rip-2):
   - `codex-ripple-adversarial-reviewer` — inline-reads `../../skills/idc-skill-plan-adversarial-review/SKILL.md` (WD-1) body. Wraps `/codex:adversarial-review`.
   - `custom-ripple-reviewer` — inline-reads `../../skills/idc-skill-plan-review/SKILL.md` (RS-5) body. Reviews 5 ripple-shape dimensions.
   Both reviewers use Blocker / Major / Minor / Nit severity ladder per Q-cross-2.
6. File the change order before changing canonical docs.
7. Declare the highest affected layer and why higher layers do or do not change.
   The impact-classifier's `rationale` field provides the body text.
8. Declare downstream sync that must happen in the same PR or chain-ordered
   commits. Per the impact-classifier's `downstream_sync_map[]` return field.
9. Operator gates — invoke CS-5 `idc-skill-planning-substrate` with
   `gate_mode: ripple` to compose the `boundary_language` + `operator_approvals_required[]`:
   - `verdict: MAJOR_GATED` → stop for operator approval before drafting AND
     again before merge.
   - `verdict: GATED` → stop for operator approval before merge.
   - `verdict: MINOR_AUTONOMOUS` → see §Codex-side asymmetry below — Codex does
     NOT auto-merge.
   - `verdict: NO_RIPPLE` → no PR opens.
10. Run audit + handoff — invoke CS-1 `idc-skill-run-audit` (drops FIRST) then <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->
    CS-2 `idc-skill-role-handoff` (`kind=ripples`). Per Q-cross-1, the <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->
    Claude-side CR-5 `idc-role-closeout-author --role ripple` ships first; the <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->
    Codex parent invokes the two skills directly in the same audit-FIRST
    ordering until Codex parity for closeout-author lands.

## Codex-side asymmetry — declared verbatim (Q-rip-4)

**`MINOR_AUTONOMOUS` autonomous-merge is NOT supported on the Codex sibling in
v2.** The four-condition gate logic IS portable to Codex (RS-2 returns the
verdict identically), but the **autonomous-merge step itself** relies on the
worktree-merge single-shot pattern (`cd "$MAIN" && gh pr merge "$PR_NUM" --squash --delete-branch && ...`)
which depends on `TeamDelete` semantics that the Codex runtime lacks.

Therefore: when this Codex parent reaches `verdict: MINOR_AUTONOMOUS`, the
Codex parent surfaces the verdict + ledger destination
(`docs/workflow/ledgers/<YYYY-MM-DD>-ripple-autonomous-ledger.md`) to the
operator and **stops**, rather than auto-merging. The operator manually merges
the PR and appends the ledger line. Future enhancement (Option 3 — codex-side
loader feature) deferred per `appendices/codex-drift-ripple.md`. The same
asymmetry is documented verbatim in `../../agents/idc-ripple.md
§Codex-side asymmetry` (relative to this skill directory inside the idc-workflow plugin).

This asymmetry is **declared, not silent** — both parents (Claude
`idc-ripple.md` and this codex sibling) carry matching prose so future-session
agents do not accidentally retrofit Codex with a half-working autonomous-merge.
The four-condition gate evaluation, the change-order draft, the ledger-format
reminder in the change order body, and the verdict surfaced to the operator are
identical across runtimes; only the merge-execution step differs.

## Output Requirements

Every Ripple change order must include (per RS-4 schema validation):

- Source of drift (the `Trigger` field)
- `Pipeline:` field — `governance` or `codebase`
- `Verdict:` field — `NO_RIPPLE | MINOR_AUTONOMOUS | GATED | MAJOR_GATED`
- `Master Plan Section:` AND `Affected Role/Skill Authority:` — both required
  regardless of pipeline; the field that does not apply carries `<not applicable
  — <other> pipeline>`
- Highest affected layer
- Why higher layers do or do not change
- Proposed canonical edits (full diff)
- Downstream sync list
- CLAUDE.md tree impact, including `none` with rationale when unaffected
- Architectural-fitness obligations
- Operator gates and current gate status (none for `MINOR_AUTONOMOUS`; pre-merge
  for `GATED`; pre-drafting AND pre-merge for `MAJOR_GATED`)
- Return path to the IDC role that filed the Ripple (codebase pipeline) OR the
  audit/plan that filed the Ripple (governance pipeline)
- For `MINOR_AUTONOMOUS` only: ledger entry destination
  (`docs/workflow/ledgers/<YYYY-MM-DD>-ripple-autonomous-ledger.md`) and format
  reminder

## Branch and worktree cleanup

Codex lacks `TeamDelete` semantics, so worktree + branch cleanup is the parent's responsibility — but parents have historically left branches dangling on the remote (see `docs/workflow/audits/2026-05-14-codex-orphan-branch-sweep-audit.md` for the cleanup of 17+ such branches). Every run of this skill MUST follow the cleanup discipline below.

1. **Record at session start.** Capture the branch name + worktree path at session start in `<scratch>/codex-cleanup-manifest.md`:
   ```markdown
   # Codex cleanup manifest — codex-idc-ripple
   - branch: codex-ripple/<slug>
   - worktree_path: .claude/worktrees/codex-ripple-<slug>/
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
