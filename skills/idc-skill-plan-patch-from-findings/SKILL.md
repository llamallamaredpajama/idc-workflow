---
name: idc-skill-plan-patch-from-findings
description: 'Use when applying review findings to produce a revised IDC plan-shaped draft.'
---
# idc:idc-skill-plan-patch-from-findings (WD-3)

Pure emit-only patch skill consumed by the orchestrator inline (substrate: `idc:idc-skill-plan-patch-from-findings`) (the cross-IDC fixer roleplayer agent). The fixer agent computes the union of Blocker/Major findings from WD-1's adversarial-review report + the WD-2 specialization's report (canonical-doc-review / plan-custom-review / pillar-plan-review / correctness-review — Sequence's tracker-edit-review-pass routes through QR-4, NOT through this skill), then dispatches this skill with the union as input. This skill applies the findings to the current draft and writes the patched output. **No decision logic** — if a finding is in the union it gets applied; the fixer agent already decided what's in the union.

## Input contract

| Field | Shape |
|-------|-------|
| `current_draft_path` | absolute path to the current draft (e.g. `<scratch_dir>/draft-subphase.md` or `<scratch_dir>/draft-subphase-v2.md` on second-loop iterations) |
| `findings_union_json` | absolute path to a JSON file containing the union of findings from WD-1 + WD-2 specialization. See "findings_union_json schema" below |
| `target_versioned_output_path` | absolute path for the patched draft (e.g. `<scratch_dir>/draft-subphase-v3.md`). Caller chooses the version suffix; this skill writes verbatim to that path. |
| `brief_path` | optional 5–30 line brief naming any cross-finding context the fixer wants the patch logic to honor (e.g. "preserve trace declarations verbatim") |

### findings_union_json schema

The findings_union_json file MUST be a JSON object with this shape (CR-2 produces it):

```json
{
  "ordering": "blockers_first",
  "findings": [
    {
      "id": "<stable-finding-id-from-source-report>",
      "source": "wd-1" | "wd-2-canonical-doc-review" | "wd-2-plan-custom-review" | "wd-2-pillar-plan-review" | "wd-2-correctness-review",
      "severity": "Blocker" | "Major",
      "dimension": "<dimension-name>",
      "location": "<file>:<line>" | "<file>:<H1-heading>",
      "what": "<verbatim from source report>",
      "suggested_fix": "<verbatim from source report>"
    },
    ...
  ]
}
```

**Minor / Nit findings MUST NOT appear in the union.** CR-2 is responsible for filtering — those go to operator-todos per the don't-stop-the-train rule (file small findings as side jobs and keep the run moving; never halt a healthy run for Minor/Nit work). If the JSON contains a Minor or Nit, halt with `BLOCKED — minor/nit in union (caller responsibility)`.

## Procedure

1. **Read** `current_draft_path` end-to-end.
2. **Read** `findings_union_json`. Validate JSON shape (every entry has all required fields; severity ∈ {Blocker, Major}).
3. **Validate** `target_versioned_output_path`:
   - Path is under the same scratch directory as `current_draft_path` (same parent).
   - Filename has a version suffix matching pattern `<basename>-v<N>.md` where `N` is an integer.
   - Path does not exist on disk yet (overwriting an existing version is forbidden — CR-2 must increment).
4. **For each finding in `findings.ordering == "blockers_first"` order**:
   - Locate the target span in the current draft using the `location` field (line number, or H1 heading).
   - Apply the `suggested_fix` as a localized edit to the span. Preserve all unaffected text byte-for-byte.
   - **Do NOT widen scope** — never edit text outside the `location` span unless the `suggested_fix` explicitly names another span (in which case both spans are touched as a single atomic edit).
   - **Do NOT re-author canonical declarations** — `Upstream Master Plan Domain/Phase`, `Upstream Subphase`, `§Rough Pillars Source`, `Pipeline:`, `Verdict:` are preserved verbatim unless the finding's `dimension` is the trace-declaration itself (in which case the finding's `suggested_fix` carries the corrected verbatim text).
5. **Write** the patched draft to `target_versioned_output_path` once all findings are applied. Use `Write` tool — single atomic write, no intermediate states.
6. **Compute the 1-line digest**:
   ```
   patched: <target_versioned_output_path> · <K> findings applied (<B> Blockers, <M> Majors)
   ```
7. **Return** the digest to caller. Do not inline the patched draft body in the return value — caller reads it from disk.

## Output contract

- The patched draft at `target_versioned_output_path` is the only file written.
- The 1-line digest is the only return value.
- This skill does NOT write to canonical paths (`docs/plans/`, `docs/specs/`, `docs/prd/`, `docs/considerations/`, `docs/workflow/ripple/`, `docs/workflow/pillar-conflicts/`, the tracker substrate — `docs/workflow/tracker-config.yaml` plus the configured backend (GitHub Projects or the filesystem `TRACKER.md`), source files, test files, any CLAUDE.md). Caller's Phase 4 staging step does that.

## Halt conditions

This skill halts (returns halt-string, writes nothing) under any of:

1. `current_draft_path` missing → `BLOCKED — current_draft_path missing`
2. `findings_union_json` missing OR malformed JSON → `BLOCKED — findings_union_json invalid: <reason>`
3. Findings union contains Minor or Nit severity → `BLOCKED — minor/nit in union (caller responsibility)`
4. `target_versioned_output_path` already exists on disk → `BLOCKED — target_versioned_output_path exists (increment version)`
5. `target_versioned_output_path` parent directory mismatches `current_draft_path` parent → `BLOCKED — target path not in scratch dir`
6. A finding's `location` cannot be resolved in the current draft (line number out of range, H1 heading absent) → `BLOCKED — finding <id>: location unresolved`
7. A finding's `suggested_fix` would alter a verbatim trace declaration AND the finding's `dimension` is NOT the trace-declaration itself → `BLOCKED — finding <id>: would alter protected declaration`

On halt, this skill does NOT write to `target_versioned_output_path`. Caller decides whether to fix the finding union and re-dispatch, or escalate.

## Banlist

- **Do NOT decide which findings to apply.** Caller's findings-union logic already decided. If a finding is in the JSON, apply it.
- **Do NOT widen scope of any individual fix.** Localized edit per the `location` field; preserve everything else byte-for-byte.
- **Do NOT re-author trace declarations or fence-pinned fields.** `Upstream Master Plan Domain/Phase`, `Upstream Subphase`, `§Rough Pillars Source`, `Pipeline:`, `Verdict:`, `Master Plan Section:`, `Affected Role/Skill Authority:` are preserved verbatim unless the finding explicitly carries the corrected verbatim text.
- **Do NOT write to canonical paths.** Scratch-only — caller's Phase 4 stages from scratch.
- **Do NOT chain multiple findings into a "rewrite this section" mega-edit.** One finding = one localized edit. Larger edits indicate the finding-union itself was wrong-shaped; halt instead.
- **Do NOT inline the patched draft in the return value.** Caller reads from disk; the digest is the only return.

## Codex parity note

This skill IS findings-union-shape-agnostic w.r.t. runtime — Claude vs Codex callers produce the same `findings_union_json`, this skill applies edits with whatever Edit/Write primitive the runtime exposes. Codex callers invoke via inline-read of this SKILL.md (per architecture.md §Cross-runtime substrate model Option 2 short-term).

## Cross-references

- WD-1 source: `idc:idc-skill-plan-adversarial-review/SKILL.md` (one half of findings-union input)
- WD-2 base + 5 specializations: `idc:idc-skill-plan-review-base/`, `idc:idc-skill-plan-review/`, `idc:idc-skill-plan-review/`, `idc:idc-skill-plan-review/`, `idc:idc-skill-plan-review/` (other half of findings-union input)
- Caller (single agent): CR-2 the orchestrator inline (PR-5 fold; substrate: `idc:idc-skill-plan-patch-from-findings`) (4 callers via mode parameter: Engineer admission-fixer, Develop subphase-plan-fixer, Deconflict pillar-plan-fixer, Ripple change-order-fixer)
- NOT applicable to: Sequence tracker-edit fixes (route through the orchestrator inline (substrate: `idc:idc-skill-filesystem-tracker-implementation` or `idc:idc-skill-github-tracker-implementation` via `idc:idc-skill-tracker-adapter`) instead — TRACKER edits are re-emitted by QS-1, not patched)
- Source ADAPT inspiration: `superpowers:receiving-code-review` posture for findings-handling (verify before implement) — but WD-3 itself is pure emit-no-decision because the verify step happened in CR-2
