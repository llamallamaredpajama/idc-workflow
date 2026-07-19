# Autorun integration for `/idc:pause` and `/idc:resume`

**For the integrator.** `commands/autorun.md` and `agents/idc-autorun.md` were off-limits to the
teammate that built pause/resume (three concurrent writers). Everything else is wired and green; this
file holds the one change those two files still need, ready to paste.

Nothing here is required for `/idc:pause` or `/idc:resume` themselves to work — both are complete and
tested without it. What it buys is the second resume path: **a pause the operator forgets about must
never silently strand work.** With this block in place, the next `/idc:autorun` picks a paused run
back up on its own.

## What the block does

One deterministic call, at the very top of the drain, before any other preflight step. It clears the
durable pause record and reports what it cleared. That is the whole integration, because a paused run
has no other state to restore: pause is graceful by contract (it finished the in-flight item,
including its board card, before it stopped), and the durable state of the WORK is — as autorun
already assumes — the board, which the drain re-reads every pass anyway.

It is safe on every path: when nothing is paused it prints `resume: not-paused` and exits 0, so the
common case costs one local file stat. It performs no board read, so it adds zero GraphQL.

## The block

Insert it into `commands/autorun.md` immediately **after** the "Mark this session as a drain
orchestrator" step and **before** the "Janitor preflight" step, under this heading:

> **Pick up a paused run (deterministic — run ONCE, at drain start).** A previous session may have
> stopped this repo's pipeline on purpose with `/idc:pause`. That pause is graceful by contract —
> nothing was left half-done — and it holds no work state, so resuming it is exactly: clear the
> record, then drain from the live board as usual. Doing this at the top of the drain is what makes a
> forgotten pause impossible to strand: the operator gets the run back by running `/idc:autorun`,
> without having to remember they paused it. `resume: not-paused` is the normal, silent case.

<!-- autorun-preflight:begin -->
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_pause_state.py" --cwd "$PWD" resume \
  --session "$CLAUDE_CODE_SESSION_ID"
```
<!-- autorun-preflight:end -->

> Report it in the exit report when it cleared something: `resume: cleared (paused)` means this run
> continues a deliberately-paused one, and `resume: cleared (pause-requested)` means the previous
> session asked to pause and never achieved it — an ordinary interrupted run, so treat anything the
> normal preflight sweeps surface as that session's unfinished business, not as a clean handover.

The HTML comments around the block are load-bearing for the test, not for the reader:
`tests/smoke/phase10-pause-resume.sh` (section A9) extracts the fenced block **from this file** and
executes it against a real paused repo. So the documented integration is the tested one — if you
change the command here, change it here first and the test follows.

## Two smaller edits in the same two files

1. **`commands/autorun.md`, exit-report list** (the "Emit the exit report" paragraph): add *whether
   this run resumed a paused one* to the list of things the report states.

2. **`agents/idc-autorun.md`** — mirror the same preflight step in the playbook. `/idc:autorun` tells
   the session to read the agent file and run ITS steps, so a step that exists only in the command
   markdown is not live in a real run (the same trap `phase7-command-prose-invariants.sh` already
   locks for the `--acceptance` flag).

## What is already done (no action needed)

- `commands/pause.md`, `commands/resume.md` — the two playbooks.
- `scripts/idc_pause_state.py` — the durable pause record and its single write door.
- `scripts/idc_pause_check.py` — the read-only, fail-closed "is anything half-done?" reader.
- `scripts/idc_command_contract.py` — `pause`/`resume` in `COMMANDS`, the new `paused` terminal status
  in the claim table (legal for the six pipeline commands only), and the `idc_pause_check.py` blocker
  branch.
- `scripts/hooks/idc_command_entry_gate.py` — `resume` as a workflow command, `pause` as a recovery
  one (pausing must stay possible on a degraded install; resuming puts the pipeline back in motion).
- `scripts/hooks/idc_stop_fixpoint_gate.py` — a confirmed pause allows the stop.
- `hooks/hooks.json` — the entry-gate matcher (lint Rule P requires it).
- `scripts/idc_init_scaffold.sh` + `commands/update.md` — gitignore the pause record.
- `tests/smoke/phase10-pause-resume.sh` + its registration in `tests/smoke/run-all.sh`.

## Loose ends for the integrator

- **Command counts in prose are now stale.** `README.md`, `CLAUDE.md`, `AGENTS.md`,
  `docs/architecture.md`, and `templates/WORKFLOW.md` all say "11 slash commands". It is 13. Left
  unedited deliberately — several are shared with the other concurrent work.
- **No `CHANGELOG.md` entry and no version bump.** Adding an `## Unreleased` section without bumping
  `plugin.json` fails lint Rule H, and the bump belongs to whoever cuts the release.
