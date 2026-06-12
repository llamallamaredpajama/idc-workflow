---
name: idc-skill-plan-review
description: 'Use when running a specialized IDC plan review for feasibility, governance, sequencing, or fence coverage.'
---
# idc:idc-skill-plan-review (parameterized WD-2 specialization)

Single entry point that folds the five WD-2a..WD-2e specializations behind a `mode` parameter. The shared base `idc:idc-skill-plan-review-base` stays as the substrate this skill cites + restates verbatim per the self-contained-roleplayer rule. The point of this fold is one entry-point, not one shared dimension set — each mode carries its full per-role dimension list verbatim.

| `mode` | Caller role | Dimension count | Replaces |
|--------|-------------|-----------------|----------|
| `admission` | Plan (Engineer cognitive surface) | 8 admission-shape | `canonical-doc-review` |
| `subphase` | Plan (Develop cognitive surface) | 10 plan-shape | `plan-custom-review` |
| `pillar` | Plan (Deconflict cognitive surface) | 8 pillar-shape | `pillar-plan-review` |
| `tracker` | Sequence | 4 tracker-shape | `tracker-edit-review-pass` |
| `ripple` | Ripple | 5 ripple-shape | `correctness-review` |

## Mode router

Caller passes `mode` exactly once per call. Each mode is independently invocable. No call combines modes — distinct callsites stay distinct. The full mode-specific dimension lists, halt conditions, and per-mode banlists live in the per-mode sections below; the WD-2 base contract is restated once at the top so every mode inherits it verbatim.

## Inheritance from `idc:idc-skill-plan-review-base` (restated inline — load-bearing)

Per the self-contained-roleplayer rule (which applies analogously to skills consumed via Codex inline-read), the WD-2 base contract is restated here verbatim — DO NOT replace these with a "see base" pointer. Every mode below inherits ALL of the following:

### Autonomous Execution Mandate (load-bearing — inherited verbatim)

These rules override any default review posture. Every mode MUST honor them.

1. **Run all reads via the Bash / Read tool yourself.** Never ask the caller to paste content back. Never instruct the caller to "open the draft and tell me what it says."
2. **Never ask for permission to read scratch artifacts.** Reading `<scratch_dir>/<draft>.md`, `<scratch_dir>/codex-plan-review.md`, and any other in-flight scratch files is always safe and immediate.
3. **Never block on missing optional inputs.** If a related scratch artifact is absent, proceed with the available evidence and tag the affected dimension `unverified` rather than halting.
4. **Proceed autonomously through all dimensions.** Do not pause for caller input mid-review. The caller's findings-union logic in the orchestrator inline (substrate: `idc:idc-skill-plan-patch-from-findings`) consumes the report once written.
5. **If a tool is unavailable**, write a halt-stub at the canonical report path describing what would have been checked, then return.

### Confidence → Severity Bucket Mapping (inherited verbatim — fence-critical)

Every finding carries a 0–100 confidence score. Apply this mapping without exception:

| Confidence | Severity Bucket | When to use |
|------------|-----------------|-------------|
| 91–100 | **Blocker** | Explicit canonical-chain violation, missing required trace, severity-fence breach, governance-gate breach, scope origination |
| 80–90 | **Major** or **Minor** | High-likelihood concern with specific evidence; **Major** if it blocks admission/landing OR breaks the canonical chain, **Minor** if it affects quality / coverage / readability |
| < 80 | **Excluded — drop entirely** | Do not include in any bucket. Do not mention in the report. |

Rationale: false positives in plan review waste fixer-loop iterations that count against the 3-loop ceiling. The < 80 floor protects the loop.

**Severity-downsizing is forbidden** — never demote Blocker → Major to escape a halt. The caller's fix-loop pivots on Blocker/Major (auto-fix) vs Minor/Nit (file to operator-todos). Inversion of that gate is a banlist item in every mode below.

### Mandatory Outputs (inherited verbatim)

Every mode invocation MUST produce ALL of these:

| # | What | Where |
|---|------|-------|
| 1 | **Scope announcement** before any dimension analysis: `Reviewing: <target_path> (<mode> mode, <N> dimensions)` | Inline-to-caller (1 line only) |
| 2 | **Report file written to disk** at `<scratch_dir>/<report_filename>` (defaulted by caller — NOT chosen by skill). Never only inline text. | Disk file |
| 3 | **Exactly four severity buckets** in the report — named precisely: `Blocker`, `Major`, `Minor`, `Nit`. No other names. | Report file |
| 4 | **Dimension coverage table** — all `<N>` rows (where `<N>` is the per-mode dimension count), each with finding count and one-line status. **Table appears at the top of the report, immediately after the summary header — before any finding sections.** | Report file |
| 5 | **Inline summary after writing report** — full absolute file path to the written report, severity counts (`X Blockers · Y Major · Z Minor · W Nit`). NEVER reproduce findings inline. | Inline-to-caller |

### Report shape (inherited verbatim — modes fill in the dimension table only)

```markdown
# IDC Plan Review — <mode> — <YYYY-MM-DD-HHMM>

**Target:** `<target_path>`
**Brief:** `<brief_path>`
**Mode:** `<mode>`
**Severity counts:** X Blockers · Y Major · Z Minor · W Nit

---

## Dimension coverage

| # | Dimension | Findings | Status |
|---|-----------|----------|--------|
<one row per dimension — N rows total, with finding count and one-line status (e.g. "0 — clean", "2 — Major × 2", "0 — unverified")>

---

## Blockers
<one section per finding, or "None.">

### <short title>
- **Dimension:** <dimension name>
- **Location:** `<file>:<line>` or `<file>:<H1-heading>` for prose plans
- **Confidence:** <0-100, must be ≥ 80 to appear>
- **What:** <description>
- **Why it matters:** <impact on canonical chain>
- **Suggested fix:** <concrete change>

## Major
<same structure>

## Minor
<same structure>

## Nit
<same structure>

---

## Scope detail

<list any scratch files consulted (codex-plan-review.md, governance-trace-audit.md, etc.) so the caller's auditor can verify completeness>
```

### What this skill does NOT do (inherited verbatim)

Hard constraints — every mode inherits these:

- **No edits to the target draft.** Plan review is read-only; fixes happen via WD-3 `idc:idc-skill-plan-patch-from-findings` invoked by the orchestrator's findings-union step.
- **No edits to canonical docs.** Plan review NEVER touches PRD, master architectural spec, master implementation plan, subphase plans, pillar plans, or TRACKER.
- **No `/codex:adversarial-review` invocation.** That's WD-1's job; this skill is the IDC-side custom-plan-reviewer half of the pair.
- **No `simplify` invocation.** This skill is plan-shaped, not code-shaped — there is no Step 1.5 polish pass.
- **No test runs.** Plans don't run; specs/contracts validate via `tests/test_arch_*.py` fences which are flagged-as-obligation, not exercised by the reviewer.
- **No repro scripts.** Plan review is static; flag suspicions and move on.

### Findings-union compatibility (load-bearing for orchestrator findings-union step)

A mode's report MUST be findings-union-compatible with WD-1's adversarial-review report. The fields that the union logic depends on:

- `Severity` ∈ {Blocker, Major, Minor, Nit} — same vocabulary as WD-1's IDC bucket
- `Location` — `<file>:<line>` or `<file>:<H1-heading>` (caller's deduplicator hashes this)
- `Confidence` — 80–100 only (anything < 80 must not appear)
- `Suggested fix` — single-shot patch hint (WD-3 reads this when generating its patch plan)

Per-mode bodies MAY add per-role fields (e.g. `Affected Authority Surface`, `Trace Triple Element Missing`) but MUST NOT remove any of the four above.

---

## Mode 1 — `admission` (Plan / Engineer admission-shape, 8 dimensions)

Replaces former `canonical-doc-review`. Reviews admission-shape artifacts: a PRD section edit, a master architectural spec edit, and a master implementation plan §Domain + §Phase admission. The 13 code-shaped dimensions are replaced by 8 admission-shape dimensions extracted from `${CLAUDE_PLUGIN_ROOT}/agents/idc-plan.md` (formerly `idc-engineer.md`).

### Input contract (`admission`)

| Field | Shape |
|-------|-------|
| `target_path` | absolute path to the admission packet (typically a directory containing `prd-diff.md`, `arch-spec-diff.md`, `master-plan-diff.md`) — OR a single file if only one canonical doc edit is in scope |
| `scratch_dir` | absolute path to the orchestrator's per-run scratch dir |
| `report_filename` | basename inside `scratch_dir` (caller-supplied; defaults to `custom-admission-review.md`) |
| `brief_path` | absolute path to the 5–30 line review brief (names: which considerations are being admitted, which authority surfaces are touched, which fitness fences should fire) |
| `evidence_dir` | absolute path to the directory holding sibling scratch artifacts: codebase-context-curator packet, considerations-triage packet, governance-verdict output, codex-admission-adversarial-reviewer report |

### The 8 admission-shape dimensions (`admission`)

Source authority: `${CLAUDE_PLUGIN_ROOT}/agents/idc-plan.md` (Engineer Gate + RFD §Phase boundary + auto-advance frontmatter contract) + per-role audit `engineer.md §ES-8`.

| # | Dimension | Probe | Artifacts consulted |
|---|-----------|-------|---------------------|
| 1 | **RFD §Phase boundary kept** | Does the master-plan diff stop at §Domain + §Phase admission? Any scaffolded subphase subsections inside the §Phase block? Any candidate-pillar names at master-plan layer? | `master-plan-diff.md` |
| 2 | **Governance obligations all addressed** | For each obligation flagged by `idc:idc-skill-canonical-admission-audit` (ES-2), is the corresponding plan section + execution action present? | `evidence_dir/canonical-admission-audit.md`, `master-plan-diff.md` |
| 3 | **Considerations open-questions all surfaced or resolved** | Every Q-* in admitted considerations files either resolved with a plan section anchor OR explicitly carried forward as an open question | `evidence_dir/considerations-triage.md`, considerations files cited |
| 4 | **Ripple-downstream targets explicit** | If the diff edits PRD or arch-spec, does it list the downstream subphase/pillar/TRACKER docs that must be re-synchronized in the same Ripple PR? | `target_path` body, `evidence_dir/governance-verdict.md` |
| 5 | **Architectural-fitness fences flagged** | Every fence trigger from the admission-audit obligations table is named in the plan diff (or its absence is justified) — even if the fence won't be authored in this packet | `evidence_dir/canonical-admission-audit.md` §fence-trigger inventory, `target_path` body |
| 6 | **Considerations files cited** | Every authored section traces to at least one admitted considerations file under `docs/considerations/` | `target_path` body |
| 7 | **Authority boundaries respected** | No edits to subphase plans, pillar plans, TRACKER, source code, tests, or any subdir CLAUDE.md | full diff inspection |
| 8 | **Auto-advance frontmatter contract honored** | If a handoff is staged in the same packet, its 7-key R6 Phase A frontmatter is present and consistent with the admission verdict | `<scratch_dir>/draft-handoff.md` if present |

### Procedure (`admission`)

1. **Read the brief** at `brief_path`. Absorb the considerations-being-admitted + the authority surfaces touched + the fitness fences expected.
2. **Read scratch artifacts** named in the brief: `<evidence_dir>/canonical-admission-audit.md`, `<evidence_dir>/considerations-triage.md`, `<evidence_dir>/governance-verdict.md`, and any sibling scratch files.
3. **Read the target admission packet** at `target_path`. For directory targets, inspect each diff file in turn.
4. **Run dimensions 1–8** sequentially against the target packet + the scratch evidence:
   - For each finding ≥ 80 confidence, record `{dimension, location, confidence, what, why, suggested-fix}`.
   - For findings 91–100 confidence, severity = Blocker.
   - For findings 80–90 confidence, choose Major (blocks admission OR breaks canonical chain) vs Minor (quality/coverage/readability) per the base mapping.
   - Drop findings < 80 confidence entirely.
5. **Write the report** to `<scratch_dir>/<report_filename>` per the WD-2 base report shape with the 8-row dimension table.
6. **Return** a 1-line confirmation: `report written: <abs path> · X Blockers · Y Major · Z Minor · W Nit`.

### `admission` banlist (extends WD-2 base banlist)

- **Do NOT flag findings inside admitted considerations files themselves.** The reviewer's scope is the admission packet (PRD/spec/master-plan diffs), not the upstream considerations — those passed Plan's Phase 1 considerations-triage gate. Flagging them here re-litigates Phase 1.
- **Do NOT flag missing pillar-level detail at master-plan layer.** RFD §Phase boundary discipline says master plan admits §Domain + §Phase only — pillar-level detail is Plan's downstream cognitive surface (Develop). Flagging "no pillar enumeration here" is a category error.
- **Do NOT auto-elevate Major → Blocker for fence-triggering changes.** Fence triggers are obligations, not blockers — the obligation flag fires; Build authors the fence. Reviewer flags missing-fence-flag at Major, not Blocker.

### Halt conditions (`admission`)

This mode halts (writes a halt-stub at the report path, returns halt string) under any of:

1. `target_path` missing on disk → `BLOCKED — target_path missing`
2. `scratch_dir` missing → `BLOCKED — scratch_dir missing`
3. `evidence_dir/canonical-admission-audit.md` missing AND no override flag in brief → `BLOCKED — admission-audit evidence missing`. ES-2's audit is the source for dimensions 2 + 5.
4. Brief is empty → `BLOCKED — brief missing or empty`.

---

## Mode 2 — `subphase` (Plan / Develop subphase-shape, 10 dimensions)

Replaces former `plan-custom-review`. Reviews subphase-plan-shape artifacts: a canonical subphase plan draft including its load-bearing `§Rough Pillars` inline section (RFD principle), §Wave-Orchestrator Handoff section, `Upstream Master Plan Domain/Phase` trace declaration, and authority surface. The 13 code-shaped dimensions are replaced by 10 plan-shape dimensions extracted from `${CLAUDE_PLUGIN_ROOT}/agents/idc-plan.md` (formerly `idc-develop.md` line 128).

### Input contract (`subphase`)

| Field | Shape |
|-------|-------|
| `target_path` | absolute path to the subphase-plan draft (typically `<scratch_dir>/draft-subphase.md` or `<scratch_dir>/draft-subphase-vN.md` on fix-loop iterations) |
| `scratch_dir` | absolute path to the orchestrator's per-run scratch dir |
| `report_filename` | basename inside `scratch_dir` (caller-supplied; defaults to `custom-plan-review.md`) |
| `brief_path` | absolute path to the 5–30 line brief (names: which master-plan §Phase the subphase descends from, which sibling subphases share dependencies, which architectural-fitness fences are expected) |
| `evidence_dir` | absolute path to the directory holding sibling scratch artifacts: codebase-context-curator packet, governance-trace-audit (DS-1), prior-art-pattern-read (DS-2), codex-plan-adversarial-reviewer report |

### The 10 plan-shape dimensions (`subphase`)

Source authority: `${CLAUDE_PLUGIN_ROOT}/agents/idc-plan.md` + per-role audit `develop.md §WD-2b`. The 10 dimensions are the verbatim list from the parent agent's `custom-plan-reviewer` prompt, restated here so this mode is self-contained.

| # | Dimension | Probe | Artifacts consulted |
|---|-----------|-------|---------------------|
| 1 | **Silent-failure planning gaps** | For each work packet's named codepath, does the plan identify at least one realistic production failure scenario AND the recovery / error-handling story for it? Or does the plan assume all-or-nothing success? | `target_path` work-packet sections |
| 2 | **Security/auth surface coverage** | Does the plan name the authentication, authorization, secret-handling, or trust-boundary impact of each work packet? | `target_path` + `evidence_dir/codebase-context-curator.md` |
| 3 | **Missing tests** | Every work packet has either (a) a named test target, OR (b) an explicit "no test added — rationale: ..." disclaimer | `target_path` work-packet sections |
| 4 | **Brittle dependency sequencing** | Inter-pillar / inter-subphase dependencies declared with concrete ordering; no implicit "Pillar B works only after Pillar A merges" assumptions | `target_path` Dependencies + §Rough Pillars `dependencies` field |
| 5 | **Unclear ownership** | Every file surface in `§Rough Pillars` lists exclusive owner pillar (or explicitly declares shared with a list of co-owners) | `§Rough Pillars` `file_surfaces` field |
| 6 | **Hidden coupling** | Search the plan for adjacent-pillar references that aren't in Dependencies; flag any work packet that touches a file owned by another pillar | `target_path` + sibling subphase pointers in `evidence_dir/prior-art-pattern-read.md` |
| 7 | **Missing operator gates** | Is every operator-decision point explicit? (e.g. credentials needed, console click, OAuth consent) — surface at the right landing layer | `target_path` Operator Gates section |
| 8 | **Canonical-doc violations** | No diff to PRD, master architectural spec, master implementation plan, pillar plans, TRACKER, source code, tests, or any subdir CLAUDE.md | full diff inspection vs target_path |
| 9 | **Governance-trace integrity** | `Upstream Master Plan Domain/Phase` declaration verbatim from DS-1 governance-trace-audit; `§Rough Pillars Source` pointer present and correct | `evidence_dir/governance-trace-audit.md`, `target_path` header |
| 10 | **Parallel-safety claims** | `§Rough Pillars` `parallel_safety_hints` field per pillar is concrete (cites file surfaces) — never the word "safe" alone | `§Rough Pillars` per-pillar entries |

Plus the load-bearing inheritance check (must always pass — fenced as Blocker if missing):

- **§Rough Pillars section present.** Anti-pattern: "Skip the `§Rough Pillars` section. It is the canonical RFD handoff to Deconflict; without it the subphase plan is non-canonical." Missing section → Blocker, no exceptions.

### Procedure (`subphase`)

1. **Read the brief** at `brief_path`. Absorb the master-plan §Phase context + sibling-subphase dependencies + expected fitness fences.
2. **Read scratch artifacts** named in the brief: `<evidence_dir>/governance-trace-audit.md`, `<evidence_dir>/codebase-context-curator.md`, `<evidence_dir>/prior-art-pattern-read.md`.
3. **Read the target draft** at `target_path` end-to-end. Locate `§Rough Pillars` section explicitly — if absent, the run halts with Blocker.
4. **Run dimensions 1–10** against the draft + scratch evidence. Apply confidence ≥ 80 floor. Drop everything else.
5. **Special-case `§Rough Pillars` shape validation.** Each rough pillar entry MUST have all four required fields (`rough_scope`, `file_surfaces`, `dependencies`, `parallel_safety_hints`). Missing field → Blocker. Validation invoked here mirrors what DS-3 `idc:idc-skill-rough-pillars-section` enforces at write-time.
6. **Write the report** to `<scratch_dir>/<report_filename>` per WD-2 base report shape with the 10-row dimension table.
7. **Return** a 1-line confirmation: `report written: <abs path> · X Blockers · Y Major · Z Minor · W Nit`.

### `subphase` banlist (extends WD-2 base banlist)

- **Do NOT flag missing pillar-level detail beyond `§Rough Pillars`.** Detailed pillar plans are polished separately (now Plan's `pillar` mode). The reviewer must accept rough scope + file surfaces + dependencies as the complete handoff — the "how to actually implement" detail is not the subphase reviewer's gate.
- **Do NOT flag clash with sibling pillars.** Cross-pillar clashes are KS-2 authority. The subphase reviewer flags only intra-subphase coherence.
- **Do NOT flag wave-ordering or matrix-synth concerns.** That's Sequence's QR-3 authority. The subphase reviewer flags only RFD §Phase-boundary discipline within its own subphase.
- **Severity-downsize forbidden** specifically for: missing `§Rough Pillars` section (always Blocker), missing `Upstream Master Plan Domain/Phase` declaration (always Blocker), edits to PRD/spec/master-plan/pillars/TRACKER/source/tests/CLAUDE.md (always Blocker).

### Halt conditions (`subphase`)

This mode halts under any of:

1. `target_path` missing → `BLOCKED — target_path missing`
2. `scratch_dir` missing → `BLOCKED — scratch_dir missing`
3. `evidence_dir/governance-trace-audit.md` missing AND no override flag in brief → `BLOCKED — governance-trace evidence missing`. DS-1's audit is the source for dimension 9.
4. Brief is empty → `BLOCKED — brief missing or empty`.

---

## Mode 3 — `pillar` (Plan / Deconflict pillar-shape, 8 dimensions)

Replaces former `pillar-plan-review`. Reviews polished pillar-plan-shape artifacts: a canonical pillar plan draft (or a directory of pillar drafts polished from one subphase's `§Rough Pillars`) including the **trace triple** (`Upstream Subphase` + `Upstream Master Plan Domain/Phase` + `§Rough Pillars Source`), Pillar Resource Ownership table, and Conflict Resolution sections referencing clash-evidence files. The 13 code-shaped dimensions are replaced by 8 pillar-shape dimensions extracted from `${CLAUDE_PLUGIN_ROOT}/agents/idc-plan.md` (formerly `idc-deconflict.md` line 198).

### Input contract (`pillar`)

| Field | Shape |
|-------|-------|
| `target_path` | absolute path to the pillar-plan draft OR a directory of pillar drafts under polish in this run |
| `scratch_dir` | absolute path to the orchestrator's per-run scratch dir |
| `report_filename` | basename inside `scratch_dir` (caller-supplied; defaults to `custom-pillar-review.md`) |
| `brief_path` | absolute path to the 5–30 line brief (names: upstream subphase, sibling pillars under polish in this run, expected clash-evidence files) |
| `evidence_dir` | absolute path to the directory holding: subphase-ingestion (KS-1), pillar-clash-analysis (KS-2), sibling-pillar-precedent-review (KS-3), pillar-resource-ownership shards (WM-1), clash-evidence files (WM-2), codex-pillar-adversarial-reviewer report |

### The 8 pillar-shape dimensions (`pillar`)

Source authority: `${CLAUDE_PLUGIN_ROOT}/agents/idc-plan.md` + per-role audit `deconflict.md §WD-2c`. The dimensions are extracted verbatim from the parent agent's `custom-pillar-reviewer` prompt.

| # | Dimension | Probe | Artifacts consulted |
|---|-----------|-------|---------------------|
| 1 | **Parallel-safety claims** | Pillar Resource Ownership table `Parallel-safe with` column populated for every row; `shared` rows enumerate every co-owning pillar | Pillar Resource Ownership table in `target_path` |
| 2 | **File-surface ownership integrity** | Every file surface declared by this pillar appears in the ownership table with `Resource Kind ∈ {file, service, doc, governance}` and `Ownership ∈ {exclusive, shared}` (banlist enforced) | ownership table |
| 3 | **Trace-back completeness** | All three trace declarations present and consistent: `Upstream Subphase`, `Upstream Master Plan Domain/Phase`, `§Rough Pillars Source` | `target_path` header + `evidence_dir/subphase-ingestion.md` |
| 4 | **Sibling-pillar coupling** | No work packet writes to a file surface owned exclusively by a sibling pillar; shared writes appear in both pillars' ownership tables | KS-2 `pillar-clash-analysis.md`, sibling pillar headers from KS-3 |
| 5 | **Missing tests** | Every work packet either names a test target OR explicitly declares "no test added — rationale" | `target_path` work-packet sections |
| 6 | **Brittle dependency sequencing** | `Blocks on:` directives concrete (cite specific pillar IDs); no implicit ordering | ownership table `Blocks on:` rows + Dependencies section |
| 7 | **Conflict-resolution coherence** | For every clash named in `evidence_dir/pillar-clash-analysis.md`, the pillar plan has a Conflict Resolution section pointing to the corresponding `docs/workflow/pillar-conflicts/<a>-<b>-pillar-conflicts.md` file | KS-2 output + `target_path` Conflict Resolution sections |
| 8 | **Governance violations** | No diffs to PRD, master architectural spec, master implementation plan, subphase plans, TRACKER, source code, tests, or any subdir CLAUDE.md from this pillar plan | full diff inspection |

### Procedure (`pillar`)

1. **Read the brief** at `brief_path`. Absorb upstream-subphase context + sibling-pillar list + expected clash-evidence files.
2. **Read scratch artifacts**: `<evidence_dir>/subphase-ingestion.md`, `<evidence_dir>/pillar-clash-analysis.md`, `<evidence_dir>/sibling-pillar-precedent-review.md`. For directory `target_path`, also enumerate `<evidence_dir>/pillar-resource-ownership/*.md` shards (WM-1 emission per pillar).
3. **Read the target pillar draft(s)** at `target_path` end-to-end. For multi-pillar runs, each pillar gets dimensions 1–8 evaluated independently; findings tagged with the pillar slug.
4. **Trace-triple gate (Blocker)**: validate all three trace declarations present + consistent with `evidence_dir/subphase-ingestion.md`. Missing any → Blocker.
5. **Ownership-table schema gate (Blocker)**: validate `Resource Kind` column values are subset of `{file, service, doc, governance}` and `Ownership` column values are subset of `{exclusive, shared}`. Out-of-enum → Blocker.
6. **Run dimensions 1–8** against the draft + scratch evidence. Apply confidence ≥ 80 floor.
7. **Cross-pillar clash-resolution check**: for every entry in KS-2's `clash_register`, the pillar plan has a Conflict Resolution section linking to the corresponding `pillar-conflicts/<a>-<b>-pillar-conflicts.md` file. Missing reference → Major (the clash file may exist but the pillar plan didn't cross-reference it).
8. **Write the report** to `<scratch_dir>/<report_filename>` per WD-2 base shape with 8-row dimension table.
9. **Return** a 1-line confirmation: `report written: <abs path> · X Blockers · Y Major · Z Minor · W Nit`.

### `pillar` banlist (extends WD-2 base banlist)

- **Do NOT recommend changes to existing landed sibling pillars.** Polished + merged pillar plans are immutable post-merge (per KS-3 read-only authority). If a clash with a landed sibling appears, it routes to Ripple via KS-5, not via review-side recommendation.
- **Do NOT flag matrix-synth or wave-ordering concerns.** That's Sequence's QR-3 authority. The pillar reviewer flags only per-pillar coherence + cross-pillar clashes within this run.
- **Do NOT lower the trace-triple Blocker.** Anti-pattern hard-encoded in KS-4 `idc:idc-skill-pillar-plan-shape`.
- **Do NOT downsize ownership-enum violations.** Resource Kind out-of-enum AND Ownership out-of-enum are both Blocker.
- **Do NOT flag missing tests for documentation-only pillar plans.** A pillar plan that has no work packet with a code surface produces no test obligation; flag missing tests only when work packets touch source code.

### Halt conditions (`pillar`)

This mode halts under any of:

1. `target_path` missing → `BLOCKED — target_path missing`
2. `scratch_dir` missing → `BLOCKED — scratch_dir missing`
3. `evidence_dir/pillar-clash-analysis.md` missing AND brief lists no override → `BLOCKED — clash-analysis evidence missing`. KS-2's output is the source for dimensions 4 + 7.
4. Brief is empty → `BLOCKED — brief missing or empty`.

---

## Mode 4 — `tracker` (Sequence tracker-shape, 4 dimensions)

Replaces former `tracker-edit-review-pass`. Reviews tracker-shape artifacts: a proposed Tracker edit expressed as a set of GraphQL mutations against the GitHub Projects V2 substrate (admit-time wave-queue admit, janitor-mode reflow, lane-pointer correction, bookend-open). The 13 code-shaped dimensions are replaced by 4 tracker-shape dimensions extracted from `${CLAUDE_PLUGIN_ROOT}/agents/idc-sequence.md`.

Backend-aware: when `tracker-config.yaml::backend = github` (default post-Phase-7 migration) the proposed edit is a GraphQL mutation spec; when `backend = filesystem` it is a TRACKER.md body diff. The 4 dimensions apply uniformly through the `idc:idc-skill-tracker-adapter` substrate; backend differences are absorbed by the adapter, not by this reviewer.

### Tracker-mode-specific severity note

Severity-downsizing forbidden — `tests/test_arch_github_tracker.py` pins the GitHub Projects V2 backend bootstrap shape (project-number lookup, field-id resolution, six-method dispatch parity with the portable Tracker interface). Bootstrap-fence violations are always Blocker. Filesystem-backend fallback retains its own bootstrap shape via the renamed `idc:idc-skill-filesystem-tracker-implementation`.

### Input contract (`tracker`)

| Field | Shape |
|-------|-------|
| `target_path` | absolute path to the proposed edit spec. **GraphQL backend (default):** `<scratch_dir>/proposed-mutations.json` — a structured GraphQL mutation set (list of `{op, target_id, field, value, mutation_text}` rows covering `gh issue create` / `gh issue edit` / `gh project item-add` / `gh project item-edit` / Projects V2 GraphQL `addProjectV2ItemById` / `updateProjectV2ItemFieldValue`) emitted by QS-1 `idc:idc-skill-github-tracker-implementation`. **Filesystem-backend fallback:** `<scratch_dir>/proposed-tracker.md` body emitted by `idc:idc-skill-filesystem-tracker-implementation` |
| `current_state_path` | absolute path to current Tracker state. **GraphQL backend:** JSON snapshot from `scripts/sync_github_tracker.py --export-state` (the `--tracker-state` JSON consumed by `pillar_matrix.py --dispatch-check`). **Filesystem backend:** `TRACKER.md` on disk (e.g. `<governed-repo>/TRACKER.md`). Caller routes through `idc:idc-skill-tracker-adapter` to obtain |
| `scratch_dir` | absolute path to Sequence's per-run scratch dir |
| `report_filename` | basename inside `scratch_dir` (caller-supplied; defaults to `tracker-edit-review.md`) |
| `brief_path` | absolute path to the 5–30 line brief (names: edit mode (admit / janitor / lane-pointer-fix / bookend-open), polished pillar-plan trace keys this edit cites, expected wave-queue layout, **backend in effect**) |
| `evidence_dir` | absolute path holding: matrix YAML (`<phase-tag>-matrix.yaml`), governance-verdict (CS-4) output, polished pillar-plan paths cited |

### The 4 tracker-shape dimensions (`tracker`)

Source authority: `${CLAUDE_PLUGIN_ROOT}/agents/idc-sequence.md` (bootstrap fence + active-wave-stays-detailed rule + scope-origination guard) + per-role audit `sequence.md §QS-2`.

| # | Dimension | Probe | Artifacts consulted |
|---|-----------|-------|---------------------|
| 1 | **Governance verdict trace** | Every Tracker edit traces to a CS-4 governance-verdict output (binary `tracker-only` vs `ripple-required`). Verdict = `tracker-only` is the precondition for any Tracker landing. Holds across both GraphQL and filesystem backends — backend choice does not relax the verdict precondition | `evidence_dir/governance-verdict.md` |
| 2 | **Scope-invention scan** | Every proposed mutation (issue-create body, project item-add target, Currently-building lane-pointer field set, Wave-Queue field write) maps to an existing polished pillar plan at `docs/plans/pillars/`. Missing pillar plan → either a phantom (route to Develop or Ripple) OR a Sequence-originated scope (forbidden — load-bearing scope-origination guard) | proposed mutation set / TRACKER body, `docs/plans/pillars/` enumeration, `evidence_dir/<phase-tag>-matrix.yaml` |
| 3 | **Parallel-safety risk** | Lane-pointer mutations (Currently-building / Status:Active field updates across lanes) consistent with matrix YAML's `parallel_safe_with` field (no two non-`(idle)` Active items across lanes that the matrix declares unsafe to parallelize) | proposed lane-mutation block + `evidence_dir/<phase-tag>-matrix.yaml` |
| 4 | **Fresh-LLM-startup readability** | After the proposed mutations are applied, would a fresh session reading the Project board (GraphQL backend — Active-status filter view + first-page issue ordering) or the TRACKER.md body (filesystem backend — first 30 lines + active-phase block) know "what's next" in <30s? Active items must carry T-numbered checkboxes / detailed acceptance criteria; inactive phases pointer-only (per active-phase-stays-detailed rule) | proposed mutation set applied to current state (simulate) — holistic read |

### Procedure (`tracker`)

1. **Read the brief** at `brief_path`. Absorb edit-mode + cited polished pillar-plan trace keys + **backend in effect** (`github` or `filesystem`).
2. **Read scratch artifacts**: `<evidence_dir>/governance-verdict.md`, `<evidence_dir>/<phase-tag>-matrix.yaml` (if Phase 2 admit-mode).
3. **Diff proposed vs current** (backend-routed):
   - **GraphQL backend:** parse `target_path` mutation set; for each mutation `{op, target_id, field, value}`, look up `target_id` in the `current_state_path` JSON snapshot and compute the post-apply delta. The dimension scan operates against the mutation set + post-apply delta — not the full Project board.
   - **Filesystem backend:** `diff <current_state_path> <target_path>`. The dimension scan operates against the markdown diff scope.
4. **Bootstrap-fence gate (Blocker)**:
   - **GraphQL backend:** validate the proposed mutation set does not contradict the Projects V2 bootstrap shape (project-number lookup intact, field IDs resolved against `tracker-config.yaml::field_ids`, six-method dispatch parity preserved — pinned by `tests/test_arch_github_tracker.py`).
   - **Filesystem backend:** validate the first 30 lines of proposed TRACKER unchanged from current OR explicitly authorized in brief. The "Recently completed" label remains intact.
   - Any drift in either backend → Blocker.
5. **Active-wave-stays-detailed gate (Blocker for compaction)**: if proposed edit compacts the active phase to pointer-only (forbidden during decomposition), → Blocker. For GraphQL backend this means stripping T-checkbox body content from Active-status issues; for filesystem backend this means flattening the active-phase block.
6. **Run dimensions 1–4** against the diff + scratch evidence. Apply confidence ≥ 80 floor.
7. **Bookend-class check**: validate the proposed edit is bookend-open class (Sequence's authority — GraphQL: `gh issue edit --add-label bookend-open,wave:N,active` + `gh project item-edit --field Status --value Active`; filesystem: TRACKER.md wave-queue admit) AND not bookend-close class (Build's authority — GraphQL: `gh issue close <num>` + `gh project item-edit --field Status --value Complete`; filesystem: TRACKER.md "Recently completed" promotion). A bookend-close mutation from Sequence → Blocker (authority violation).
8. **Write the report** to `<scratch_dir>/<report_filename>` per WD-2 base shape with 4-row dimension table.
9. **Return** a 1-line confirmation: `report written: <abs path> · X Blockers · Y Major · Z Minor · W Nit`.

### `tracker` banlist (extends WD-2 base banlist)

- **Do NOT flag missing pillar-level scope.** Tracker cites plan-derived units only; per the scope-origination guard, missing scope routes to Develop or Ripple, not to Tracker. Reviewer flags scope-origination at Blocker, never recommends adding it.
- **Do NOT flag wave-ordering as Major+ on operator-judgment-call edits.** Wave ordering encodes operator preference within the matrix's parallel-safety constraints. Reviewer flags wave-ordering only when matrix YAML disagrees with proposed lanes (parallel-safety risk = dimension 3).
- **Do NOT flag bookend-open commit message style.** Sequence emits bookend-open with conventional `tracker:` prefix; commit-message style is not a Tracker-edit-shape concern.
- **Do NOT flag GraphQL-vs-REST API choice.** The `idc:idc-skill-github-tracker-implementation` substrate picks the API form (GraphQL Projects V2 vs `gh issue` / `gh project item-*` REST) per Projects V2 requirements; this reviewer does not litigate API choice.
- **Do NOT flag backend choice (`github` vs `filesystem`).** Backend selection is `tracker-config.yaml::backend`'s authority, resolved by `idc:idc-skill-tracker-adapter`. The reviewer applies the same 4-dimension schema regardless of backend.
- **Severity-downsize forbidden** for: bootstrap-fence violation (always Blocker), scope-origination (always Blocker), bookend-close authoring (always Blocker — Build's authority).

### Halt conditions (`tracker`)

This mode halts under any of:

1. `target_path` missing → `BLOCKED — target_path missing`
2. `current_state_path` missing → `BLOCKED — current_state_path missing`
3. `evidence_dir/governance-verdict.md` missing → `BLOCKED — governance-verdict evidence missing`. CS-4 verdict is precondition for any Tracker edit.
4. Brief is empty → `BLOCKED — brief missing or empty`.
5. Backend in effect cannot be resolved (brief silent AND `tracker-config.yaml::backend` unreadable) → `BLOCKED — backend unresolved`.
6. GraphQL backend in effect AND `target_path` is not parseable as a structured mutation set → `BLOCKED — proposed-mutations spec malformed`.

---

## Mode 5 — `ripple` (Ripple change-order-shape, 5 dimensions)

Replaces former `correctness-review`. Reviews change-order-shape artifacts: a Ripple change-order draft at `<scratch_dir>/draft-ripple.md` including its `Pipeline:`, `Verdict:`, `Master Plan Section:`, `Affected Role/Skill Authority:`, downstream-sync ripple plan, architectural-fitness obligations, and CLAUDE.md tree impact declaration. The 13 code-shaped dimensions are replaced by 5 ripple-shape dimensions extracted from `${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md`.

### Ripple-mode-specific severity note

Severity-downsizing forbidden — Ripple's `Pipeline:` field, `Verdict:` enum, and `Master Plan Section:` + `Affected Role/Skill Authority:` citation fields are fence-pinned by `tests/test_arch_governance_pipeline.py` and `tests/test_arch_idc_ripple.py`. Schema-fence violations are always Blocker.

### Input contract (`ripple`)

| Field | Shape |
|-------|-------|
| `target_path` | absolute path to the change-order draft (typically `<scratch_dir>/draft-ripple.md` or `<scratch_dir>/draft-ripple-vN.md` on fix-loop iterations) |
| `scratch_dir` | absolute path to Ripple's per-run scratch dir |
| `report_filename` | basename inside `scratch_dir` (caller-supplied; defaults to `correctness-review.md`) |
| `brief_path` | absolute path to the 5–30 line brief (names: drift source, claimed highest-affected layer, Pipeline classification, claimed Verdict) |
| `evidence_dir` | absolute path holding: drift-evidence (RS-1), impact-classifier (now `idc:idc-skill-ripple-verdict`) output (the 4-tuple), CLAUDE.md tree audit (now folded into `idc:idc-skill-ripple-verdict`), codex-ripple-adversarial-reviewer report |

### The 5 ripple-shape dimensions (`ripple`)

Source authority: `${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md` + per-role audit `ripple.md §RS-5`.

| # | Dimension | Probe | Artifacts consulted |
|---|-----------|-------|---------------------|
| 1 | **Highest-affected-layer correctness** | The `highest_affected_layer` claimed by the change order matches the `idc:idc-skill-ripple-verdict` classifier output (`{prd, master-architectural-spec, master-implementation-plan, subphase, pillar, root-claude-md, subdir-claude-md, governance-fence, source}`). Surface-based classification rule applied (codebase vs governance pipeline) | `evidence_dir/impact-classifier.md`, `target_path` `Highest Affected Layer:` field |
| 2 | **Downstream-sync completeness** | The change order's downstream-sync ripple plan covers every layer below the highest affected — no gaps. Per anti-pattern of `idc-ripple.md` ("Defer downstream sync forbidden"): same PR, never follow-up | `evidence_dir/impact-classifier.md` `downstream_sync_map`, `target_path` Downstream Sync section |
| 3 | **Architectural-fitness coverage** | Every fence trigger from `idc:idc-skill-ripple-verdict`'s `architectural_fitness_obligations` list is named in the change order (or its absence is justified) | `evidence_dir/impact-classifier.md`, `target_path` Fitness Obligations section |
| 4 | **Governance-gate coverage** | The change order names the correct gate per `Verdict:` value: `MAJOR_GATED` (PRD/arch-spec) → pre-drafting AND pre-merge approval; `GATED` (master-plan/subphase/pillar/root CLAUDE.md/governance fence) → pre-merge approval; `MINOR_AUTONOMOUS` → no operator gate (autonomous-merge ledger entry instead); `NO_RIPPLE` → no PR opens. CLAUDE.md tree impact declared (default `none` with rationale) | `target_path` Operator Gates section + `Verdict:` field + CLAUDE.md tree impact line |
| 5 | **Hand-back integrity** | The change order's hand-back-instructions branch on `Pipeline:` (governance vs codebase). For governance: hands back to `docs/workflow/audits/` + paired plan. For codebase: hands back to the IDC role whose authority surface was the drift source. Hand-back is concrete (names role, names artifact path) | `target_path` Hand-back section, `evidence_dir/drift-evidence.md` |

### Procedure (`ripple`)

1. **Read the brief** at `brief_path`. Absorb drift source + claimed `highest_affected_layer` + claimed `Verdict`.
2. **Read scratch artifacts**: `<evidence_dir>/drift-evidence.md`, `<evidence_dir>/impact-classifier.md` (the 4-tuple), `<evidence_dir>/claude-md-tree-audit.md` (if the tree-audit sub-procedure of `idc:idc-skill-ripple-verdict` fired).
3. **Read the target change-order draft** at `target_path` end-to-end.
4. **Schema-fence gates (Blocker)**:
   - `Pipeline:` field present and value ∈ `{governance, codebase}` exactly. Out-of-enum → Blocker.
   - `Verdict:` field present and value ∈ `{NO_RIPPLE, MINOR_AUTONOMOUS, GATED, MAJOR_GATED}` exactly. Out-of-enum → Blocker.
   - `Master Plan Section:` AND `Affected Role/Skill Authority:` BOTH present (regardless of pipeline). Missing either → Blocker.
   - CLAUDE.md tree impact declaration present (`none` with rationale OR enumerated). Missing → Blocker.
5. **Run dimensions 1–5** against the draft + scratch evidence. Apply confidence ≥ 80 floor.
6. **Cross-check `Verdict:` matches the four-condition gate** per `tests/test_arch_idc_ripple.py::test_minor_autonomous_path_exists`. If `MINOR_AUTONOMOUS` claimed but the four conditions don't all hold → Blocker.
7. **Write the report** to `<scratch_dir>/<report_filename>` per WD-2 base shape with 5-row dimension table.
8. **Return** a 1-line confirmation: `report written: <abs path> · X Blockers · Y Major · Z Minor · W Nit`.

### `ripple` banlist (extends WD-2 base banlist)

- **Do NOT recommend operator-decision overrides on `Verdict:` value.** Verdict is `idc:idc-skill-ripple-verdict`'s authority. Reviewer flags mismatch between claimed Verdict and the four-condition gate at Blocker (dimension 6 cross-check), but never proposes a different Verdict — that's Ripple's authority.
- **Do NOT flag missing canonical-doc body content.** The change order's `proposed canonical edits` field IS the diff; reviewer doesn't second-guess the scope, only the schema + downstream-sync coverage + governance-gate coverage.
- **Do NOT auto-elevate Major → Blocker for fence-triggering changes that are correctly listed.** A correctly-listed fence-trigger is dimension 3 = clean (zero findings). Only missing/wrong fence-trigger lists generate findings.
- **Severity-downsize forbidden** for: out-of-enum `Pipeline:` value, out-of-enum `Verdict:` value, missing both citation fields, missing CLAUDE.md tree impact declaration, downstream-sync gap (per anti-pattern of `idc-ripple.md`), `MINOR_AUTONOMOUS` claimed when four conditions don't hold.

### Halt conditions (`ripple`)

This mode halts under any of:

1. `target_path` missing → `BLOCKED — target_path missing`
2. `scratch_dir` missing → `BLOCKED — scratch_dir missing`
3. `evidence_dir/impact-classifier.md` missing → `BLOCKED — impact-classifier evidence missing`. The `idc:idc-skill-ripple-verdict` 4-tuple is the source for dimensions 1, 2, 3, 4.
4. Brief is empty → `BLOCKED — brief missing or empty`.

---

## Cross-references

- WD-2 base: `idc:idc-skill-plan-review-base/SKILL.md` (severity / confidence / autonomous mandate / report shape)
- WD-1 sibling: `idc:idc-skill-plan-adversarial-review/SKILL.md` (paired adversarial pass)
- Source ADAPT: the operator-personal `code-review-custom` skill (never migrated; not shipped with this plugin — severity ladder + confidence floor + autonomous mandate originate there; 13 code-shaped dimensions are dropped here)
- Findings-union consumer: the orchestrator inline (substrate: `idc:idc-skill-plan-patch-from-findings`) → WD-3 `idc:idc-skill-plan-patch-from-findings/`
- Source authorities (per mode): `${CLAUDE_PLUGIN_ROOT}/agents/idc-plan.md` (modes `admission`, `subphase`, `pillar`); `${CLAUDE_PLUGIN_ROOT}/agents/idc-sequence.md` (mode `tracker`); `${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md` (mode `ripple`)
- Per-mode related skills:
  - `admission`: ES-1 `idc:idc-skill-canonical-doc-authoring`, ES-2 `idc:idc-skill-canonical-admission-audit` (mode-routed: `verdict | anti-pattern-lint | audit-write` — the latter two folded from the former ES-5 `engineer-anti-pattern-check` and ES-4 `engineering-admission-audit-write` per Phase 2D PR-7).
  - `subphase`: DS-1 `idc:idc-skill-governance-trace-audit`, DS-2 `idc:idc-skill-prior-art-pattern-read`, DS-3 `idc:idc-skill-rough-pillars-section`.
  - `pillar`: KS-1 `idc:idc-skill-subphase-ingestion`, KS-2 `idc:idc-skill-pillar-clash-analysis`, KS-3 `idc:idc-skill-sibling-pillar-precedent-review`, KS-4 `idc:idc-skill-pillar-plan-shape`, KS-5 `idc:idc-skill-ripple-trigger-precheck`, WM-1 `idc:idc-skill-pillar-resource-ownership`, WM-2 `idc:idc-skill-clash-evidence`.
  - `tracker`: QS-1 active `idc:idc-skill-github-tracker-implementation` (GraphQL); QS-1 fallback `idc:idc-skill-filesystem-tracker-implementation` (markdown); dispatch surface `idc:idc-skill-tracker-adapter`. Bootstrap fences — GraphQL: `tests/test_arch_github_tracker.py`. Findings-union consumer for tracker fix-loop is QS-1 re-emission via `idc:idc-skill-tracker-adapter`, not WD-3 (Tracker edits are not patched via WD-3; they are re-emitted by QS-1).
  - `ripple`: RS-1 `idc:idc-skill-drift-evidence`, RS-2/3 (now folded) `idc:idc-skill-ripple-verdict`, RS-4 `idc:idc-skill-change-order-shape`. Schema fences: `tests/test_arch_governance_pipeline.py`, `tests/test_arch_idc_ripple.py::test_minor_autonomous_path_exists`, `::test_change_order_template_has_required_citation_fields`.
- Q-cross-2 alignment: `docs/workflow/audits/2026-05-07-idc-role-skill-coverage/appendices/open-questions.md`
