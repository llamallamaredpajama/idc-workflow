---
name: idc-skill-matrix-dispatch-check
description: 'Use when IDC Build is about to dispatch pillar work and must gate against the active matrix.'
---
# IDC Skill — Matrix Dispatch Check (`idc:idc-skill-matrix-dispatch-check`)

CUSTOM. Build's hard preflight gate before every pillar dispatch. Build's matrix consumption is **CLI-only** by canonical contract — Build NEVER reads `<phase-tag>-matrix.yaml` directly. Sequence is the sole matrix writer; Build only joins it with Tracker state via the CLI. The Tracker substrate is the GitHub Projects V2 backend (per `idc:idc-skill-tracker-adapter` dispatch); Build refreshes the per-dispatch state JSON via `scripts/sync_github_tracker.py export-state --output <path>` (the GraphQL exporter introduced by P1 + admitted by Engineer §Phase 1) before invoking this skill. Filesystem-backend fallback (`tracker-config.yaml::backend = filesystem`) substitutes a TRACKER.md-derived JSON of the same shape; the CLI consumer is identical. This skill is the single-process wrapper for that CLI invocation.

The verdict is deterministic from the CLI; this skill does NOT make routing decisions. If the verdict is `blocked-by` or `conflicts-with`, the caller (Build orchestrator) decides whether to halt-and-pick-different-pillar OR file a Ripple uphill correction via the orchestrator inline (substrate: `idc:idc-skill-ripple-verdict` + `idc:idc-skill-drift-evidence`).

## When to invoke

Inside `idc:idc-build` Phase 2 (Phase-tracker bootstrap, after the dispatch packet returns) AND before EVERY writer dispatch in Phase 3. The check fires once per pillar dispatch attempt, not once per phase.

Specifically:

- **Cold-mode Build dispatch** — after the orchestrator inline (substrate: `idc:idc-skill-tracker-adapter`) returns the dispatch packet, but BEFORE Build spawns BR-1 `idc:idc-role-writer` teammates for the pillar.
- **Resume-mode Build dispatch** — after CR-6 in `--resume` mode reports `RESUME_READY`, before resuming a paused pillar's writer dispatch.
- **Ripple-uphill-correction re-check** — after a the orchestrator inline (substrate: `idc:idc-skill-ripple-verdict` + `idc:idc-skill-drift-evidence`) Ripple lands and Sequence re-runs Phase 2 (per `idc-build.md §Ripple uphill correction path`), Build re-invokes this skill on the affected pillar to confirm `safe`.

Do NOT invoke from non-Build roles. Sequence's tracker-admit gate uses CS-4 `idc:idc-skill-ripple-verdict` + CS-5 `idc:idc-skill-planning-substrate` for its own decision; the matrix dispatch-check is downstream of admission, not a substitute for it.

## Input shape

Caller passes a single packet with:

- `pillar_trace_key` — the polished pillar plan's filename stem without the `-plan` suffix; matches `pillars[].pillar_id` in `<phase-tag>-matrix.yaml`. Example: `phase-9-subphase-2-pillar-1-rolling-rough-skeleton`.
- `tracker_state_path` — path to a JSON file representing current Tracker state in `{pillar_id: status}` shape (consumed by `pillar_matrix.py::_load_tracker_state` after the P3 markdown→JSON parser flip). Build generates this file fresh per dispatch via `scripts/sync_github_tracker.py export-state --output <path>` (GitHub backend — the canonical substrate emitter; D5-fold names this exporter as the upstream of `pillar_matrix.py --tracker-state`). Filesystem-backend fallback emits the same JSON shape from `TRACKER.md` parsing; the consumer flag remains `--tracker-state` either way (NOT `--tracker-state-path` — D5-fold). When omitted, `pillar_matrix.py` treats Tracker state as empty and `dispatch_check` returns `unknown-pillar` for any non-trivial gate; this skill does NOT generate the state file.
- `phase_tag` — optional; the consolidated matrix filename slug (e.g. `phase-9-subphase-2`). Inferred from `pillar_trace_key` when omitted.
- `repo_root` — optional; absolute path to the host repo root. Defaults to `git rev-parse --show-toplevel` resolved at skill invocation.

## Output shape

A single response packet (no file writes — read-only skill):

```yaml
verdict: safe | blocked-by:<pillar-id> | conflicts-with-wave-member:<pillar-id>
pillar_trace_key: <input echo>
phase_tag: <inferred or input>
matrix_path: <abs path to <phase-tag>-matrix.yaml>
evidence:
  blocks_on: [<pillar-id list from matrix>]
  blocks_on_status: [<pillar-id: pending|active|complete>]
  shared_surfaces: [<file path list>]
  active_wave_members: [<pillar-id list>]
raw_cli_stdout: <full stdout from pillar_matrix.py --dispatch-check --json>
raw_cli_stderr: <full stderr>
exit_code: <int>
```

### Verdict values

- `safe` — all `blocks_on` upstream pillars are `complete` in TRACKER AND no in-flight conflict on shared surfaces with any wave-member pillar in `active` status. Caller proceeds with dispatch.
- `blocked-by:<pillar-id>` — at least one upstream pillar named in the matrix's `blocks_on` edge for `<pillar_trace_key>` is NOT `complete`. Caller halts the affected pillar (don't-stop-the-train: continue with other unaffected pillars).
- `conflicts-with-wave-member:<pillar-id>` — another pillar in the same wave is `active` AND shares a non-parallel-safe surface (per the matrix `parallel_safe_with` field). Caller halts the affected pillar; serialize after the wave member completes OR file Ripple if the parallel-safety analysis is wrong.

## Implementation contract

The skill's body is the documented invocation pattern; the caller (Build orchestrator) executes the CLI directly via Bash. The skill is the documentation + verdict-shape contract.

State refresh (Build pre-dispatch step — produces the JSON consumed by `--tracker-state`):

```bash
cd "$REPO_ROOT" && \
  uv run python scripts/sync_github_tracker.py export-state \
    --output "$TRACKER_STATE_PATH"
```

Dispatch check (this skill's wrapped invocation):

```bash
cd "$REPO_ROOT" && \
  uv run python docs/workflow/scripts/pillar_matrix.py --dispatch-check \
    --pillar="$PILLAR_TRACE_KEY" \
    --tracker-state="$TRACKER_STATE_PATH" \
    --json
```

Flag-spelling pins (D5-fold + P3 drift-3 — verbatim against live argparse at `docs/workflow/scripts/pillar_matrix.py`):

- The pillar selector flag is `--pillar` (NOT `--pillar-trace-key`). The argument value is the polished pillar plan's filename stem without `-plan`, matching `pillars[].pillar_id` in `<phase-tag>-matrix.yaml`.
- The state-input flag is `--tracker-state` (NOT `--tracker-state-path`). The argument value is the JSON path produced by `sync_github_tracker.py export-state --output <path>`.
- The state-producer subcommand is `sync_github_tracker.py export-state` (subcommand, not a top-level `--export-state` flag). Inherit the live spelling per the same surgical-correction precedent that fixed `--tracker-state` in P3.

Exit codes:
- `0` — verdict is `safe`. Stdout is the full evidence packet in JSON.
- `1` — verdict is `blocked-by:<id>` OR `conflicts-with-wave-member:<id>`. Stdout names the verdict + evidence. Caller parses and decides.
- `2` — CLI error (matrix file unreadable, pillar_trace_key not in matrix, tracker-state.json malformed, etc.). Caller halts with `BLOCKED: blocker: matrix_cli_error`.

The caller MUST capture both stdout and stderr verbatim into the response packet; downstream Ripple-trigger logic may need the raw evidence to draft an accurate change-order proposal.

## Single-process confirmation

This skill is single-input → single-output: caller hands one packet (`pillar_trace_key`, `tracker_state_path`, optional `phase_tag`, optional `repo_root`), skill returns one response packet (`verdict`, `evidence`, `raw_cli_stdout`, `raw_cli_stderr`, `exit_code`). Read-only — never writes files, never spawns teammates / Task subagents, no state across invocations. Each call is independent. Verdict-branching (Ripple uphill correction draft, halt-vs-pick-different-pillar) is the caller's responsibility.

## Banlist

Load-bearing forbiddens:

- **No matrix writes.** Build is read-only on `<phase-tag>-matrix.yaml`. Sequence is the sole matrix writer (per `${CLAUDE_PLUGIN_ROOT}/agents/idc-sequence.md` authority); attempting to edit the matrix from this skill is a canonical-chain violation.
- **No Tracker writes.** Status / order updates are bookend-only and live in Build's separate bookend-open / bookend-close flow (`gh issue edit` + `gh project item-edit` against the GitHub Projects V2 board on the GitHub backend; equivalent TRACKER.md edits on the filesystem fallback), not this skill.
- **No Ripple draft.** When verdict is `blocked-by` or `conflicts-with`, this skill returns the verdict + evidence and stands down. The Ripple change-order draft is the orchestrator inline (substrate: `idc:idc-skill-ripple-verdict` + `idc:idc-skill-drift-evidence`)'s authority.
- **No silent verdict downgrade.** If the CLI returns `blocked-by:<id>`, this skill MUST return `blocked-by:<id>` — never quietly downgrade to `safe` because "the upstream pillar is probably almost done."
- **No matrix file invention.** If `<phase-tag>-matrix.yaml` is missing, the CLI returns exit code 2; this skill surfaces the error verbatim. Sequence must run admission first.
- **No retry-on-error.** A single CLI invocation per skill call. Caller decides whether to retry (e.g. after a tracker-state.json refresh).

## Codex parity note

The pillar_matrix.py CLI is runtime-portable Python — both Claude and Codex Build orchestrators invoke it identically via Bash. The verdict vocabulary (`safe | blocked-by:<id> | conflicts-with-wave-member:<id>`) is byte-compatible across runtimes; idc:codex-idc-build inline-reads this SKILL.md body to load the invocation contract. No Claude-only dependencies in the implementation contract.

## See also

- `${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md §Matrix dispatch-check protocol` — caller-side gate documentation, including the `Ripple uphill correction path` for `blocked-by` / `conflicts-with` verdicts.
- the orchestrator inline (PR-5 fold; see substrate skills) (CR-6) — upstream of this skill; returns the dispatch packet that names the pillar to gate.
- the orchestrator inline (PR-5 fold; see substrate skills) (CR-8) — downstream of this skill when verdict is non-`safe`; drafts Ripple change-order proposal at scratch path for operator surfacing.
- `${CLAUDE_PLUGIN_ROOT}/agents/idc-sequence.md §Matrix authoring` — Sequence is the sole matrix writer; Build's CLI consumption is downstream.
- `tests/test_arch_pillar_matrix.py` — fence pinning the matrix's deterministic synthesis + active-row-locking discipline (Sequence's WM-3/WM-4/WM-5 contract).
- `docs/workflow/CLAUDE.md §Per-lane Currently building pointer` — per-lane vs global semantics that ride on the dispatch-check verdict.
