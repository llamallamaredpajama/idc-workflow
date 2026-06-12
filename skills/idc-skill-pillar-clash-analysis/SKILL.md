---
name: idc-skill-pillar-clash-analysis
description: 'Use when IDC deconflict work needs to analyze cross-pillar clashes from subphase and pillar plan inputs.'
---
# idc:idc-skill-pillar-clash-analysis (KS-2 — Deconflict)

CUSTOM. Deconflict's forward-clash detector. Consumes KS-1's subphase-ingestion digest and identifies cross-pillar conflicts that KR-1's pillar-polish workflow must resolve in-pillar (via union/serialize) or escalate to Ripple via KS-5.

This skill is the **resolution-proposing** stage; it never authors clash-evidence files (that's WM-2's emission contract, called by KR-1 with this skill's output). The 5th verdict `ripple-required` is the load-bearing gatekeeper between "reconcile in pillar" and "upstream doc is wrong." Severity-downsizing `ripple-required` to `serialize` or `union` is a banlist violation.

## When to invoke

- the orchestrator inline (substrate: `idc:idc-skill-pillar-plan-shape` + `idc:idc-skill-plan-review` + `idc:idc-skill-pillar-clash-analysis`) Phase 1 step 2 — runs after KS-1 ingestion completes.
- Deconflict parent orchestrator's pre-KR-1 step when checking whether multi-subphase polish is feasible without Ripple escalation.

Do NOT invoke from the orchestrator inline (substrate: `idc:idc-skill-pillar-matrix-synth` (all three views)) — Sequence reads already-landed clash-evidence files (WM-2 emissions), not this analysis output. Do NOT invoke from Build, Engineer, or Develop.

## Input contract

| Field | Shape |
|-------|-------|
| `subphase_ingestion_digest_path` | absolute path to KS-1's emitted digest at `<scratch_dir>/subphase-ingestion.md` |
| `scratch_dir` | absolute path to the Deconflict run's per-run scratch dir |
| `output_filename` | basename for the emitted clash-analysis report (caller-supplied; defaults to `pillar-clash-analysis.md`) |
| `tracker_state_path` | filesystem-backend-only metadata — optional absolute path to current `TRACKER.md` for sequencing-inversion detection (defaults to repo-root `TRACKER.md`). On the GitHub backend this field is unused; sequencing state resolves via `gh project item-list` queries on lane labels + Status field through `idc:idc-skill-tracker-adapter`. |
| `mode` | `full` (default) \| `validate-only` (skip emission, return verdict-only) |

## Output contract — clash-analysis report shape (verbatim)

```markdown
# Pillar Clash Analysis — <run-id>

**Subphases analyzed:** <N>
**Candidate pillars enumerated:** <M>  <!-- sum across §Rough Pillars in KS-1 digest -->
**Clashes detected:** <K>
**Pairs with ripple-required verdict:** <R>

## Summary verdict

<one of: `clean — no clashes detected` | `<K> in-pillar resolutions proposed` | `<R> ripple-required pairs blocking polish`>

## Clash register

| # | Pillar A | Pillar B | Kind | Resource Kind | Resource ID | Evidence (1-line) | Proposed Resolution |
|---|----------|----------|------|---------------|-------------|-------------------|---------------------|
| 1 | <pillar-trace-key> | <pillar-trace-key> | file-conflict / semantic-conflict / dependency-cycle / sequencing-inversion / ripple-required | file / service / doc / governance | <repo-relative path or service name> | <one-line evidence quote> | serialize / union / ripple-required |
| 2 | ... | ... | ... | ... | ... | ... | ... |

## Per-clash detail

### Clash 1 — <pillar-A> ↔ <pillar-B> (<kind>)

**Resource:** `<resource_kind>` `<resource_id>`
**Evidence (multi-line):**
<2-5 line block citing the conflicting acceptance criteria, file-surface declarations, dependency edges, or sequencing assumptions from KS-1's digest. Quote subphase plan paragraphs by line number when possible.>

**Proposed resolution:** `<serialize | union | ripple-required>`

**Resolution rationale:**
<1 paragraph: why this resolution wins. For `serialize`, name which pillar runs first and why. For `union`, explain the non-overlapping-slice split. For `ripple-required`, name the highest affected canonical layer (subphase | master plan | arch spec | PRD) and the upstream doc that needs repair.>

### Clash 2 — ...

## Ripple-required pairs (gatekeeper)

<For every clash with `kind: ripple-required` OR `proposed_resolution: ripple-required`:>

- **Pair:** `<pillar-A>` ↔ `<pillar-B>`
- **Highest affected layer:** `<subphase | master-plan | arch-spec | prd>`
- **Upstream doc:** `<absolute path to subphase plan or master plan section>`
- **Why upstream is wrong (1 sentence):** <evidence summary>
- **Recommended action:** route to KS-5 `idc:idc-skill-ripple-trigger-precheck`; do NOT proceed to polish for the affected pair until Ripple lands.

## Pillars NOT clashing (proceed to polish)

<list of pillar trace keys that have NO clash with any other candidate — these are safe to polish in parallel per "don't stop the train">
```

The `## Clash register` table heading is LOAD-BEARING. KR-1's polish workflow reads this table mechanically; renaming or omitting columns breaks the read.

## Procedure

1. **Validate inputs**:
   - `subphase_ingestion_digest_path` exists and is readable. Mismatch → `BLOCKED — subphase_ingestion_digest_path missing or unreadable`.
   - `scratch_dir` exists and is writable.
2. **Read the KS-1 digest** at `subphase_ingestion_digest_path`. Extract:
   - Per-subphase file-surface lists.
   - Per-subphase verbatim §Rough Pillars blocks.
   - Cross-subphase dependency edges (from the digest's edges table).
3. **Enumerate candidate pillars** by parsing each subphase's §Rough Pillars block. Generate a stable pillar trace key per entry: `<domain>-phase-<n>-subphase-<n>-pillar-<m>-<slug>` where `<m>` is the rough-pillar entry index within that subphase and `<slug>` is derived from the entry heading. KS-1's verbatim block is the authoritative source — do not invent pillars.
4. **Detect clashes** across candidate-pillar pairs. For every (pillar_a, pillar_b) pair where `pillar_a < pillar_b` lexicographically:
   - **(a) file-conflict:** both pillars declare write access to the same repo-relative file path (cross-reference §Rough Pillars `file_surfaces` declarations + parent-subphase file surfaces from the digest).
   - **(b) semantic-conflict:** both pillars declare an acceptance criterion targeting the same surface but with contradictory expected behavior (e.g. "removes endpoint X" vs "modifies endpoint X"). Detection is keyword + surface-name overlap; flag the suspected pair for KR-1 review when surface names match but acceptance criteria diverge.
   - **(c) dependency-cycle:** pillar_a's `Dependencies:` lists pillar_b AND pillar_b's `Dependencies:` lists pillar_a (direct cycle), OR a longer cycle exists through transitive edges from KS-1's cross-subphase edges table.
   - **(d) sequencing-inversion:** pillar_a is admitted earlier than pillar_b in the Tracker's wave-queue substrate — filesystem backend: `TRACKER.md` `## Implementation Wave Queue` parsing; GitHub backend: lane-label ordering via `gh project item-list` queries; both routed through `idc:idc-skill-tracker-adapter` — (or the KS-1 digest's cross-subphase edge implies this) AND pillar_b's exit criteria block pillar_a's entry — the order is contradictory.
   - **(e) ripple-required:** any of the above where the proximate cause is an upstream-doc inconsistency (e.g. subphase A's §Goal contradicts subphase B's §Goal in a way that can only be reconciled by editing the master-plan section both derive from, OR an acceptance criterion contradicts an explicit fence-pinned invariant in `tests/test_arch_*.py`).

   > **Runtime note — parallel dispatch of the step-4 sweep (DEFAULT in Claude Code).** **DEFAULT in Claude Code** when the candidate-pillar count makes the M-choose-2 comparison large (rule of thumb: **> ~6 pillars, i.e. > 15 pairs**); inline/teammate dispatch is the fallback for non-Claude runtimes or when `Workflow` is unavailable. At that threshold the calling role runs this detection sweep via the Claude Code `Workflow` tool instead of inline: enumerate the `(pillar_a < pillar_b)` pairs from step 3, then `parallel()` one bounded **read-only** sub-agent per pair (or pair-batch) that reads ONLY the KS-1 digest at `subphase_ingestion_digest_path` (plus read-only Tracker wave-queue state), applies all five detection lenses, and returns one schema-validated verdict `{pillar_a, pillar_b, kind, resource_kind, resource_id, evidence_line, proposed_resolution}`. The orchestration *script* collects every pair verdict; this skill then assembles the `## Clash register` and proceeds to step 5 unchanged. **In any non-Claude runtime (Codex, etc.) the `Workflow` tool does not exist — ignore this note and run step 4 inline (or via the runtime's own parallel-subagent dispatch).** Boundary: the fan-out is read-only — no Tracker mutation, no clash-evidence writes, no KS-5 calls (per Banlist), closed `kind`/`resolution` enums, and never invent pillar trace keys. Resolution proposing (step 5) and the gatekeeper logic — including the no-downsizing-`ripple-required` rule — run in this skill AFTER the sweep returns, **never** inside the fan-out (sub-agents cannot coordinate). For small pillar counts, keep step 4 inline; the dispatch overhead is not worth it.
5. **Propose a resolution** per clash:
   - `file-conflict` → default `serialize` if one pillar logically depends on the other; default `union` if both pillars write non-overlapping slices of the same file (filesystem-backend example: `TRACKER.md` bookend appends; on the GitHub backend the equivalent is concurrent `gh issue edit` mutations, which are naturally non-conflicting because GitHub serializes issue mutations server-side).
   - `semantic-conflict` → if reconcilable in-pillar by tightening one acceptance criterion, propose `serialize`; if not reconcilable without upstream-doc edit, propose `ripple-required`.
   - `dependency-cycle` → propose `ripple-required` (cycles always indicate upstream §Dependencies-section drift).
   - `sequencing-inversion` → propose `serialize` if TRACKER ordering can absorb the inversion via wave reassignment; propose `ripple-required` if the inversion proves the master-plan §Domain/§Phase ordering is wrong.
   - `ripple-required` → propose `ripple-required` (terminal; no in-pillar reconciliation).
6. **Emit the report** at `<scratch_dir>/<output_filename>` per the report shape above.
7. **Return** `{output_path, clash_count, in_pillar_resolution_count, ripple_required_count, clean: <bool>}`.

In `validate-only` mode, skip step 6 — return verdict-only.

## Halt conditions

| Halt | When |
|------|------|
| `BLOCKED — subphase_ingestion_digest_path missing or unreadable` | step 1 |
| `BLOCKED — scratch_dir does not exist or not writable` | step 1 |
| `BLOCKED — KS-1 digest malformed: §Rough Pillars block missing for subphase <basename>` | step 2 |
| `BLOCKED — pillar trace key collision detected (KS-1 digest emitted two rough-pillar entries with same slug)` | step 3 |

On halt the analysis report is NOT written. Caller routes per the halt's recovery hint:

- KS-1 digest malformed → re-run KS-1; halt indicates KS-1 emit-step bug, not Develop-side defect.
- Pillar trace key collision → flag back to Develop for §Rough Pillars heading disambiguation.

## Banlist

- **Do NOT downsize `ripple-required` to `serialize` or `union`.** A `ripple-required` verdict means upstream-doc drift; reconciling in-pillar would silently land the drift. Severity-downsizing this verdict is a banlist violation pinned by the folded `idc-deconflict` role's §Anti-patterns (now `idc:idc-plan`).
- **Do NOT widen the `kind` enum.** `{file-conflict, semantic-conflict, dependency-cycle, sequencing-inversion, ripple-required}` is the closed set — pinned by the folded `idc-deconflict` role (now `idc:idc-plan`) Phase 1 line 173.
- **Do NOT widen the `resolution` enum.** `{serialize, union, ripple-required}` is the closed set — pinned by WM-2 `idc:idc-skill-clash-evidence` and the folded `idc-deconflict` role's §Clash Evidence Schema (now `idc:idc-plan`).
- **Do NOT write clash-evidence files at `docs/workflow/pillar-conflicts/`.** That's WM-2's emission contract, called by KR-1 with this skill's output as input. Single-responsibility split.
- **Do NOT call KS-5 `idc:idc-skill-ripple-trigger-precheck` from this skill.** KS-2 detects + proposes; KS-5 stages the Ripple proposal scratch artifact. KR-1 orchestrates the call sequence.
- **Do NOT modify the Tracker substrate.** Sequencing-inversion detection is read-only against the Tracker's current wave-queue substrate — filesystem backend: `TRACKER.md` body; GitHub backend: `gh project` queries — both routed through `idc:idc-skill-tracker-adapter`. (Tracker writes are Sequence + Build authority via the adapter; KS-2 never mutates either substrate.)
- **Do NOT invent pillar trace keys.** Every key in the `clash_register` MUST derive from a §Rough Pillars entry in KS-1's digest.
- **Do NOT include intra-pillar clashes.** A pillar that has internal contradictions is a polish-quality issue caught by WD-2c `idc:idc-skill-plan-review`, not a cross-pillar clash. KS-2's scope is pair-wise only.

## Cross-references

- KS-1 input: `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-subphase-ingestion/SKILL.md` (digest is the sole input)
- KR-1 caller: the orchestrator inline (PR-5 fold; see substrate skills) (Phase 1 step 2)
- Downstream consumers:
  - WM-2 `idc:idc-skill-clash-evidence` (KR-1 invokes WM-2 with this skill's clash entries to author durable clash-evidence files at `docs/workflow/pillar-conflicts/`)
  - KS-5 `idc:idc-skill-ripple-trigger-precheck` (KR-1 invokes KS-5 with this skill's `ripple-required` pairs to stage Ripple proposal scratch)
  - KS-3 `idc:idc-skill-sibling-pillar-precedent-review` (separate scope — cross-RUN clashes against already-landed pillars; this skill is intra-RUN only)
- Authority source: the folded `idc-deconflict` role (now `idc:idc-plan`) Phase 1 line 173 (`clash-analyzer` teammate prompt) + per-role audit `deconflict.md §KS-2`
- Q-decon-2 binding: KS-2 + WM-1 are SEPARATE skills (single-responsibility, distinct schemas) — see audit `deconflict.md §Open questions for this role`
