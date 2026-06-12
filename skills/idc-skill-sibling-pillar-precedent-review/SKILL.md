---
name: idc-skill-sibling-pillar-precedent-review
description: 'Use when IDC deconflict work needs precedent from sibling pillar plans before resolving a clash.'
---
# idc:idc-skill-sibling-pillar-precedent-review (KS-3 — Deconflict)

CUSTOM (lightweight). Cross-RUN sibling-pillar precedent absorber. Distinct from KS-2 — KS-2 detects intra-RUN clashes between candidate pillars NOT YET landed; KS-3 detects cross-RUN clashes against pillars ALREADY landed (and harvests style precedents from them so polished pillar plans look consistent across the codebase).

The "lightweight" framing in the per-role audit means this skill does NOT propose resolutions or stage Ripple proposals — it surfaces flags that KR-1's polish workflow forwards to KS-2's resolution machinery (intra-RUN reconcilable) or KS-5's Ripple-precheck (cross-RUN clash with immutable landed sibling → almost always `ripple-required`).

## When to invoke

- the orchestrator inline (substrate: `idc:idc-skill-pillar-plan-shape` + `idc:idc-skill-plan-review` + `idc:idc-skill-pillar-clash-analysis`) Phase 1 step 3 (parallel with KS-2) — runs after KS-1 ingestion completes.
- Deconflict parent orchestrator's pre-KR-1 step when validating that polish-now-vs-defer is the right call.

Do NOT invoke from QR-3 (matrix synth reads landed-clash-evidence files via WM-2, not this skill's flags). Do NOT invoke from Build (pillar-execution-time reads pillar plans directly).

## Input contract

| Field | Shape |
|-------|-------|
| `subphase_ingestion_digest_path` | absolute path to KS-1's emitted digest at `<scratch_dir>/subphase-ingestion.md` |
| `pillars_dir` | absolute path to `docs/plans/pillars/` (the directory holding landed sibling pillar plans) |
| `scratch_dir` | absolute path to the Deconflict run's per-run scratch dir |
| `output_filename` | basename for the emitted report (caller-supplied; defaults to `sibling-pillar-precedent-review.md`) |
| `adjacent_subphase_filter` | optional list of subphase trace keys to scope sibling search; if omitted, every pillar plan in `pillars_dir` is considered |
| `mode` | `full` (default) \| `validate-only` |

## Output contract — precedent + clash report shape (verbatim)

```markdown
# Sibling Pillar Precedent Review — <run-id>

**Landed sibling pillar plans scanned:** <N>
**Adjacent-subphase pillars (in scope):** <M>
**Naming/structure precedents extracted:** <P>
**Cross-RUN clashes flagged:** <C>

## Precedents to inherit

### Slug naming convention
<observed pattern across landed siblings — e.g. "kebab-case verb-noun, max 5 words". List 2-3 example trace keys.>

### Ownership-table column ordering
<verbatim column order from landed siblings. The `Resource Kind | Resource ID | Ownership | Parallel-safe with` order is fence-pinned but column-fill conventions per pillar may vary.>

### Wave-line placement
<observed "Wave: <N>" line position in landed pillar plan bodies — typically below the ownership table or in the §Dependencies section. Cite 1-2 examples.>

### Work-packet ID format
<observed format — e.g. "W1.P3.T2" or "<pillar-slug>-task-<n>". Cite 1-2 examples.>

### Other inheritable conventions
<any other observed convention worth preserving. Maximum 3 entries — keep this section bounded.>

## Cross-RUN clash flags

<For every candidate pillar (from KS-1 digest's §Rough Pillars enumeration) that overlaps with a landed sibling on a file surface, governance fence, or service:>

| Candidate Pillar | Landed Sibling | Resource Kind | Resource ID | Overlap Nature | Recommended Routing |
|------------------|----------------|---------------|-------------|----------------|---------------------|
| <candidate trace key> | <landed sibling trace key + path> | file/service/doc/governance | <resource id> | <1-line description> | KS-5 ripple-precheck (landed siblings are immutable post-merge) |

## Out-of-scope siblings (skipped)

<list of pillar plans in `pillars_dir` that were skipped because they're outside the `adjacent_subphase_filter` OR they have no overlap with any candidate from this run. Trace keys only — no analysis.>
```

The `## Cross-RUN clash flags` table heading is LOAD-BEARING. KR-1's polish workflow checks this table and routes every flag to KS-5 (NOT to KS-2 — landed siblings are immutable, so the clash cannot be reconciled in-RUN; the only routes are Ripple-required or skip-this-candidate).

## Procedure

1. **Validate inputs**:
   - `subphase_ingestion_digest_path` exists and readable.
   - `pillars_dir` exists; if empty, emit a clean report (no precedents, no clashes) and return — first-Pillar-of-the-codebase scenario.
   - `scratch_dir` writable.
2. **Read the KS-1 digest** to enumerate this run's candidate pillars + their declared file surfaces.
3. **Enumerate landed sibling pillar plans** under `pillars_dir/*.md`. If `adjacent_subphase_filter` is supplied, filter to plans whose `Upstream Subphase:` header matches the filter.
4. **Extract precedents** from landed siblings (read first 100 lines of each landed sibling — header + ownership table is enough; do not absorb full bodies):
   - **Slug naming:** parse the pillar trace key from the filename stem; observe shared patterns.
   - **Ownership-table column ordering:** read the `## Pillar Resource Ownership` block; capture column-fill conventions.
   - **Wave-line placement:** find `Wave:` line and note its position relative to ownership table / §Dependencies.
   - **Work-packet ID format:** parse §Work Packets headings.
   - **Other conventions:** any heading-shape pattern observed in 2+ landed siblings.
5. **Detect cross-RUN clashes**: for every candidate pillar's declared file surface (from KS-1 digest), check whether any landed sibling's `## Pillar Resource Ownership` table includes the same `(resource_kind, resource_id)` pair. Record overlaps as cross-RUN clashes.

   > **Runtime note — sibling scan via background fan-out (DEFAULT in Claude Code).** Steps 3-5 are a bounded, read-only fan-out over the landed sibling plans — each sibling is read independently (first ~100 lines), yields one precedent+overlap record, and never coordinates with another. **DEFAULT in Claude Code** when `pillars_dir` holds more than a handful of landed siblings (rule of thumb: **> 6**); inline/teammate dispatch is the fallback for non-Claude runtimes or when `Workflow` is unavailable. At that threshold the caller (KR-1) runs this scan via the Claude Code `Workflow` tool instead of reading each sibling inline, so the per-sibling reads stay out of the caller's context: one **read-only** sub-agent per sibling (or small batch), each given the candidate set + declared surfaces from the KS-1 digest and the four precedent dimensions, returning a small validated record `{trace_key, precedents:{slug, ownership_cols, wave_line, work_packet_id, other[]}, overlaps:[{resource_kind, resource_id, overlap_nature}]}`. The script merges records into the verbatim `## Output contract` shape (de-duping precedents, concatenating clash rows) and returns the same `{output_path, sibling_count, precedent_count, cross_run_clash_count}` tuple. **In any non-Claude runtime (Codex, etc.) the `Workflow` tool does not exist — ignore this note and run steps 3-5 inline.** Read-only analysis only — it does NOT change the immutable-landed-sibling, emit-only, or no-resolution posture of this skill (per Banlist), and the caller stays a teammate. For a small `pillars_dir` (few siblings, or the empty-dir clean-report path), keep the inline reads.
6. **Emit the report** at `<scratch_dir>/<output_filename>` per the report shape above.
7. **Return** `{output_path, sibling_count, precedent_count, cross_run_clash_count}`.

In `validate-only` mode, skip step 6.

## Halt conditions

| Halt | When |
|------|------|
| `BLOCKED — subphase_ingestion_digest_path missing or unreadable` | step 1 |
| `BLOCKED — pillars_dir does not exist` | step 1 (use empty-dir clean-report path instead if dir exists but empty) |
| `BLOCKED — scratch_dir not writable` | step 1 |

This skill never halts on cross-RUN clashes themselves — those are flagged in the report for KR-1's downstream routing, not halt conditions. KR-1 decides whether each cross-RUN clash skips the candidate pillar or routes to KS-5.

## Banlist

- **Do NOT recommend changes to existing landed sibling pillars.** Polished + merged pillar plans are immutable post-merge. If a clash with a landed sibling appears, KR-1 routes to KS-5 + Ripple, NOT to a "patch the landed sibling" recommendation. Pinned by the folded `idc-deconflict` orchestrator (now `idc:idc-plan`) §Anti-patterns line 295 and per-role audit `deconflict.md §Banlist`.
- **Do NOT detect intra-RUN clashes.** That's KS-2's scope. KS-3 sees only candidate-vs-landed; candidate-vs-candidate is KS-2's table.
- **Do NOT propose resolutions.** Cross-RUN clashes always route to KS-5 (the landed sibling is immutable; the only options are Ripple or skip). KS-3's table emits routing pointers, not resolutions.
- **Do NOT absorb full pillar plan bodies.** Read first ~100 lines per landed sibling (header + ownership table). KR-1's context window is the constraint; this skill is the lightweight scanner.
- **Do NOT widen the precedent-section list.** The four precedent dimensions (slug, ownership-table cols, Wave-line placement, work-packet ID) plus a bounded "Other" with max 3 entries is the contract. KR-1's polish workflow grep-anchors on these heading names.
- **Do NOT modify any pillar plan** — strictly read-only on `pillars_dir`. Emit-only to scratch.

## Cross-references

- KS-1 input: `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-subphase-ingestion/SKILL.md` (digest enumerates candidate pillars)
- KR-1 caller: the orchestrator inline (PR-5 fold; see substrate skills) (Phase 1 step 3 — runs in parallel with KS-2)
- Downstream consumer:
  - KS-5 `idc:idc-skill-ripple-trigger-precheck` (KR-1 routes every cross-RUN clash flag here; landed siblings are immutable so resolutions are always Ripple or skip)
- Sibling skill: KS-2 `idc:idc-skill-pillar-clash-analysis` (intra-RUN scope; disjoint from this skill's cross-RUN scope)
- Authority source: the folded `idc-deconflict` orchestrator (consolidated into `idc:idc-plan`), Phase 1 line 175 (`prior-pillar-reviewer` teammate prompt) + per-role audit `deconflict.md §KS-3`
