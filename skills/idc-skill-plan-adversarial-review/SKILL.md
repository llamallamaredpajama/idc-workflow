---
name: idc-skill-plan-adversarial-review
description: Run an adversarial Codex review against an IDC plan-shaped artifact (admission packet, subphase plan, pillar plan, change order) and emit IDC-bucketed findings to a scratch path. Wraps `/codex:adversarial-review`. Single-process — input (target_path, scratch_dir) → output adversarial-review report at canonical scratch path with severity ladder mapped to IDC vocabulary. Use when an IDC role (Engineer / Develop / Deconflict / Ripple) reaches its Phase 3 review step and needs a Codex-side challenge pass over the in-flight scratch draft.
---

# idc:idc-skill-plan-adversarial-review

Single-process wrapper around the existing `/codex:adversarial-review` slash command, scoped to **plan-shaped IDC artifacts** (PRD/spec/master-plan diff, subphase plan, pillar plan, change order, considerations packet) — not source code. Emits a fixed-shape adversarial-review report at a caller-supplied scratch path with findings bucketed in **IDC severity vocabulary** (Blocker / Major / Minor / Nit) so the caller's findings-union logic and fix-loop can consume both this skill's output and the WD-2 specialization's output without translation.

Wave-1 substrate skill consumed by Engineer (Phase 3 codex-admission-adversarial-reviewer), Develop (Phase 3 codex-plan-adversarial-reviewer), Deconflict (Phase 3 codex-pillar-adversarial-reviewer), and Ripple (Phase 3 codex-ripple-adversarial-reviewer). Build's BR-4 phase-close adversarial reviewer invokes `/codex:adversarial-review` directly at phase-delta scope — NOT via this wrapper — because phase-delta scope is code-shaped, not plan-shaped.

## Input contract

Caller MUST supply, on disk, before invocation:

| Field | Shape | Example |
|-------|-------|---------|
| `target_path` | absolute path to the artifact under review (single file OR a directory of related drafts) | `/tmp/idc-develop/<run-id>/draft-subphase.md` |
| `scratch_dir` | absolute path to the role's per-run scratch directory; this skill writes its report INSIDE this directory | `/tmp/idc-develop/<run-id>/` |
| `report_filename` | basename of the report file inside `scratch_dir` | `codex-plan-review.md` |
| `role` | the calling IDC role (one of `engineer | develop | deconflict | ripple`) — used in report header and to route the focus framing | `develop` |
| `brief_path` | absolute path to a 5–30 line brief that names: artifact kind, what authority surface it edits, what specific assumptions to challenge | `/tmp/idc-develop/<run-id>/briefs/codex-plan-adversarial-reviewer-1.md` |

If `target_path` does not exist on disk, halt with `BLOCKED — target_path missing` and write nothing.

If `scratch_dir` does not exist on disk, halt with `BLOCKED — scratch_dir missing`. Do not create the directory yourself; the caller's bootstrap teammate owns scratch-dir creation per `idc:idc-skill-planning-substrate` (CS-3).

## Procedure

1. **Read the brief.** Open `brief_path` and absorb the artifact-kind framing + the specific assumptions the caller wants challenged. Do NOT read the canonical doc bodies it cites; read only what the brief contains.
2. **Resolve scope** for the Codex review. For a single-file `target_path`, pass the file path directly to Codex via `--scope working-tree` against a worktree containing only that draft. For a directory `target_path` (multi-pillar Deconflict run), enumerate the draft files inside and review them in sequence; concatenate findings.
3. **Run the wrapped command** via Bash:

   ```bash
   /codex:adversarial-review --wait <focus-text>
   ```

   The `<focus-text>` is the concatenation of:
   - the artifact kind (e.g. `IDC subphase plan with §Rough Pillars contract`)
   - the authority-boundary line (e.g. `must not edit PRD/spec/master-plan/pillar/TRACKER`)
   - up to 3 challenge assumptions from the brief (e.g. `RFD §Phase boundary kept; auto-advance frontmatter contract honored; trace-back declarations verbatim`)

   Use `--wait` not `--background` — this skill is single-process and the caller is awaiting the report. Caller decides background vs wait at orchestrator level if needed.
4. **Capture Codex output verbatim.** The slash command returns a JSON payload with findings. Do not paraphrase, summarize, or omit any finding from the raw payload.
5. **Map Codex severities to IDC severity vocabulary.** This is the load-bearing step that aligns this skill's output with WD-2 specialization output for findings-union (per Q-cross-2). Mapping is verbatim:

   | Codex severity | IDC bucket |
   |----------------|-----------|
   | `critical` | **Blocker** |
   | `high` | **Major** |
   | `medium` | **Minor** |
   | `low` | **Nit** |

   **Do NOT downsize a finding to escape a halt.** The caller's fix-loop pivots on Blocker/Major (auto-fix) vs Minor/Nit (file to operator-todos). Severity-downsizing inverts that gate and is forbidden.
6. **Write the report** to `<scratch_dir>/<report_filename>` in the shape below. Caller reads only this file; the raw `/codex:adversarial-review` stdout is NOT what the caller consumes.
7. **Return** a 1-line confirmation to the caller of the form `report written: <abs path>` plus severity counts (`X Blockers · Y Majors · Z Minors · W Nits`). Caller's findings-union logic reads the report file off disk; this skill does not pass findings inline.

## Output contract — report shape

The report at `<scratch_dir>/<report_filename>` MUST conform to this exact shape (caller's findings-union logic depends on the column order + severity bucket names):

```markdown
# IDC Plan Adversarial Review — <role> — <YYYY-MM-DD-HHMM>

**Target:** `<target_path>`
**Brief:** `<brief_path>`
**Codex command:** `/codex:adversarial-review --wait <focus-text-as-passed>`
**Severity counts:** X Blockers · Y Majors · Z Minors · W Nits

---

## Blockers
<one section per finding, or "None.">

### <short title>
- **Location:** `<file>:<line>` or `<file>` if line N/A for prose targets
- **Codex severity (raw):** critical
- **IDC bucket:** Blocker
- **Challenge:** <verbatim Codex challenge text>
- **Why it matters:** <Codex impact text>
- **Suggested resolution:** <Codex suggested fix>

## Major
<same structure; Codex severity = high>

## Minor
<same structure; Codex severity = medium>

## Nit
<same structure; Codex severity = low>

---

## Raw Codex output

<verbatim stdout of /codex:adversarial-review — do not edit>
```

The "Raw Codex output" section is required so the caller's auditor can verify the IDC bucketing was applied correctly without re-running Codex.

## Halt conditions

This skill halts (writes a halt-stub at `<scratch_dir>/<report_filename>` describing the halt reason, returns the halt string to caller) under any of:

1. `target_path` missing on disk (no report written; halt string `BLOCKED — target_path missing`).
2. `scratch_dir` missing on disk (no report written; halt string `BLOCKED — scratch_dir missing`).
3. `brief_path` missing on disk OR empty (write halt-stub; halt string `BLOCKED — brief missing or empty`). Reviewing without a brief is a context-discipline violation — the caller is supposed to specify what to challenge.
4. `/codex:adversarial-review` returns a non-zero exit code OR malformed JSON (write halt-stub with the raw stderr; halt string `BLOCKED — codex command failed: <stderr summary>`). Do NOT attempt to recover or re-run; the caller decides whether to retry.
5. Codex emits a finding with a severity outside `{critical, high, medium, low}` (write halt-stub citing the unrecognized severity; halt string `BLOCKED — unrecognized codex severity: <value>`). Do NOT invent a mapping.

This skill never auto-fixes findings, never edits the target artifact, never edits canonical docs. It is read+invoke-only against the artifact, write-only to the scratch report file.

## Banlist

- **Do NOT translate Codex findings into your own words.** Caller's audit needs Codex's verbatim challenge text. Paraphrasing erases the adversarial framing.
- **Do NOT downsize a finding to escape a halt.** Severity mapping is verbatim per Q-cross-2.
- **Do NOT include a finding in any bucket without a Codex severity.** If Codex omits the severity field, halt per condition 5; do not guess.
- **Do NOT invoke `/codex:review`.** This skill is the adversarial variant only. Plain `/codex:review` is a different command with different framing — caller wants the adversarial pass.
- **Do NOT write outside `<scratch_dir>/<report_filename>`.** No edits to the target draft, no edits to canonical docs, no edits to TRACKER, no commits.
- **Do NOT inline-paste the Codex output back to the caller.** Caller reads the report off disk per the orchestrator-context-discipline pattern.

## Codex parity note

This skill IS the IDC-side adoption of `/codex:adversarial-review`. The `/codex:adversarial-review` command itself is provided by the `openai-codex` plugin and is REUSE-only — never edit it. This wrapper adds:

- Input contract (caller-supplied paths instead of cwd-inferred scope) so the same skill works from any IDC role's scratch dir.
- IDC severity vocabulary (Blocker/Major/Minor/Nit) instead of Codex's critical/high/medium/low so findings-union logic with WD-2 specializations is direct.
- Plan-shape framing in the focus text so Codex's challenge is targeted at admission/decomposition/clash assumptions, not at code defects.
- Halt taxonomy that the caller's halt-reason enum can ingest.

For Codex-runtime parity (the Codex-runtime sibling adapters consuming the same wrapper), see `docs/workflow/audits/2026-05-07-idc-role-skill-coverage/architecture.md §Cross-runtime substrate model` and `appendices/codex-drift-ripple.md`.

## Cross-references

- Q-cross-2 (severity alignment) in `docs/workflow/audits/2026-05-07-idc-role-skill-coverage/appendices/open-questions.md`
- WD-2 base + 5 specializations: `idc:idc-skill-plan-review-base/`, `idc:idc-skill-plan-review/`, `idc:idc-skill-plan-review/`, `idc:idc-skill-plan-review/`, `idc:idc-skill-plan-review/`, `idc:idc-skill-plan-review/`
- WD-3 patch skill (consumes findings union): `idc:idc-skill-plan-patch-from-findings/`
- the orchestrator inline (substrate: `idc:idc-skill-plan-patch-from-findings`) is the agent that chains WD-1 + WD-2 specialization output into a findings-union and dispatches WD-3
- Build's BR-4 phase-close adversarial reviewer invokes `/codex:adversarial-review` directly (phase-delta scope, code-shaped) — distinct path
