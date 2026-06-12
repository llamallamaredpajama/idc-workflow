---
name: idc-skill-prior-art-pattern-read
description: 'Use when Develop mode needs prior-art patterns from sibling plans, pillar plans, or handoff artifacts.'
---
# idc:idc-skill-prior-art-pattern-read (DS-2)

Develop's prior-art pattern-extraction skill. The single-process question: **what shape conventions, naming patterns, and file-ownership precedents has the rest of the IDC chain already used in this domain that the new subphase plan should inherit, and what cross-references should DR-1 cite verbatim?**

This skill returns **citations + shape-summary only** — never absorbs file body. Its output is the rapid pattern-inheritance packet DR-1 reads to keep the new subphase plan stylistically consistent with sibling work, without burning DR-1's context window on raw plan bodies.

Q-dev-1 (binding decision): DS-2 stays separate from DS-1 + DS-3. They have different output schemas (DS-1: 4-value verdict; DS-2: citation list + shape-summary; DS-3: emit-shape contract). Consolidating would push back to v1's skill-only abstraction.

## Why this skill exists (load-bearing rationale)

The folded `idc-develop` orchestrator (consolidated into `idc:idc-plan`), Phase 1, spawns three teammates in parallel including **`prior-art-reviewer`**: *"reads any sibling subphase plans for the same domain, prior pillar plans (if any have already polished work for this section), and prior phase-orchestrator handoff artifacts. Returns: shape conventions to inherit, naming patterns for tasks, file-ownership precedents, and any sibling subphase claims that would conflict with the proposed new subphase."*

The sibling-claim-conflict piece overlaps with DS-1's cross-subphase dependency map (DS-1 returns the dependency edges; DS-2 returns the shape conventions of the pattern). Two skills, two output schemas, distinct concerns. The skill exists so that the pattern-extraction returns the same packet shape regardless of which spawn path triggers it — DR-1 Phase 1 prior-art-pattern-reader sub-step, the Develop parent orchestrator's Phase 1, or a future Codex inline-read consumer.

## Input contract

| Field | Shape |
|-------|-------|
| `domain` | the master-plan §Domain slug (e.g. `agentic-chat`, `obsidian-sync`, `compile`) — used to filter sibling subphase plans + prior pillar plans by filename prefix |
| `master_section_id` | the operator's named §Domain/§Phase (e.g. `agentic-chat/phase-7d`) — used to filter handoff artifacts; cited in shape-summary as the new subphase's anchor |
| `subphase_plan_dir` | absolute path to `docs/plans/subphases/` |
| `pillar_plan_dir` | absolute path to `docs/plans/pillars/` |
| `phase_handoff_dir` | absolute path to `docs/workflow/handoffs/phases/` (legacy phase-orchestrator handoffs) AND `docs/workflow/handoffs/subphases/` (newer Develop-side handoffs) — both are read |
| `wave_handoff_dir` | absolute path to `docs/workflow/handoffs/waves/` (Sequence-side handoffs) — optional; included for cross-domain wave-shape patterns when relevant |
| `considerations_dir` | absolute path to `docs/considerations/` (optional — included if the brief flags a recently-landed consideration touching this domain) |
| `scratch_dir` | absolute path to Develop's per-run scratch dir |
| `output_path` | absolute path for the precedent packet — typically `<scratch_dir>/prior-art-pattern-read.md` |
| `max_citations` | integer (default 24) — caps the citation count to keep packet bounded; above this, the skill prioritizes most-recent siblings + most-cited handoffs |

## Output contract — precedent packet shape (verbatim)

```markdown
# Prior-Art Pattern Read — <domain> / <master_section_id>

**Audit timestamp:** <UTC ISO 8601>
**Domain filter:** `<domain>`
**Sibling subphase plans found:** <count>
**Prior pillar plans found:** <count>
**Phase-orchestrator handoffs found:** <count>
**Citations returned:** <count> (cap: <max_citations>)

## Sibling subphase plan citations

| Path | Heading anchor | Pattern observed | Cite verbatim? |
|------|----------------|------------------|----------------|
| `docs/plans/subphases/<file>` | `<H2/H3 anchor>` | <one-line pattern label> | yes \| no |
| ... | ... | ... | ... |

(If no siblings exist, single row `(none) | (n/a) | first subphase under domain | (n/a)`.)

## Prior pillar plan citations

| Path | Trace key | Ownership-table convention | Wave-line convention |
|------|-----------|-----------------------------|----------------------|
| `docs/plans/pillars/<file>` | <pillar trace key> | <one-line: e.g. "exclusive-only", "shared with co-owner table"> | <one-line: e.g. "Wave: <tag>" inline> |
| ... | ... | ... | ... |

## Handoff artifact citations

| Path | Kind | Anchor | Pattern observed |
|------|------|--------|------------------|
| `docs/workflow/handoffs/<kind>/<file>` | phase \| subphase \| wave | <H2/H3 heading> | <one-line> |
| ... | ... | ... | ... |

## Shape-summary (consolidated patterns)

### Naming conventions

- Subphase slug pattern: <one line — e.g. "kebab-case noun-phrase derived from §Phase topic; observed examples: <slug-1>, <slug-2>">
- Pillar slug pattern: <one line>
- Work-packet ID format: <one line — e.g. "T<N>.<M> hierarchical IDs OR `WP-<N>` flat IDs; observed in <X> sibling plans, <Y> divergences">

### Ownership-table column ordering

<one paragraph naming columns observed in the dominant prior pillar plans (e.g. "Resource Kind | Resource ID | Ownership | Parallel-safe with"); cite divergences>

### File-surface declaration patterns

<one paragraph: how prior pillars declare write-paths (relative repo path; with/without role labels; etc.); cite the most recent canonical example>

### Parallel-safety phrasing precedents

<one paragraph: the dominant phrasing patterns observed (e.g. "safe-with-pillar-X because file surfaces don't overlap"; "blocks on pillar-Y until merge"); cite divergences from bare "safe">

### §Phase gate mirroring

<one paragraph: how prior subphase plans mirror master-plan §Phase gates (verbatim quote vs paraphrase); cite the §Gates And Operator Decisions section convention from Wave-Orchestrator Handoff prior emissions>

### Considerations absorption

<one paragraph: which prior considerations files were absorbed into prior subphase plans for this domain (if any), and the citation pattern (footnote vs explicit `Absorbed considerations:` header)>

## Sibling-claim conflict flags

(Patterns DS-2 noticed where a sibling subphase's stated scope OR §Rough Pillars file_surfaces would clash with what the new subphase is likely to declare — informational only; DS-1 returns the dependency-map authority, this is shape-only forewarning.)

| Sibling path | Claim observed | Likely conflict with new subphase | Recommended DR-1 handling |
|--------------|----------------|-------------------------------------|----------------------------|
| `docs/plans/subphases/<file>` | <one-line claim> | <one-line conflict pattern> | <"declare cross-subphase dep"; "split file surface"; "flag for Deconflict KS-2 review"> |
| ... | ... | ... | ... |

(If no flags, single row `(none) | (n/a) | (n/a) | (n/a)`.)

## Recommended verbatim citations for DR-1

(Strings DR-1 may paste verbatim into the new subphase plan body. Each line is a single citation string; DR-1 may include or omit per its own judgment.)

- `<verbatim citation 1>`
- `<verbatim citation 2>`
- ...
```

The H2 anchors `## Sibling subphase plan citations`, `## Prior pillar plan citations`, `## Handoff artifact citations`, `## Shape-summary (consolidated patterns)`, `## Sibling-claim conflict flags`, and `## Recommended verbatim citations for DR-1` are **load-bearing** — DR-1 parses by anchor lookup. Do NOT rename or reorder.

## Procedure

1. **Validate inputs**:
   - `domain` is a non-empty kebab-case string.
   - `master_section_id` matches `^[a-z0-9-]+/phase-[0-9a-z]+(?:/subphase-[0-9a-z]+)?$`.
   - All directory inputs are absolute and exist; missing → `BLOCKED — input path <name> missing` with a caveat that empty-but-readable directories are allowed (degrade gracefully).
   - `output_path` parent directory exists.
2. **Sibling subphase scan** — `glob` `<subphase_plan_dir>/<domain>-phase-*-subphase-*-plan.md`; for each match, read **only** the H1/H2 anchor list + the `Upstream Master Plan Domain/Phase` header + first 60 lines of body to capture the goal/scope summary. Do NOT whole-file read. Cap at `max_citations / 3` siblings prioritizing most recent.
3. **Prior pillar scan** — `glob` `<pillar_plan_dir>/<domain>-phase-*-subphase-*-pillar-*-plan.md`; for each match, read the H1 title + the `## Pillar Resource Ownership` table only (per WM-1's canonical shape) + any inline `Wave:` / `Blocks on:` directives. Cap at `max_citations / 3`.
4. **Handoff artifact scan** — `glob` matches under `phase_handoff_dir`, `subphase_handoff_dir` (subdir of `phase_handoff_dir` if both share parent), and `wave_handoff_dir`. Read only the H2 anchor list + frontmatter (the seven-key R6 frontmatter) per file. Cap at `max_citations / 3`.
5. **Considerations cross-check** (optional) — if `considerations_dir` is supplied AND any consideration file in last 90 days references the named `<domain>`, capture its path + frontmatter for the §Considerations absorption summary section.
6. **Shape consolidation** — across all sampled siblings + pillars + handoffs:
   - **Naming conventions:** detect modal slug pattern (kebab-case, noun-phrase, etc.); list at least 2–3 verbatim examples.
   - **Ownership-table convention:** detect dominant column order; flag any pillars that diverge.
   - **File-surface declaration patterns:** detect whether prior pillars use `path | role | co-owners` triples or freer prose; cite the most recent example.
   - **Parallel-safety phrasing:** detect whether prior pillars use the "safe-with-X because Y" pattern (good) or the bare "safe" / "n/a" pattern (banlist-violating). Flag divergences without recommending action.
   - **§Phase gate mirroring:** sample subphase plans' `## Wave-Orchestrator Handoff > ### Gates And Operator Decisions` sections; detect verbatim-quote vs paraphrase convention.
   - **Considerations absorption:** detect whether prior subphase plans cite considerations via footnote vs explicit `Absorbed considerations:` header.
7. **Sibling-claim conflict scan** — for each sibling subphase, compare its stated scope/§Rough Pillars file_surfaces (if a `## §Rough Pillars` section exists) against the new subphase's likely surface based on `master_section_id` keyword overlap. This is **forewarning only** — DS-1's dependency-map is the authoritative dependency-edge declaration; DS-2's flags are pattern-shape signals to help DR-1 know which siblings to cross-reference.
8. **Recommended verbatim citations** — collect 3–8 short strings DR-1 may paste verbatim (typical examples: a recent §Phase gate quote DR-1 will mirror, a sibling subphase's declared cross-subphase dep that the new subphase should reciprocate, a fitness-fence test name pattern). Each string ≤ 120 chars.
9. **Write the precedent packet** to `output_path` per the output contract shape above. Render `(none)` rows for empty sections.
10. **Return** `{output_path, sibling_subphase_count, prior_pillar_count, handoff_count, citation_count, conflict_flag_count}` to caller.

## Halt conditions

| Halt | When |
|------|------|
| `BLOCKED — domain missing/empty` | step 1 |
| `BLOCKED — input path <name> missing` | step 1 (only when path is absent, not when directory is empty) |
| `BLOCKED — output_path parent dir absent` | step 1 |
| `BLOCKED — max_citations exceeded irrationally` | step 9 (cap > 200; protects against runaway packet) |

Empty sibling/pillar/handoff directories are NOT a halt — the packet renders `(none)` rows and DR-1 proceeds with no inherited shape patterns. First-subphase-under-§Phase is a normal case.

## Banlist

- **Do NOT absorb file body.** Per-citation reads cap at H1/H2 anchor list + ≤60 lines OR a single named table — never whole-file. The packet returns shape-summary, not content.
- **Do NOT recommend pattern adoption.** DS-2 reports observed patterns; DR-1 (informed by drafting authority) decides which to inherit. Severity-downsizing forbidden — never call a sibling's pattern "wrong" or "deprecated"; flag divergences neutrally.
- **Do NOT make admission decisions** or classify trace verdicts. DS-1 owns the trace verdict; this skill is read-only over already-canonical sibling plans.
- **Do NOT decide cross-subphase dependency edges.** DS-1's `## Cross-subphase dependency map` is the authoritative source. DS-2's `## Sibling-claim conflict flags` are shape-only forewarning, not dependency declaration.
- **Do NOT widen citation caps without justification.** `max_citations` defaults to 24; caller may override but >200 halts (runaway protection).
- **Do NOT cite plans outside the named `<domain>`** unless explicitly requested via brief override. Cross-domain pattern-borrowing is DR-1's drafting call, not DS-2's read.
- **Do NOT edit canonical docs.** Read-only role.

## Cross-references

- DR-1 caller: the orchestrator inline (PR-5 fold; substrate: `idc:idc-skill-rough-pillars-section`) Phase 1 (prior-art-pattern-reader sub-step)
- WD-2b reader: `idc:idc-skill-plan-review/` dimensions 5 (unclear ownership) and 6 (hidden coupling) — reads this skill's `## Sibling-claim conflict flags` as evidence input
- DS-1 sibling: `idc:idc-skill-governance-trace-audit/` (different output schema — 4-value verdict packet, not pattern packet); the cross-subphase dependency map is DS-1's authority, not DS-2's
- DS-3 sibling: `idc:idc-skill-rough-pillars-section/` (downstream emit-shape; DS-2's ownership-table convention informs DS-3 emission of `(role, co_owners)` triples)
- Source authority: the folded `idc-develop` orchestrator (consolidated into `idc:idc-plan`), Phase 1 (prior-art-reviewer description); `docs/CLAUDE.md §Subphase / pillar plan filename conventions`
