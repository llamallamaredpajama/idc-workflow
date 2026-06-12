---
name: idc-skill-pr-deconflict-resolve
description: 'Use when resolving pull request conflicts under IDC deconflict rules.'
---
# IDC Skill — PR Deconflict Resolve (`idc:idc-skill-pr-deconflict-resolve`)

CUSTOM. Per-conflict resolution substrate consumed by BR-2 `idc:idc-role-merge-deconflictor` when spawned with `mode: prose`. The skill takes a blob containing `<<<<<<< HEAD ... ======= ... >>>>>>> ` merge-marker conflicts on a canonical-doc PR (Engineer's admission PR; Develop's subphase-plan PR; Deconflict's pillar-plan PR; Build's per-PR canonical-doc edits — Build's source-code conflicts stay inside BR-2 default-mode `mode: code-semantic` and never reach this skill), classifies each conflict, applies the per-`gate_mode` authority-surface preservation rules, and emits a resolved file body at the scratch path.

## When to invoke

Inside BR-2 `idc:idc-role-merge-deconflictor` with `mode: prose` Phase 2 when a canonical-doc PR has merge-marker conflicts. The `gate_mode` parameter (`engineer | develop | deconflict | build`) selects the per-role authority-surface preservation rules.

## Input shape

Caller passes a single packet with:

- `conflict_blob_path` — absolute path to the file containing merge-marker conflicts (typically captured from `git diff` or the PR's CI conflict surface).
- `gate_mode` — exactly one of `engineer | develop | deconflict | build`. Selects per-role authority-surface preservation rules.
- `scratch_dir` — absolute path to BR-2's scratch dir for the prose-mode invocation.
- `output_path` — absolute path for the resolved file body (typically `<scratch_dir>/resolved-<basename>.md`).
- `authority_surface_inventory` — for the named `gate_mode`, the list of fields/sections that MUST be preserved verbatim regardless of which side won. (E.g. for engineer: `Pipeline:`, `Highest Affected Layer:`, `Upstream Master Plan Domain/Phase:`, all 7 INJECT blocks per `references/authority-boundary-injects.md`; for develop: `Upstream Master Plan Domain/Phase`, `§Rough Pillars` schema; for deconflict: `Upstream Subphase`, `Tracker Trace Key`, `Resource Ownership table`; for build: trace declarations + work-packet IDs + arch-fitness fence references.)

## Output shape

- **Resolved file body** at `output_path` — markers stripped, per-side picks applied, authority-surface preserved.
- **Per-resolution rationale log** at `<scratch_dir>/pr-deconflict-resolve-log.md` — one entry per conflict with anchor + classification + side-picked + rationale. Caller (BR-2 mode=prose) decides whether to commit the resolved body.
- **Return packet:** `{output_path, resolution_log_path, conflict_count, resolution_kind_counts, halt_reason?}`.

### Per-resolution rationale log shape

```yaml
---
log_kind: pr-deconflict-resolve-log
gate_mode: engineer | develop | deconflict | build
conflict_count: <N>
---

# PR deconflict resolve log — <gate_mode>

## Per-conflict resolutions

| # | Anchor | Classification | Side picked | Rationale |
|---|--------|----------------|-------------|-----------|
| 1 | `<file>:<line>` | append-collision \| reorder \| sibling-replacement \| semantic-conflict | HEAD \| origin/main \| union \| HALT | <one-line> |
| ... |

## Authority-surface preservation report

(For each item in `authority_surface_inventory`, confirm presence + byte-for-byte preservation in the resolved body. List any missing/changed items as halt reasons.)
```

## Procedure

1. **Read** `conflict_blob_path` end-to-end. Identify every `<<<<<<< / ======= / >>>>>>> ` triplet — these are conflict regions.
2. **Per conflict, classify:**
   - **append-collision** — both sides append to the same tail section (typical for CLAUDE.md gotchas list; on the filesystem tracker backend, also tracker log entries — the GitHub Projects tracker backend self-serializes concurrent issue edits, so this collision does not arise there). Resolution: UNION (keep both, in chronological order).
   - **reorder** — same content but different ordering. Resolution: pick the side that matches the canonical-doc convention (e.g. master-plan §Phase ordering).
   - **sibling-replacement** — both sides replaced the same paragraph with different prose, but not semantically conflicting. Resolution: pick the side that better matches `authority_surface_inventory` semantics; if ambiguous, HALT and surface to caller.
   - **semantic-conflict** — both sides changed meaning in incompatible ways (e.g. opposite verdicts in an audit). Resolution: HALT with `blocker: semantic_conflict` and surface to caller. For Build mode, semantic-conflict in SOURCE code is out of scope here — BR-2 must be re-spawned with default `mode: code-semantic` (Fable 5 / 1M-context / ultrathink) instead of `mode: prose`. This skill only resolves prose / canonical-doc merge markers.
3. **Apply per-mode authority-surface preservation:**
   - **engineer mode:** every `Pipeline:`, `Highest Affected Layer:`, `Upstream Master Plan Domain/Phase:` line preserved byte-for-byte from whichever side has the most-recent version. The 7 INJECT blocks from `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-canonical-doc-authoring/references/authority-boundary-injects.md` preserved verbatim. Any conflict that would alter an INJECT halts.
   - **develop mode:** every `Upstream Master Plan Domain/Phase` line preserved; `§Rough Pillars` schema (per pillar: `rough_scope`, `file_surfaces`, `dependencies`, `parallel_safety_hints`) preserved byte-for-byte.
   - **deconflict mode:** every `Upstream Subphase`, `Tracker Trace Key`, `Resource Ownership` table preserved byte-for-byte; clash-evidence resolutions (`Resolution: serialize | union | ripple-required`) preserved.
   - **build mode:** trace declarations + work-packet IDs + arch-fitness fence references preserved. Any source-code conflict halts — caller must re-spawn BR-2 with default `mode: code-semantic` instead of `mode: prose`.
4. **Emit the resolved file body** at `output_path`. Strip every conflict marker. The body should be valid markdown / YAML / canonical-doc shape.
5. **Emit the per-resolution rationale log** at `<scratch_dir>/pr-deconflict-resolve-log.md`.
6. **Validate output:**
   - No conflict markers remain in the resolved body.
   - Every item in `authority_surface_inventory` appears verbatim in the resolved body.
   - The body is well-formed for the gate_mode (e.g. master-plan body parses; subphase plan trace headers present).
7. **Return** the small return packet. If any HALT classifications occurred during step 2 OR any authority-surface item failed validation in step 6, the verdict is `HALTED` with the appropriate `halt_reason`.

## Single-process confirmation

Single-input → single-output: caller hands one packet (conflict_blob + gate_mode + scratch_dir + output_path + authority_surface_inventory), skill writes one resolved file body + one resolution log at the canonical scratch paths and returns one return packet. No internal multi-step orchestration, no spawning of teammates / Task subagents, no state across invocations.

## Banlist

Load-bearing forbiddens:

- **No edits to canonical paths.** Output is scratch only — the caller (BR-2 mode=prose) decides when to commit the resolved body.
- **No semantic source-code conflict resolution.** Source-code semantic conflicts are handled by the same role file (`idc:idc-role-merge-deconflictor`) when spawned with default `mode: code-semantic` (Fable 5 / 1M-context / ultrathink). This skill (mechanical, no deep-analysis budget) is for prose / canonical-doc merge markers only — invoked exclusively from `mode: prose`. The two modes share one roleplayer per the Phase 2 PR-5 fold.
- **No silent authority-surface drift.** When an `authority_surface_inventory` item disagrees byte-for-byte with the resolved body, halt with `blocker: authority_surface_drift` — do not silently rewrite to match.
- **No marker remnants.** The resolved body MUST contain zero `<<<<<<< / ======= / >>>>>>> ` markers. Any remnant is a halt.
- **No re-authoring.** This skill resolves conflicts; it does not introduce new content beyond what either side proposed.
- **No mode crossover.** `gate_mode` is load-bearing — engineer-mode rules don't apply to develop-mode PRs and vice versa.
- **No HEAD-bias / origin-bias.** Default resolution per classification — append-collision UNIONs both sides; reorder picks canonical convention; sibling-replacement halts on ambiguity. Never default to a single side.

## Codex parity note

Loaded via the Skill tool by `${CLAUDE_PLUGIN_ROOT}/skills/codex-idc-plan/SKILL.md` (after substrate-redirection sweep) when BR-2 is dispatched with `mode: prose` in Codex's admission-PR conflict step. The `gate_mode`-parameterized authority-surface preservation rules apply identically across runtimes. Codex parent invokes the skill identically; the resolved-body shape + per-resolution log are byte-compatible.

## See also

- BR-2 `idc:idc-role-merge-deconflictor.md` — the parent roleplayer agent. Spawn with `mode: prose` (inherits session model) to consume this skill across all 4 `gate_mode`s; spawn with default `mode: code-semantic` (Fable 5 / 1M-context / ultrathink per `docs/workflow/CLAUDE.md §PR review-fix protocol`) for source-code semantic conflicts. Both modes live behind one role file per the Phase 2 PR-5 fold.
- `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-canonical-doc-authoring/references/authority-boundary-injects.md` — the 7 INJECT blocks the engineer-mode authority-surface inventory must preserve.
- `docs/workflow/CLAUDE.md §Worktree merge — single-shot pattern` — context for when this skill fires in the merge flow.
- `docs/workflow/CLAUDE.md §Parallel-pillar doc conflicts resolve as union` — the canonical resolution pattern for append-collision-class conflicts.
