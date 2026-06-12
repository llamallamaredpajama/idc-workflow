---
name: idc-skill-governance-trace-audit
description: 'Use when Develop mode needs to trace whether work is admitted by canonical governance.'
---
# idc:idc-skill-governance-trace-audit (DS-1)

Develop's governance-trace audit skill. The single-process question: **is the master-plan §Domain/§Phase section the operator pointed at actually admitted in the canonical chain, and what does that admission imply for the subphase plan DR-1 is about to draft?**

This skill is the ONLY skill that returns the 4-value Develop-mode trace verdict (`ADMITTED | UNADMITTED | RIPPLE_PENDING | BLOCKED`). It is intentionally distinct from neighboring governance skills:

- **CS-4 `idc:idc-skill-ripple-verdict`** answers a different question: "given a proposed edit's file paths, is the edit `tracker-only` or `ripple-required`?" That's a binary verdict over an *edit*; this skill is a 4-value verdict over an *upstream §Phase admission*.
- **ES-2 admission-shape verdict** (Engineer's specialization) answers yet another question: "is the consideration packet ready to admit upstream into PRD/spec/master plan?" That's Engineer's authority, called inside the Engineer Gate.
- **CS-5 `idc:idc-skill-planning-substrate`** answers a different binary question: GO / HALT / ESCALATE through a gate boundary. Develop may invoke CS-5 separately for its pre-merge gate; DS-1 is the upstream-admission audit that comes first.

Q-dev-1 (binding decision): DS-1 stays separate from DS-2 and DS-3 — different output schemas; different read scopes; consolidating would push back to v1's skill-only abstraction.

## Why this skill exists (load-bearing rationale)

the folded `idc-develop` role (now `idc:idc-plan`) halt-condition 3: *"The master-plan section the operator points to is not admitted (governance auditor returns `BLOCKED` on the trace check). Route to `idc-engineer`."* Halt-condition 4: *"Drafting would require PRD or arch-spec changes (governance auditor returns `TOP_LEVEL_REPLAN_REQUIRED`). Route to `idc-engineer` or `idc-ripple`."* The "governance auditor" referenced is this skill's caller (DR-1's governance-trace-auditor sub-step).

The skill exists so that the trace audit emits the same 4-value verdict shape regardless of which spawn path triggers it — DR-1 Phase 1, the Develop parent orchestrator's Phase 1, or a future Codex inline-read consumer. Pinning the verdict shape here keeps Develop's halt-routing deterministic.

## Input contract

| Field | Shape |
|-------|-------|
| `master_section_id` | string in the form `<domain>/<phase-N>` (e.g. `agentic-chat/phase-7d`) — the master-plan §Domain/§Phase section the operator named via `--master-section`. May also accept `<domain>/<phase-N>/<subphase-N>` if the operator is expanding into an existing partially-admitted subphase shell |
| `subphase_slug` | kebab-case slug for the subphase being drafted; used to compute the canonical `Upstream Master Plan Domain/Phase` declaration text |
| `prd_toc_path` | absolute path to the PRD table of contents (typically `docs/prd/prd.md` — read **only** the H1/H2 anchor list per the operator's "PRD ToC only; never whole" rule) |
| `master_arch_spec_path` | absolute path to the master architectural spec (typically `docs/specs/master-architectural-spec.md` — targeted reads, not whole-file) |
| `master_plan_path` | absolute path to the master implementation plan (typically `docs/plans/master-implementation-plan.md`) — read the named §Domain + §Phase sections + any cross-section anchors they reference |
| `sibling_subphase_dir` | absolute path to `docs/plans/subphases/` for cross-subphase dependency check |
| `ripple_dir` | absolute path to `docs/workflow/ripple/` — read recent change orders touching the named section (default: change orders modified within last 60 days OR open) |
| `arch_fitness_dir` | absolute path to `tests/` — used to read `tests/test_arch_*.py` fences relevant to the named section |
| `scratch_dir` | absolute path to Develop's per-run scratch dir |
| `output_path` | absolute path for the verdict packet — typically `<scratch_dir>/governance-trace-audit.md` |

## Output contract — verdict packet shape (verbatim)

```markdown
# Governance Trace Audit — <master_section_id>

**Subphase slug being drafted:** `<subphase_slug>`
**Verdict:** ADMITTED | UNADMITTED | RIPPLE_PENDING | BLOCKED
**Audit timestamp:** <UTC ISO 8601>

## Verbatim trace declaration text

The drafter MUST paste this verbatim into the subphase plan body (typically as the second line of the file, immediately after the H1 title):

```
Upstream Master Plan Domain/Phase: <verbatim master-plan section name from master_plan_path>
```

(If `subphase_slug` expands an existing subphase shell, also include `Upstream Subphase Shell: <shell trace key>` on the next line.)

## Cross-subphase dependency map

| Sibling subphase (path) | Dependency direction | Anchor (H2 or H3) | Notes |
|--------------------------|----------------------|-------------------|-------|
| `docs/plans/subphases/<...>` | blocks-this \| blocked-by-this \| shares-surface-with | <heading> | <one line> |
| ... | ... | ... | ... |

(If no sibling subphases reference this `master_section_id`, the table contains a single row `(none) | (n/a) | (n/a) | first subphase under this §Phase`.)

## Architectural-fitness obligations triggered

| Fence file | Test name | Why this §Phase triggers it | Drafter must declare |
|------------|-----------|------------------------------|----------------------|
| `tests/test_arch_<area>.py` | `::test_<name>` | <one line citing the master-plan §Phase passage> | <obligation drafter must flag in `Test/Fitness Obligations` section> |
| ... | ... | ... | ... |

(If no fences are triggered, single row `(none) | (n/a) | (n/a) | (n/a)`.)

## Ripple change orders touching this section

| Change order file | Status | Highest affected layer | Open question for Develop |
|-------------------|--------|-------------------------|----------------------------|
| `docs/workflow/ripple/<slug>-ripple.md` | open \| merged \| draft | prd \| spec \| master-plan \| subphase | <one line> |
| ... | ... | ... | ... |

(If no recent change orders, single row `(none) | (n/a) | (n/a) | (n/a)`.)

## Verdict rationale

<2–6 sentences. Cite the master-plan anchor passage(s), any §Phase gates the drafter must mirror, and the route-to recommendation if verdict ≠ ADMITTED.>

## Halt routing (only populated if verdict ≠ ADMITTED)

- **UNADMITTED:** Operator's named `master_section_id` does not appear in the master plan H2/H3 anchor list. Route Develop to halt; operator must invoke `idc-engineer` to admit the §Phase first. Cite the closest existing master-plan anchor as evidence of absence.
- **RIPPLE_PENDING:** §Phase is admitted, but an open Ripple change order at `docs/workflow/ripple/<slug>-ripple.md` flags pending edits to that section. Route Develop to halt; operator must wait for the change order to merge OR explicitly authorize drafting against the in-flight upstream draft (operator-is-lead override).
- **BLOCKED:** §Phase admission is contradicted by upstream PRD or master architectural spec language (master plan claims X; arch spec or PRD requires not-X). Route Develop to halt; operator must invoke `idc:idc-ripple` to file a change order against the upstream contradiction. Cite both passages in evidence.

(For ADMITTED, this section is omitted entirely.)
```

The H2 anchors `## Verbatim trace declaration text`, `## Cross-subphase dependency map`, `## Architectural-fitness obligations triggered`, `## Ripple change orders touching this section`, `## Verdict rationale`, and `## Halt routing` are **load-bearing** — DR-1 parses by anchor lookup. Do NOT rename or reorder.

## Procedure

1. **Validate inputs**:
   - `master_section_id` matches `^[a-z0-9-]+/phase-[0-9a-z]+(?:/subphase-[0-9a-z]+)?$`. Mismatch → `BLOCKED — master_section_id shape invalid`.
   - All path inputs are absolute and exist. Missing → `BLOCKED — input path <name> missing or unreadable`.
   - `output_path` parent directory exists.
2. **PRD ToC scan** — read `prd_toc_path` and extract the H1/H2/H3 anchor list **only**. Verify the named §Domain has a corresponding PRD section anchor (e.g. `## Agentic chat`). If absent → flag in verdict rationale; this alone does not flip the verdict (PRD ToC absence is a Ripple condition only when the master plan also lacks §Domain coverage).
3. **Master architectural spec targeted read** — search the spec for the named §Domain anchor and any anchors the master-plan §Phase passage cites. Read at most 200 lines of context per anchor (do NOT whole-file read). Capture any contradiction language for the BLOCKED branch.
4. **Master plan §Domain + §Phase read** — locate the §Domain H2 anchor; locate the §Phase H3 anchor (or H2 if the master plan organizes phases at H2). If either anchor is absent → verdict = `UNADMITTED`. Capture the verbatim §Phase passage for the trace declaration text. Capture any §Phase gates the drafter must mirror (operator-decision points; arch-fitness obligations).
5. **Cross-subphase dependency scan** — `glob` `<sibling_subphase_dir>/<domain>-phase-<N>-subphase-*-plan.md`; for each match, read the `Upstream Master Plan Domain/Phase` header; if it matches `master_section_id`, scan the body for any `blocks` / `blocked-by` / `shares-surface-with` declarations referencing the new `subphase_slug` OR any sibling-pillar references that would clash with a fresh subphase. Compose the dependency map.
6. **Architectural-fitness fence scan** — `glob` `<arch_fitness_dir>/test_arch_*.py`; for each fence, search for docstring or test-name references to the named `<domain>` or §Phase keywords. Capture the fence file + test name + one-line trigger reason.
7. **Ripple change-order scan** — `glob` `<ripple_dir>/*.md`; for each change order modified within last 60 days OR with status `open`/`draft` in its frontmatter, search the body for references to the named §Domain/§Phase. If any open/draft change order names the section AND has not yet merged → verdict = `RIPPLE_PENDING`.
8. **Contradiction detection** — if the master-plan §Phase passage and the master arch spec or PRD anchor capture mutually contradictory claims (master plan says "implement X via Y"; arch spec says "Y is forbidden") → verdict = `BLOCKED`. Capture both passages verbatim in evidence.
9. **Compute final verdict** in this order (first match wins):
   - `BLOCKED` if step 8 found a contradiction.
   - `UNADMITTED` if step 4 could not locate the §Phase anchor.
   - `RIPPLE_PENDING` if step 7 found an open/draft change order touching the section.
   - `ADMITTED` otherwise.
10. **Compose verbatim trace declaration text**:
    - Read the master-plan §Phase H2/H3 heading verbatim. Strip leading `## ` / `### ` markers. Use the heading text as the value of `Upstream Master Plan Domain/Phase`.
    - Format as `Upstream Master Plan Domain/Phase: <heading>` exactly. The drafter pastes this into the subphase plan as a header line.
11. **Write the verdict packet** to `output_path` per the output contract shape above. Render `(none)` rows for empty cross-subphase / fitness / ripple sections. Omit the `## Halt routing` section entirely if verdict = `ADMITTED`.
12. **Return** `{output_path, verdict, master_section_id, subphase_slug, sibling_count, fence_count, open_ripple_count}` to caller.

## Halt conditions

| Halt | When |
|------|------|
| `BLOCKED — master_section_id shape invalid` | step 1 |
| `BLOCKED — input path <name> missing or unreadable` | step 1 |
| `BLOCKED — output_path parent dir absent` | step 1 |
| `BLOCKED — master_plan_path unreadable mid-scan` | steps 2–4 |
| `BLOCKED — sibling subphase plan <path> malformed (missing Upstream header)` | step 5 (informational; does not flip verdict; flag in rationale) |

The 4-value verdict (`ADMITTED | UNADMITTED | RIPPLE_PENDING | BLOCKED`) is **content output**, NOT a halt — verdict ≠ ADMITTED routes via the caller's halt-condition logic, not by raising an error from this skill.

## Banlist

- **Do NOT make admission decisions.** Engineer admits §Domain/§Phase via the Engineer Gate; this skill audits whether admission has already happened. If verdict = `UNADMITTED`, the skill ROUTES to Engineer; it does NOT admit.
- **Do NOT classify tracker-only-vs-ripple-required.** That's CS-4's verdict. DS-1's 4-value verdict is over upstream-§Phase-admission, not over a proposed edit's surface impact.
- **Do NOT widen the verdict enum.** Adding a fifth value requires a Ripple change order touching the folded `idc-develop` role (now `idc:idc-plan`) halt-conditions 3–4 + this SKILL.md.
- **Do NOT absorb full PRD body or full arch-spec body** — targeted-read discipline. PRD = ToC only; arch spec = ≤ 200 lines of context per cited anchor; master plan = §Domain + §Phase only.
- **Do NOT edit canonical docs.** Read-only role.
- **Do NOT auto-elevate `RIPPLE_PENDING` to `BLOCKED`.** A pending change order is the operator's signal to wait, not a contradiction. Only contradictory upstream language flips to `BLOCKED`.
- **Do NOT mock up the trace text** — read the master-plan §Phase heading verbatim. If the heading uses domain-specific vocabulary (e.g. `Agentic Chat — Phase 7d (chat-bot intelligence)`), preserve it byte-for-byte.

## Cross-references

- DR-1 caller: the orchestrator inline (PR-5 fold; substrate: `idc:idc-skill-rough-pillars-section`) Phase 1 (governance-trace-auditor sub-step)
- Halt-routing source: the folded `idc-develop` role (now `idc:idc-plan`) halt-conditions 3 + 4
- Distinct neighbors:
  - **CS-4 `idc:idc-skill-ripple-verdict/`** — binary `tracker-only | ripple-required` verdict over a proposed edit (not §Phase admission)
  - **CS-5 `idc:idc-skill-planning-substrate/`** — `GO | HALT | ESCALATE` over a gate boundary (Develop pre-merge gate; not the upstream-admission audit)
  - **ES-2** (Engineer's admission-shape verdict) — different vocabulary, different scope; lives inside Engineer Gate
- WD-2b reader: `idc:idc-skill-plan-review/` dimension 9 (governance-trace integrity) — reads this skill's `## Verbatim trace declaration text` block as the source-of-truth for the subphase plan's `Upstream Master Plan Domain/Phase` header
- DS-2 sibling: `idc:idc-skill-prior-art-pattern-read/` (different output schema — pattern citations, not verdict packet)
- DS-3 sibling: `idc:idc-skill-rough-pillars-section/` (consumed downstream of this audit, in DR-1 step 4)
- Source authority: root `CLAUDE.md §Canonical Document Hierarchy`; the folded `idc-develop` role (now `idc:idc-plan`) §Required trace + halt-conditions 3–4; `docs/CLAUDE.md §Subphase / pillar plan filename conventions`
