---
name: idc-skill-considerations-admissibility-review
description: 'Use when reviewing IDC consideration files for admission readiness before PRD, architecture, or plan authorship.'
---
# IDC Skill — Considerations Admissibility Review (`idc:idc-skill-considerations-admissibility-review`)

CUSTOM. Per-file admissibility classifier consumed by CR-11. The skill reads ONE considerations file end-to-end, classifies admissibility per `triage_scope`, surfaces open operator questions, flags cross-domain coupling, and recommends canonical-doc anchor landings. CR-11 dispatches one read-only Task subagent per file in parallel; each subagent invokes this skill once. The aggregation into Ready / Needs-rescope / Reject-out-of-scope cohorts is CR-11's responsibility.

## When to invoke

Inside a Task subagent dispatched by CR-11 the orchestrator inline (substrate: `idc:idc-skill-considerations-admissibility-review`) Phase 2. Also callable directly from an Engineer parent orchestrator's Phase 1 considerations-reviewer step when CR-11 is not in use. Single-process — one verdict per considerations file.

## Input shape

Caller passes a single packet with:

- `file_path` — absolute path to the considerations file (typically `docs/considerations/<YYYY-MM-DD>-<domain>-<slug>-considerations.md`).
- `triage_scope` — exactly one of `engineer-admission | develop-subphase-alignment | ripple-flagged`. Selects the per-scope verdict criteria.
- `scratch_dir` — absolute path to the calling roleplayer's scratch dir.
- `output_filename` — optional; defaults to `<file_basename>-admissibility.md` under `scratch_dir`.

## Output shape

Single per-file digest written to disk plus a small return packet:

- **File** at `<scratch_dir>/<output_filename>`. YAML frontmatter + structured body (see "Per-file digest shape" below).
- **Return packet:** `{verdict, open_questions_count, cross_domain_refs_count, anchor_recommendations_count, file_path}`.

### Per-file digest shape

```yaml
---
review_kind: considerations-admissibility
triage_scope: engineer-admission | develop-subphase-alignment | ripple-flagged
file_path: <abs path>
verdict: Ready | Needs-rescope | Reject-out-of-scope
domain: <slug from filename>
authored_date: <YYYY-MM-DD from filename>
---

# Considerations admissibility — <slug>

## 1. Verdict + rationale (2-3 sentences)

(One short paragraph naming the verdict and the load-bearing reason.)

## 2. Open questions still pending operator decision

- <bullet per Q-* item the considerations file flagged but did NOT resolve> (verbatim quote from file)

## 3. Cross-domain references

- <bullet per anchor in another domain's PRD section / arch-spec section / master-plan §Domain / subphase plan / pillar plan / code surface that this consideration implies edits in>

## 4. Recommended canonical-doc anchor landings

| # | Consideration finding | Recommended anchor | Doc layer |
|---|------------------------|---------------------|-----------|
| 1 | <one-line finding from file> | <e.g. "PRD §Compile pipeline / source-level dedupe"> | prd / arch-spec / master-plan |
| ... |

## 5. Triage-scope-specific notes

(For `engineer-admission`: note whether the consideration is structurally PRD-shape vs arch-spec-shape vs master-plan-shape. For `develop-subphase-alignment`: note whether the consideration aligns with the named admitted master-plan §Domain/§Phase. For `ripple-flagged`: note whether the consideration is a Ripple trigger vs a downstream-sync target.)
```

## Procedure

1. **Read** the considerations file at `file_path` end-to-end.
2. **Read** prior admission audits (`docs/workflow/audits/*-engineering-admission-audit.md`) and prior Ripple change orders (`docs/workflow/ripple/*-ripple.md`) only as needed to detect supersession (i.e. has this consideration already been admitted or filed as Ripple? If so, the verdict drifts toward `Reject-out-of-scope` with rationale "already admitted at <ref>").
3. **Classify per `triage_scope`:**
   - `engineer-admission` (default for Engineer's Phase 1):
     - `Ready` — consideration names a specific PRD/arch-spec/master-plan landing anchor, has resolvable scope, no unresolved Q-* questions blocking authorship, no upstream contradiction.
     - `Needs-rescope` — scope is ambiguous, anchor is unclear, OR open questions are load-bearing for authoring decisions but resolvable by operator.
     - `Reject-out-of-scope` — consideration would require editing a layer above PRD; OR it is purely governance-pipeline (CLAUDE.md tree, `${CLAUDE_PLUGIN_ROOT}/agents/`, `${CLAUDE_PLUGIN_ROOT}/skills/`) routing through Ripple not Engineer; OR it is purely subphase/pillar/code work routing through Develop/Build not Engineer; OR it is already admitted/filed.
   - `develop-subphase-alignment`:
     - `Ready` — consideration content aligns with the named admitted master-plan §Domain/§Phase.
     - `Needs-rescope` — partial alignment with adjustments needed.
     - `Reject-out-of-scope` — consideration belongs to a different §Domain/§Phase OR to a higher canonical layer.
   - `ripple-flagged`:
     - `Ready` — consideration is a clean Ripple trigger with a clear `highest_affected_layer`.
     - `Needs-rescope` — the trigger is ambiguous or implies broader canonical-chain disruption (route to Engineer for re-canonical pass).
     - `Reject-out-of-scope` — drift detected is already covered by a prior Ripple OR doesn't actually require canonical-doc editing.
4. **Extract open questions:** scan the considerations file for any Q-* items, "OPEN", "PENDING", or unresolved-decision markers. Quote verbatim.
5. **Detect cross-domain coupling:** scan for anchor names in other domains' canonical surfaces. List each anchor as a cross-domain reference.
6. **Recommend canonical-doc anchor landings:** for each load-bearing consideration finding, recommend a specific anchor (`PRD §<section>`, `master architectural spec §<section>`, `master implementation plan §<Domain>/§<Phase>`). One row per finding.
7. **Compose triage-scope-specific notes** per §5 of the digest shape.
8. **Write the digest** to `<scratch_dir>/<output_filename>`.
9. **Return** the small return packet.

## Single-process confirmation

Single-input → single-output: caller hands one packet (file_path + triage_scope + scratch_dir + output_filename), skill writes one per-file digest at the canonical scratch path and returns one return packet. There is no internal multi-step orchestration, no spawning of teammates / Task subagents (the SKILL is invoked by a parallel-dispatched Task subagent, but the skill itself does not spawn), no state across invocations.

## Banlist

Load-bearing forbiddens:

- **No edits to considerations files.** Read-only — considerations are operator-managed pre-canonical surface; only the operator (or `idc:idc-think` orchestrator) writes them.
- **No archive moves.** This skill never moves files between `docs/considerations/` and `docs/considerations/archived-considerations/`. Operator-managed archive shelf; archive moves require the Ripple sanction path.
- **No multi-file aggregation.** This skill processes ONE file at a time. Cohort aggregation (Ready / Needs-rescope / Reject-out-of-scope partitioning across N files) is CR-11's responsibility.
- **No admission decisions.** Verdict is `Ready | Needs-rescope | Reject-out-of-scope` — admissibility classification, not admission. Admission is Engineer's authority via ES-2 + ER-1 + the operator gate.
- **No verdict downsizing to escape a halt.** When evidence supports `Reject-out-of-scope`, never emit `Needs-rescope` to keep the consideration in-scope.
- **No silent open-question suppression.** Every Q-* item the considerations file flagged renders verbatim in §2 of the digest.
- **No verdict crossover between triage_scopes.** A consideration that's Ready for `engineer-admission` may be `Needs-rescope` for `ripple-flagged`. The `triage_scope` parameter is load-bearing — never blend.

## Codex parity note

Loaded via the Skill tool by the folded `codex-idc-engineer` (consolidated into `idc:codex-idc-plan`; after substrate-redirection sweep) inside per-file Codex subagents — closes Codex parity gap #1 (today's codex-idc-engineer collapses considerations-reviewer + admission-reviewer into one subagent). The Codex parent dispatches per-file subagents identically; the verdict + digest shape are byte-compatible across runtimes. <!-- lint-allow: dangling ref, tracked in docs/dev/known-debts.md -->

## See also

- CR-11 the orchestrator inline (PR-5 fold; substrate: `idc:idc-skill-considerations-admissibility-review`) — the parent roleplayer that dispatches one Task subagent per file.
- ES-2 `idc:idc-skill-canonical-admission-audit` — Engineer's binding admission audit; consumes CR-11's Ready cohort as input.
- ER-1 the orchestrator inline (PR-5 fold; substrate: `idc:idc-skill-canonical-doc-authoring`) — the drafter that consumes CR-11's Ready cohort + ES-2's verdict packet.
- `docs/considerations/` — pre-canonical considerations surface; the considerations surface is Think-owned, so never edit considerations files from outside Think.
- `docs/considerations/archived-considerations/` — operator-managed archive shelf; archive moves require Ripple sanction.
