---
name: idc-skill-plan-review-base
description: Base substrate for IDC plan-shaped review skills — defines the severity ladder (Blocker / Major / Minor / Nit), confidence-≥-80 floor, 91+→Blocker mapping, mandatory-disk-output contract, autonomous-execution mandate, and report shape that every WD-2 specialization (canonical-doc-review, plan-custom-review, pillar-plan-review, tracker-edit-review-pass, correctness-review) inherits. NOT invoked directly — specializations cite + summarize the rules below and fill in their per-role dimension list. Use when authoring or maintaining a WD-2 specialization, OR when an external caller needs to verify the shared severity / confidence / output contract.
---

# idc:idc-skill-plan-review-base

Shared substrate for the WD-2 family of plan-shaped review skills. The 13 code-shaped dimensions from `code-review-custom` do NOT apply to plan documents — that dimension list is replaced by each specialization's per-role dimension list. Everything else (severity ladder, confidence floor, autonomous-execution mandate, mandatory-disk-output, report shape) is inherited verbatim and is fenced as load-bearing.

This base is **not invoked directly by the caller orchestrator** — invocation goes through one of the 5 specializations:

| Specialization | Caller role | Dimension count |
|----------------|-------------|-----------------|
| `idc:idc-skill-plan-review` | Engineer | 8 admission-shape |
| `idc:idc-skill-plan-review` | Develop | 10 plan-shape |
| `idc:idc-skill-plan-review` | Deconflict | 8 pillar-shape |
| `idc:idc-skill-plan-review` | Sequence | 4 tracker-shape |
| `idc:idc-skill-plan-review` | Ripple | 5 ripple-shape |

Each specialization cites this base by name in its body AND restates the load-bearing rules inline (per the self-contained-roleplayer rule — Codex inline-read of the substrate may not be transitive across symlink shims).

## Autonomous Execution Mandate (load-bearing — inherited verbatim)

These rules override any default review posture. Every WD-2 specialization MUST honor them.

1. **Run all reads via the Bash / Read tool yourself.** Never ask the caller to paste content back. Never instruct the caller to "open the draft and tell me what it says."
2. **Never ask for permission to read scratch artifacts.** Reading `<scratch_dir>/<draft>.md`, `<scratch_dir>/codex-plan-review.md`, and any other in-flight scratch files is always safe and immediate.
3. **Never block on missing optional inputs.** If a related scratch artifact is absent (e.g. `governance-trace-audit.md` for Develop), proceed with the available evidence and tag the affected dimension `unverified` rather than halting.
4. **Proceed autonomously through all dimensions.** Do not pause for caller input mid-review. The caller's findings-union logic in the orchestrator inline (substrate: `idc:idc-skill-plan-patch-from-findings`) consumes the report once written.
5. **If a tool is unavailable**, write a halt-stub at the canonical report path describing what would have been checked, then return.

## Confidence → Severity Bucket Mapping (inherited verbatim — fence-critical)

Every finding carries a 0–100 confidence score. Apply this mapping without exception:

| Confidence | Severity Bucket | When to use |
|------------|-----------------|-------------|
| 91–100 | **Blocker** | Explicit canonical-chain violation, missing required trace, severity-fence breach, governance-gate breach, scope origination |
| 80–90 | **Major** or **Minor** | High-likelihood concern with specific evidence; **Major** if it blocks admission/landing OR breaks the canonical chain, **Minor** if it affects quality / coverage / readability |
| < 80 | **Excluded — drop entirely** | Do not include in any bucket. Do not mention in the report. |

Rationale: false positives in plan review waste fixer-loop iterations that count against the 3-loop ceiling. The < 80 floor protects the loop.

**Severity-downsizing is forbidden** — never demote Blocker → Major to escape a halt. The caller's fix-loop pivots on Blocker/Major (auto-fix) vs Minor/Nit (file to operator-todos). Inversion of that gate is a banlist item in every WD-2 specialization.

## Mandatory Outputs (inherited verbatim)

Every WD-2 specialization invocation MUST produce ALL of these:

| # | What | Where |
|---|------|-------|
| 1 | **Scope announcement** before any dimension analysis: `Reviewing: <target_path> (<role> mode, <N> dimensions)` | Inline-to-caller (1 line only) |
| 2 | **Report file written to disk** at `<scratch_dir>/<report_filename>` (defaulted by caller — NOT chosen by skill). Never only inline text. | Disk file |
| 3 | **Exactly four severity buckets** in the report — named precisely: `Blocker`, `Major`, `Minor`, `Nit`. No other names. | Report file |
| 4 | **Dimension coverage table** — all `<N>` rows (where `<N>` is the specialization's dimension count), each with finding count and one-line status. **Table appears at the top of the report, immediately after the summary header — before any finding sections.** | Report file |
| 5 | **Inline summary after writing report** — full absolute file path to the written report, severity counts (`X Blockers · Y Major · Z Minor · W Nit`). NEVER reproduce findings inline. | Inline-to-caller |

## Report shape (inherited verbatim — specializations fill in the dimension table only)

```markdown
# IDC Plan Review — <role> — <YYYY-MM-DD-HHMM>

**Target:** `<target_path>`
**Brief:** `<brief_path>`
**Specialization:** `<specialization-slug>`
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

## What this base does NOT do (inherited verbatim)

Hard constraints — every WD-2 specialization inherits these:

- **No edits to the target draft.** Plan review is read-only; fixes happen via WD-3 `idc:idc-skill-plan-patch-from-findings` invoked by CR-2.
- **No edits to canonical docs.** Plan review NEVER touches PRD, master architectural spec, master implementation plan, subphase plans, pillar plans, or TRACKER.
- **No `/codex:adversarial-review` invocation.** That's WD-1's job; WD-2 specializations are the IDC-side custom-plan-reviewer half of the pair.
- **No `simplify` invocation.** WD-2 specializations are plan-shaped, not code-shaped — there is no Step 1.5 polish pass.
- **No test runs.** Plans don't run; specs/contracts validate via `tests/test_arch_*.py` fences which are flagged-as-obligation, not exercised by the reviewer.
- **No repro scripts.** Plan review is static; flag suspicions and move on.

## Findings-union compatibility (load-bearing for CR-2)

A WD-2 specialization's report MUST be findings-union-compatible with WD-1's adversarial-review report. The fields that the union logic in CR-2 depends on:

- `Severity` ∈ {Blocker, Major, Minor, Nit} — same vocabulary as WD-1's IDC bucket
- `Location` — `<file>:<line>` or `<file>:<H1-heading>` (caller's deduplicator hashes this)
- `Confidence` — 80–100 only (anything < 80 must not appear)
- `Suggested fix` — single-shot patch hint (WD-3 reads this when generating its patch plan)

Specialization bodies MAY add per-role fields (e.g. `Affected Authority Surface`, `Trace Triple Element Missing`) but MUST NOT remove any of the four above.

## Specialization authoring rules

When authoring or maintaining a WD-2 specialization:

1. **Cite this base by skill name** at the top of the specialization body (with a 2-sentence summary of severity + confidence floor + autonomous mandate per the self-contained-roleplayer rule — do NOT use a "see base for severity ladder" pointer-only reference, because Codex inline-read may not transit symlink shims).
2. **Restate the four load-bearing rules inline:** severity ladder, confidence floor, mandatory-disk-output, autonomous-execution mandate.
3. **List your dimensions in a numbered table.** Each row: dimension name + 1-line probe question + which artifact(s) on disk are consulted (the draft? a scratch artifact? the upstream subphase / master-plan section?).
4. **Add per-role banlist items** that go beyond the base banlist (e.g. Engineer's "no scaffolded subphases inside master-plan §Phase boundary"; Sequence's "every TRACKER edit cites a plan-derived unit").
5. **Cross-reference the upstream agent file** by relative path so a future maintainer can trace dimensions back to source authority.

## Cross-references

- WD-1 sibling: `idc:idc-skill-plan-adversarial-review/` (adversarial pair; severity-mapped to the same vocabulary)
- WD-3 consumer: `idc:idc-skill-plan-patch-from-findings/` (reads this report's findings + WD-1's findings as union input)
- CR-2 orchestrator: the orchestrator inline (PR-5 fold; substrate: `idc:idc-skill-plan-patch-from-findings`) (chains WD-1 + WD-2 specialization → findings-union → WD-3)
- Source ADAPT: the operator-personal `code-review-custom` skill (never migrated; not shipped with this plugin — severity ladder + confidence floor + autonomous mandate originate there; 13 code-shaped dimensions are dropped here)
- Q-cross-2 alignment: `docs/workflow/audits/2026-05-07-idc-role-skill-coverage/appendices/open-questions.md`
