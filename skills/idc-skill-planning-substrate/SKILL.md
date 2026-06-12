---
name: idc-skill-planning-substrate
description: 'Use when an IDC orchestrator needs context curation, spawn discipline, or gate enforcement support.'
---
# IDC Skill — Planning Substrate (`idc:idc-skill-planning-substrate`)

CUSTOM. Mode-routed substrate for IDC orchestrators. Folds three previously-separate substrate skills (CR-1 codebase-context-curator, CS-3 orchestrator-context-discipline, CS-5 canonical-gate-enforcement) behind one entry point. The three sub-modes share the same callsite shape (parameter packet → return packet + optional scratch artifact) but cover orthogonal concerns — context curation, spawn discipline, and gate enforcement — so the orchestrator selects the relevant sub-mode per call.

## Mode router

Caller passes `mode` exactly once per call. Modes:

- **`curate-slice`** — per-slice canonical context packet emit (formerly CR-1 `codebase-context-curator`).
- **`discipline-spawn`** — brief-on-disk + thin-prompt + anti-absorption + operator-is-lead spawn-discipline guardrail (formerly CS-3 `orchestrator-context-discipline`).
- **`enforce-gate`** — per-mode canonical-doc gate decision + boundary-language emit (formerly CS-5 `canonical-gate-enforcement`).

Each mode is independently invocable. No call combines modes — the orchestrator runs `discipline-spawn` before each spawn, `curate-slice` from inside a slice subagent, `enforce-gate` at every gate boundary.

---

## Mode 1 — `curate-slice` (per-slice canonical context packet emit)

Per-slice canonical packet section emit. The orchestrator inline (substrate: `idc:idc-skill-planning-substrate` mode=`curate-slice`) partitions a scoping request into 4–8 source-class slices and dispatches one read-only Task subagent per slice. Each subagent invokes this skill once with its slice — the skill validates the per-slice schema and emits the canonical packet section so the orchestrator's assembled packet across slices is shape-coherent. The packet shape is shared across IDC roles (Plan codebase-context-master input; Build pre-implementation read input), enabling consistent orchestrator-side consumption.

### When to invoke (`curate-slice`)

Inside a Task subagent dispatched by the orchestrator's per-slice loop. One invocation per slice. The orchestrator caps at 8 slices; the skill processes exactly one.

### Input shape (`curate-slice`)

Caller passes a single packet with:

- `mode: curate-slice`
- `slice_kind` — exactly one of:
  - `tracker-canonical-anchors` — TRACKER + named PRD/spec/master-plan sections + root + per-directory CLAUDE.md.
  - `active-plans` — subphase plan + pillar plan named for the parent role's run.
  - `considerations` — files under `docs/considerations/` referenced by the brief.
  - `sibling-plans` — other subphase/pillar plans for the same domain.
  - `live-code-tests` — code surfaces / `tests/test_arch_*.py` fences relevant to the scope.
  - `recent-ripple-orders` — `docs/workflow/ripple/<slug>-ripple.md` touching the named scope.
  - `recent-role-audits` — `docs/workflow/audits/*-run-audit.md` for upstream roles in the same chain.
  - `operator-todos` — `docs/workflow/operator-todos/<tag>.md` BLOCKING items relevant to scope.
- `slice_inputs[]` — list of file paths the slice covers (parent orchestrator partitions; this skill respects).
- `parent_role` — exactly one of `plan | build`. Selects per-role evidence-shape emphasis (Plan needs admission obligations + trace-back surfaces; Build needs pillar-plan + matrix dispatch surface).
- `scratch_dir` — absolute path to the parent orchestrator's scratch dir.
- `output_path` — absolute path for the per-slice section emit (typically `<scratch_dir>/codebase-context-slice-<slice_kind>.md`).

### Output shape (`curate-slice`)

Single per-slice section written to disk plus a small return packet:

- **File** at `output_path` — the canonical-shape per-slice section.
- **Return packet:** `{output_path, anchors_emitted_count, dedup_keys[], slice_kind}`.

#### Per-slice canonical section shape

Each slice emits a markdown section with consistent shape so the assembled packet has 4–8 stacked sections, all coherent:

```yaml
---
section_kind: codebase-context-slice
slice_kind: <slice_kind>
parent_role: <enum>
inputs_count: <N>
anchors_emitted: <N>
---

# Slice — <slice_kind> — for <parent_role>

## Section purpose

(One-line: what this slice contributes to the assembled packet.)

## Per-input anchors

| # | File | Anchor (line range / heading) | 1–3-sentence summary | Verbatim quote (fence-pinned content only) | Dedup key |
|---|------|--------------------------------|----------------------|---------------------------------------------|-----------|
| 1 | `<abs path>` | `:42-58` or `§Architectural Fitness` | <summary> | <verbatim quote, ≤4 lines, only for fence-pinned text> | `<file>:<line-range>` |
| ... |

## Cross-slice references

(Bullet list of anchors in this slice that other slices likely cover too — feeds the orchestrator's deduplication pass.)

## Slice-level notes

(For `plan`: any admission-obligation hints or trace-back surface hints. For `build`: any pillar-plan / matrix dispatch hints.)
```

### Procedure (`curate-slice`)

1. **Validate inputs:** `slice_kind` ∈ allowed enum; `parent_role` ∈ allowed enum; every path in `slice_inputs[]` exists and is readable; `scratch_dir` exists; `output_path` lands under `scratch_dir`.
2. **Read** every file in `slice_inputs[]` end-to-end.
3. **Compose §Section purpose** — one-line statement of what this slice contributes.
4. **Emit per-input anchor rows:**
   - For each input, identify the load-bearing anchor(s) — section heading or line range that's relevant to the parent role's evidence-shape needs.
   - Emit 1–3-sentence summary per anchor — never paraphrase fence-pinned content; quote verbatim.
   - **Verbatim quotes are reserved for fence-pinned content** — load-bearing rules pinned by `tests/test_arch_*.py`, canonical-doc invariants, schema fields, exact path conventions. Don't dump body content as quotes.
   - Compute `dedup_key` as `<file>:<line-range>` (or `<file>:<heading-slug>` for prose anchors). Parent orchestrator uses dedup keys to merge collisions across slices.
5. **Per-role evidence emphasis:**
   - **plan:** anchors that name PRD section IDs, master-architectural-spec section IDs, master-plan §Domain/§Phase IDs, considerations file open-questions, governance fence trigger surfaces, sibling subphase plans, RFD §Phase boundary text, pillar trace-key shape.
   - **build:** anchors that name pillar plan trace key, pillar matrix dispatch substrate (`<phase-tag>-matrix.yaml`), `tests/test_arch_pillar_matrix.py` fence, work-packet IDs, operator-todos BLOCKING items.
6. **Compose §Cross-slice references** — for any anchor likely appearing in another slice (e.g. a CLAUDE.md anchor that cross-cuts), bullet-list the implication so the orchestrator's dedup pass merges correctly.
7. **Compose §Slice-level notes** per `parent_role`.
8. **Write** the per-slice section at `output_path`.
9. **Return** the small return packet.

### Banlist (`curate-slice`)

- **No edits to source files.** Read-only — every input is read but never written. The skill writes ONE file at `output_path` and nothing else.
- **No paraphrased verbatim quotes.** When a fence-pinned rule appears in the source, the verbatim column quotes it byte-for-byte (within ≤4 lines). Paraphrase defeats the dedup contract.
- **No bulk dumping.** §Per-input anchors carries 1–3-sentence summaries + targeted verbatim quotes — NOT entire file bodies. The parent orchestrator reads the assembled packet, NOT every input file.
- **No multi-slice processing.** This mode processes ONE slice. Parent orchestrator's per-slice subagents call the skill once each.
- **No assembled-packet output.** This mode emits ONE per-slice section. The parent orchestrator (the calling roleplayer) assembles + dedupes across slices.
- **No verdict / classification logic.** This mode is read+emit. Classification (which anchors matter most, governance verdicts, admission decisions) lives in downstream skills (CS-4 `governance-verdict` (now `idc:idc-skill-ripple-verdict`, `binary_verdict_only` surface) for governance verdicts; ES-2 `idc:idc-skill-canonical-admission-audit` / ES-3 `idc:idc-skill-considerations-admissibility-review` for admission).
- **No cross-runtime divergence.** The packet shape is identical across Claude side and Codex side — `${CLAUDE_PLUGIN_ROOT}/skills/codex-idc-plan/SKILL.md` and Codex siblings inline-read the same shape so orchestrator-side consumption is byte-compatible.

---

## Mode 2 — `discipline-spawn` (orchestrator brief-on-disk + thin-prompt + anti-absorption + operator-is-lead)

Closest substrate neighbor is `superpowers:dispatching-parallel-agents`, but that operates at task-dispatch granularity — it does NOT enforce file-based-brief, ~30-line cap, do-not-absorb-bodies guard, IDC scratch-dir convention, or the operator-is-lead spawn invariant. This mode is the IDC-canonical context-discipline substrate consumed by all IDC role orchestrators before each spawn.

### When to invoke (`discipline-spawn`)

Inside any IDC role orchestrator immediately before spawning any teammate or Task subagent. Pattern:

1. Orchestrator computes the brief content for the teammate.
2. Orchestrator calls **this skill with `mode: discipline-spawn`** with the brief content + spawn metadata.
3. Skill writes the brief to disk and returns `{brief_path, thin_prompt_text}`.
4. Orchestrator passes `thin_prompt_text` directly to `TeamCreate` / `Agent({prompt: ...})`.

Replaces the duplicated `§A6.5` prose blocks previously inlined in each `idc-<role>.md` file.

### Input shape (`discipline-spawn`)

Caller passes a single packet with:

- `mode: discipline-spawn`
- `orchestrator_role` — exactly one of `think | plan | sequence | build | ripple`. Used to resolve the scratch-dir prefix.
- `run_id` — `<YYYY-MM-DD-HHMM-tag>`; the orchestrator's current run identifier.
- `teammate_name` — kebab-case name for the teammate (e.g. `codebase-context-curator`, `subphase-plan-writer`, `pillar-plan-reviewer-1`).
- `teammate_id` — short disambiguator within run (e.g. `1`, `2`, or a pillar-tag suffix); used to resolve the brief filename.
- `intended_subagent_type` — the `subagent_type` the orchestrator will pass to `Agent({...})`. Examples: `idc:idc-role-writer`, `idc:idc-role-fixer`, `idc:idc-role-think-investigator`. The skill validates this is NOT a forbidden intermediate-lead type (see Banlist).
- `team_name` — the cmux Claude Teams name the orchestrator is dispatching into.
- `brief_body` — the full brief markdown string the teammate will read on first turn. Anti-absorption checks run against this string before writing.
- `first_message_contract` — the literal first-message-contract sentence the teammate must satisfy on its first turn (e.g. `SendMessage me a 1-line "starting <teammate_name>" then begin reading the brief and inputs.`).
- `orchestrator_context_pct?` — optional percentage 0–100. If provided AND ≥95, the skill HALTS before writing any new brief.

### Output shape (`discipline-spawn`)

- **Brief file written** to `/tmp/idc-<orchestrator_role>/<run_id>/briefs/<teammate_name>-<teammate_id>.md`. Brief files are NOT committed (scratch). The brief body is exactly the `brief_body` string the caller passed (plus a small auto-prepended header naming the teammate, brief path, and first-message-contract line — for self-locating).
- **Return packet:** `{brief_path, thin_prompt_text, line_count}` where `thin_prompt_text` is a ≤30-line string ready to pass as the `prompt` argument to `TeamCreate`/`Agent`.

#### Thin prompt template (the ~30-line cap)

The returned `thin_prompt_text` follows this template verbatim and MUST stay ≤30 lines. The skill refuses to emit a longer prompt — that's the cap's whole point.

```
You are <teammate_name> on team <team_name>.

Read your full brief at:
<absolute brief_path>

The brief contains your mission, inputs to read, output expectations,
authority boundary, banlist, and first-message contract.

First action: <first_message_contract>

Stay alive after completing your mission until you receive a shutdown_request from the orchestrator.
```

### Anti-absorption guard (load-bearing)

Before writing the brief file, the skill scans `brief_body` for these red flags and HALTS the orchestrator with a guidance message if any are detected (a halt is the right outcome — the orchestrator should re-route through a curator role rather than self-absorb):

- **Pasted plan body.** `brief_body` contains `## Pillar`/`## Wave`/`## Phase` H2 sections that look like a verbatim copy of a `docs/plans/` file (heuristic: ≥40 lines, ≥2 H2 sections, contains either a `Tracker Trace Key` or `Upstream Subphase` line). The orchestrator should pass a brief path / pillar trace key, not the body.
- **Pasted canonical-doc body.** `brief_body` contains a verbatim H1 from PRD / master architectural spec / master implementation plan, OR a `firestore.rules` literal block, OR ≥30 lines of source code (heuristic: triple-fenced code block ≥30 lines). The orchestrator should pass file paths and let the orchestrator inline (substrate: `idc:idc-skill-planning-substrate` mode=`curate-slice`) absorb canonical-doc bodies.
- **Brief exceeds 12 KB.** Briefs above 12 KB are a smell that the orchestrator is doing curator work itself. Halt and route through `mode: curate-slice` instead.

When the guard halts, the skill returns `{halt_reason: "absorption_red_flag", detected_pattern: "...", recommended_route: "run codebase-context-curator step inline (substrate: `idc:idc-skill-planning-substrate` mode=`curate-slice`); pass its returned digest pointer to the next teammate"}` so the orchestrator can recover cleanly.

### Context-full halt

If `orchestrator_context_pct` is provided AND ≥95, the skill HALTS the orchestrator before writing any new brief — at that utilization a new spawn is not safe (the orchestrator would have insufficient remaining budget for the SendMessage cycle). The right move is `/sum` or `/handoff` and resume in a fresh session. Returns `{halt_reason: "context_full", recommended_route: "drop role-run-audit + handoff; resume in fresh orchestrator session"}`.

### Operator-is-lead spawn invariant

The skill's `intended_subagent_type` validation REJECTS any subagent_type matching:

- Names suggesting an intermediate lead: `team-lead-*`, `*-lead-*`, `coordinator-*`, `meta-*`, anything that, by convention, could be expected to spawn further teammates of its own.
- Reasoning: per the IDC team-spawn constraint, agent teammates can spawn Task subagents (read-only single-shot) but CANNOT spawn other team-joining agents — the spawn falls back silently to a Task subagent and bypasses the writer-isolation guarantee. The operator (orchestrator session) MUST spawn ALL writer teammates directly.

Returns `{halt_reason: "intermediate_lead_invalid", recommended_route: "have the orchestrator (operator session) spawn the actual writer teammates directly via Agent({team_name})"}`.

### Banlist (`discipline-spawn`)

- **Pasting plan, canonical-doc, or source-code bodies into prompt arguments.** The brief lives in a file; the prompt points at the file. A 200-line inline prompt costs 200 lines of orchestrator context per spawn — across three writers + retry on a TeamCreate-not-found error that's 1200 lines of brief text. Forbidden.
- **Long inline `TeamCreate` prompts.** Cap is 30 lines for the prompt itself. The skill enforces this on output.
- **Pushing through context-full.** When `orchestrator_context_pct >= 95`, halt — never spawn.
- **Spawning intermediate "lead" between orchestrator and writer.** Operator IS the lead (per the IDC team-spawn constraint). Names like `team-lead-N`, `coordinator-*`, `meta-orchestrator-*` are rejected.
- **Absorbing canonical-doc bodies into the orchestrator's context.** Curators (`mode: curate-slice` of this skill, ES-3 `idc:idc-skill-considerations-admissibility-review`) do that work — orchestrator dispatches and consumes one-line digests + disk pointers.
- **Re-pasting the brief on retry.** When a TeamCreate-not-found / spawn error occurs, edit the brief file in place and respawn with the SAME thin prompt; do NOT re-emit a long brief inline.
- **Writing briefs anywhere except `/tmp/idc-<role>/<run_id>/briefs/`.** Path discipline keeps scratch confined to the run.

---

## Mode 3 — `enforce-gate` (per-mode canonical-doc gate decision + boundary-language emit)

Each gate-checkable callsite previously repeated the gate rule inline (drift-prone). The Engineer Gate, Build's pre-merge gate, and Ripple's `GATED`/`MAJOR_GATED` operator-approval-gatekeeper share the same logic shape: a function from `(gate_mode, action, scope)` to a GO/HALT/ESCALATE decision plus boundary-language to inject into prompts. `gate_mode` parameter selects gate-enum + per-mode banlist + per-mode operator-approvals-required list.

### When to invoke (`enforce-gate`)

Inside any IDC role at every gate-checkable boundary:

- **Engineer Gate, pre-drafting** — before drafting a PRD / arch-spec / master-plan PR. Engineer Gate requires operator approval BEFORE drafting; this skill returns `decision: ESCALATE` with `operator_approvals_required: ["pre-drafting"]` so the orchestrator can surface the gate.
- **Engineer Gate, pre-merge** — after the PR is open and reviewed but before merge. Engineer Gate requires operator approval BEFORE merge for PRD or arch-spec edits; master-plan edits require pre-merge operator approval. This mode emits `decision: ESCALATE` until the operator approval is captured, then `GO`.
- **Build pre-merge gate** — the exit gate before `gh pr merge`. Combines per-PR Ripple Audit (verdict from CS-4 `governance-verdict`) with phase-close adversarial-review verdict (when applicable). If implementation diverged from the pillar OR the pillar diverged from upstream docs, return `decision: HALT` with rationale to file Ripple.
- **Ripple `GATED` and `MAJOR_GATED`** — `MAJOR_GATED` (PRD / arch-spec) requires operator approval pre-drafting AND pre-merge; `GATED` (master plan / root CLAUDE.md / docs/workflow/CLAUDE.md / governance fence) requires pre-merge gating. This mode returns the right `operator_approvals_required[]` list per Ripple verdict.
- **Build / Sequence tracker-admit** — when admitting an item to TRACKER, this mode validates the upstream pillar plan exists at `docs/plans/pillars/<...>.md` and that the trace key is present.

### Input shape (`enforce-gate`)

Caller passes a single packet with:

- `mode: enforce-gate`
- `gate_mode` — exactly one of `engineer | build | ripple | develop | deconflict | sequence | skip`. Selects the mode-specific gate-enum + banlist + operator-approvals.
- `action` — exactly one of `drafting | pre_merge | merge | tracker_admit`. Per-mode legal action set:
  - `engineer`: `drafting | pre_merge`
  - `build`: `pre_merge | merge`
  - `ripple`: `drafting | pre_merge`
  - `develop`: `pre_merge`
  - `deconflict`: `pre_merge`
  - `sequence`: `tracker_admit`
  - `skip`: any (no gate enforcement; short-circuits to GO regardless of action)
- `scope` — typically the response packet from CS-4 `governance-verdict` (i.e. `{pipeline, verdict, highest_affected_layer, arch_fitness_obligations[]}`) plus `file_paths[]` and an optional `operator_approval_captured` flag (whose value the orchestrator tracks externally).
- `ripple_verdict?` — optional. When `gate_mode == ripple`, the 4-value Ripple verdict (`NO_RIPPLE | MINOR_AUTONOMOUS | GATED | MAJOR_GATED`) from RS-2 `impact-classifier` (now `idc:idc-skill-ripple-verdict` sub-procedure 3). Drives operator-approvals-required output.

### Output shape (`enforce-gate`)

A single response packet (no file writes — read-only mode):

```yaml
decision: GO | HALT | ESCALATE
operator_approvals_required: []   # zero, one, or two entries from {"pre-drafting", "pre-merge"}
boundary_language: <multi-line string ready to inject into the orchestrator's next prompt or PR body>
rationale: <one short paragraph explaining the decision>
mode_specific_banlist: [<short list of forbiddens injectable as a banlist into spawned teammates>]
```

#### Decision values

- `GO` — the gate is satisfied; the orchestrator may proceed with `action`.
- `HALT` — the gate is unsatisfiable as posed (e.g. Build is trying to merge a PR whose CS-4 verdict was `ripple-required`); the orchestrator must file Ripple, fix the root cause, and re-run the gate.
- `ESCALATE` — the gate requires operator approval (`pre-drafting` or `pre-merge`); the orchestrator surfaces this as a load-bearing operator gate per the playbook and pauses until approval is captured. After approval, the orchestrator re-runs this skill with `operator_approval_captured: true` to receive `GO`.

### Per-`gate_mode` behavior

#### `gate_mode: skip` (no gate enforcement)

Use when the calling surface has structurally suppressed the gate — typically:
- Autorun (`/idc:autorun`) — every Plan spawn passes `gate_mode: skip` because canonical-derived content does not warrant operator gates.
- Scaffolded-plan replan (`/idc:plan <docs/plans/*.md>`) — the input is already canonical-derived; gates already fired at the originating consideration's admission.
- Phase 0 input-type detection that classifies the input as non-consideration.

Behavior: returns `decision: GO` immediately regardless of `action` or `scope`. `operator_approvals_required: []`. `boundary_language: ""` (empty — no banner to inject). `rationale: "gate_mode: skip — caller has structurally suppressed gate enforcement; no operator approval required."` `mode_specific_banlist: []`.

**Discipline:** `gate_mode: skip` is the operator-invisible no-op. The caller is responsible for verifying its input warrants suppression (consideration vs scaffolded-plan vs autorun). The skill does NOT inspect inputs — `skip` is a hard short-circuit. Mis-classification by the caller is a caller-side bug, not a substrate failure.

#### `gate_mode: engineer` (Engineer Gate)

`action: drafting`:
- If `scope.highest_affected_layer ∈ {prd, architecture-spec, master-plan}` → `decision: ESCALATE`, `operator_approvals_required: ["pre-drafting"]`. Engineer Gate is operator-approved-before-drafting.
- Else (Engineer working inside admitted master-plan section, no upstream layer touched) → `decision: GO`.

`action: pre_merge`:
- If `scope.highest_affected_layer ∈ {prd, architecture-spec}` → `decision: ESCALATE`, `operator_approvals_required: ["pre-merge"]`. Both PRD and arch-spec require pre-merge operator approval.
- If `scope.highest_affected_layer == master-plan` → `decision: ESCALATE`, `operator_approvals_required: ["pre-merge"]`. Master plan requires pre-merge.
- Else → `decision: GO`.

`boundary_language`: the literal "Engineer Gate" boundary block that must be injected into the drafting subagent's prompt and the admission-PR body, naming the layer and the approval kind.

`mode_specific_banlist`:
- Engineer never writes source code.
- Engineer never writes TRACKER sequencing.
- Engineer never writes subphase or pillar plans.
- Engineer never bypasses the pre-drafting gate by drafting first and approving later.

#### `gate_mode: build` (Build pre-merge gate)

`action: pre_merge`:
- If `scope.verdict == ripple-required` → `decision: HALT`, rationale: implementation diverged from pillar or pillar diverged from upstream docs; file Ripple before proceeding.
- Else if `scope.arch_fitness_obligations[]` is non-empty AND any fence is red → `decision: HALT`, rationale: arch fences must be green pre-merge.
- Else → `decision: GO`.

`action: merge`:
- For Build, `merge` is the actual `gh pr merge` invocation (post-gate). If the orchestrator passes `merge` here, this skill simply re-validates the `pre_merge` decision and returns it; the orchestrator should have run `pre_merge` first.

`boundary_language`: the literal "Build pre-merge gate" block, naming the per-PR Ripple Audit verdict, fences red/green, and any operator-todos BLOCKING that must be cleared before the phase-transition ritual.

`mode_specific_banlist`:
- Build never edits PRD, master architectural spec, master implementation plan, subphase plans, or pillar plans.
- Build never bypasses the per-PR review-fix-merge cycle.
- Build never `--no-verify`.
- Build never auto-merges PRD or arch-spec PRs (those are `MAJOR_GATED`, Engineer's authority).

#### `gate_mode: ripple` (Ripple `GATED` / `MAJOR_GATED`)

`action: drafting`:
- If `ripple_verdict == MAJOR_GATED` → `decision: ESCALATE`, `operator_approvals_required: ["pre-drafting"]`.
- Else → `decision: GO`.

`action: pre_merge`:
- If `ripple_verdict == MAJOR_GATED` → `decision: ESCALATE`, `operator_approvals_required: ["pre-merge"]`. (`MAJOR_GATED` requires both pre-drafting AND pre-merge.)
- If `ripple_verdict == GATED` → `decision: ESCALATE`, `operator_approvals_required: ["pre-merge"]`.
- If `ripple_verdict == MINOR_AUTONOMOUS` → `decision: GO` (auto-merge per Ripple's four-condition gate; the gate is enforced by RS-2 `impact-classifier`).
- If `ripple_verdict == NO_RIPPLE` → `decision: HALT` (no Ripple should have been opened — this is a misroute).

`boundary_language`: the literal "Ripple gate" block naming verdict + approvals + the autonomous-ledger append rule for `MINOR_AUTONOMOUS`.

`mode_specific_banlist`:
- Ripple never auto-merges PRD or arch-spec PRs (load-bearing safety — `MAJOR_GATED` is dual-gated).
- Ripple never writes source code.
- Ripple never applies direct automatic canonical edits without the required operator approvals captured.

#### `gate_mode: develop` (Develop pre-merge for subphase plan PR)

`action: pre_merge`:
- If `scope.highest_affected_layer ∈ {prd, architecture-spec, master-plan}` → `decision: HALT`, rationale: Develop never edits upstream layers; file Ripple to escalate to Engineer.
- Else if `scope.highest_affected_layer == subphase` AND PR body declares Upstream Master Plan Domain/Phase → `decision: GO`.
- Else → `decision: HALT`, rationale: subphase plan missing required trace declaration.

`mode_specific_banlist`:
- Develop never writes pillar plans (those are Deconflict's authority; `§Rough Pillars` lives inline in subphase plans).
- Develop never originates scope not traceable to admitted master-plan domain/phase.

#### `gate_mode: deconflict` (Deconflict pre-merge for pillar plan PR)

`action: pre_merge`:
- If `scope.highest_affected_layer ∈ {prd, architecture-spec, master-plan, subphase}` → `decision: HALT`, rationale: Deconflict never edits upstream layers; file Ripple.
- Else if `scope.highest_affected_layer == pillar` AND PR body declares Upstream Subphase + Tracker Trace Key + No Higher-Layer Impact Rationale → `decision: GO`.
- Else → `decision: HALT`, rationale: pillar plan missing required trace declarations.

#### `gate_mode: sequence` (Sequence tracker_admit)

`action: tracker_admit`:
- If `scope.file_paths[]` does NOT include a polished pillar plan path under `docs/plans/pillars/<...>-plan.md` → `decision: HALT`, rationale: every TRACKER edit must cite an existing plan-derived unit from a polished pillar plan; missing scope routes to Ripple or Develop, not TRACKER.
- Else → `decision: GO`.

`mode_specific_banlist`:
- Sequence never originates phase, subphase, pillar, or task scope.
- Sequence never edits PRD, architecture spec, master plan, subphase plans, or pillar plans.
- Sequence never writes source code or tests.

### Banlist (`enforce-gate`)

Load-bearing forbiddens — these apply to the mode itself, not just per-`gate_mode` banlists above:

- **No auto-merge of PRD or arch-spec PRs.** Load-bearing safety. PRD and arch-spec are dual-gated (`MAJOR_GATED`) — pre-drafting AND pre-merge operator approval. Even if the operator passed `operator_approval_captured: true` for one approval kind, both must be captured.
- **No silent escalation suppression.** When the predicate says ESCALATE, the mode MUST return ESCALATE — never quietly downgrade to GO because "the operator probably already approved."
- **No mode crossover.** A `gate_mode: build` invocation does NOT consider Engineer Gate or Ripple gate predicates; each `gate_mode`'s gate-enum is independent.
- **No file writes.** Read-only; predicate plus rationale plus boundary-language only.
- **No spawning teammates / Task subagents.** Single-process; the caller orchestrates the multi-step flow.
- **Mode-specific banlists carry into the prompt.** This mode returns `mode_specific_banlist[]` so the orchestrator can inject it into the next teammate's prompt verbatim. Don't drop the banlist on the floor.
- **Boundary language must be injected.** The orchestrator must inject `boundary_language` into the drafting teammate's prompt (Engineer mode), into the PR body (any mode), or into the operator-facing question (ESCALATE branch). Returning the language without injecting it is a discipline failure.
- **`gate_mode: skip` does not bypass per-PR review or fence enforcement.** It only suppresses Engineer / Build / Ripple / Develop / Deconflict / Sequence gate predicates. The standard per-PR `code-review-custom` cycle, the phase-close adversarial-review pass, and `tests/test_arch_*.py` fences still run normally.

---

## Single-process confirmation

This skill is single-input → single-output regardless of `mode`. Each `mode` invocation takes one packet and either returns a small response packet (`enforce-gate`) or writes one scratch artifact + returns a small descriptor (`curate-slice`, `discipline-spawn`). No internal multi-step orchestration, no spawning of teammates / Task subagents (the SKILL is invoked by a parallel-dispatched Task subagent in `curate-slice` mode, but the skill itself does not spawn). No state across invocations; each call is independent. Multi-step dispatch (compute brief → write brief → spawn teammate → SendMessage assignments → poll outputs) is the responsibility of the calling IDC role orchestrator.

## Codex parity note

Loaded via the Skill tool by the Codex adapter skills (`idc:codex-idc-think`, `idc:codex-idc-plan`, `idc:codex-idc-sequence`, `idc:codex-idc-build`, `idc:codex-idc-ripple`) per substrate-redirection sweep. The packet shape applies identically across runtimes; per-mode behavior is byte-compatible. For Codex specifically:

- `curate-slice` — when the parent's per-slice subagents dispatch via Codex inline-read, this mode's per-slice section shape is the per-slice emit contract.
- `discipline-spawn` — Codex sibling has no equivalent today; loading this skill from inside any Codex adapter skill gives the Codex parent + bounded subagents the same brief-on-disk + thin-prompt + anti-absorption discipline. Particularly useful for idc:codex-idc-plan (long PRD-section briefs are the canonical worst case) and idc:codex-idc-build (per-PR fixer dispatch). The brief-path written by this skill becomes the literal `Read` target inside the Codex subagent prompt per architecture.md §Cross-runtime substrate model option 2 (inline-read).
- `enforce-gate` — no Codex adapter skill has externalized gate substrate today; loading this skill from inside any Codex adapter skill gives the Codex parent the same gate-enforcement substrate. Most important for idc:codex-idc-plan (Engineer Gate) and idc:codex-idc-ripple (`MAJOR_GATED`/`GATED` operator-approval-gatekeeper). When this mode returns `decision: ESCALATE`, the Codex parent surfaces the operator question through its own prompt-result mechanism (Codex companion stops and asks); the mode's output is unchanged.

## See also

- CS-4 `governance-verdict` — companion read-only classifier; this skill's `enforce-gate` `scope` argument is typically CS-4's response packet.
- RS-2 `impact-classifier` — Ripple-specific 4-value verdict; feeds this skill's `ripple_verdict` input when `enforce-gate` `gate_mode: ripple`.
- ES-2 `idc:idc-skill-canonical-admission-audit` — Plan-mode consumer of `curate-slice`'s assembled packet.
- ES-3 `idc:idc-skill-considerations-admissibility-review` — per-file admissibility classifier; complementary to `curate-slice` (this curates ALL anchors; ES-3 classifies one considerations file at a time).
- `superpowers:dispatching-parallel-agents` — closest neighbor at task-dispatch granularity; this skill's `discipline-spawn` mode adds the IDC-specific file-based-brief discipline on top.
- Operator-is-lead spawn constraint (IDC doctrine) — enforced by `discipline-spawn`; see §Operator-is-lead spawn invariant above.
- Orchestrator context discipline (IDC doctrine) — the curator-absorbs / orchestrator-reads-only-the-assembled-packet discipline this skill enables.
- Brainstormer heavy-investigation dispatch (IDC doctrine) — the dispatch-for-heavy-investigation pattern (brainstormer protects its context window via dispatch-request).
- `${CLAUDE_PLUGIN_ROOT}/agents/idc-{think,plan,sequence,build,ripple}.md` — the orchestrators that consume this skill across all three modes.
- `docs/workflow/CLAUDE.md §Briefs go in files, not inline prompts` — the operator-canonical articulation of the `discipline-spawn` discipline.
- `docs/workflow/CLAUDE.md §Operator IS the lead (no intermediate "lead" agents)` — the operator-is-lead constraint enforced by `discipline-spawn`.
- `docs/workflow/CLAUDE.md §Phase-transition gate (preconditions — ALL must hold)` — Build's phase-transition preconditions referenced by `enforce-gate` `gate_mode: build` `action: pre_merge`.
- `docs/workflow/CLAUDE.md §Phase-close adversarial-review gate` — Build's phase-close gate referenced when `scope` includes adversarial-review verdict.
- root `CLAUDE.md §Architectural Fitness` — fence-pinned content `curate-slice` quotes verbatim; per-`gate_mode` banlists in `enforce-gate` trace back to root `CLAUDE.md §IDC role authority`.
- `tests/CLAUDE.md` — fence inventory + fence-add policy.
- Caller-side input-type classification logic lives in `${CLAUDE_PLUGIN_ROOT}/agents/idc-plan.md` §Phase 0 (input-type → gate_mode mapping) and `${CLAUDE_PLUGIN_ROOT}/agents/idc-autorun.md` §Phase 1 (autorun always passes `gate_mode: skip`).
