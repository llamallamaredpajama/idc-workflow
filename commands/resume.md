---
description: IDC Resume — pick a deliberately paused run back up. Clears the pause, re-reads the live board, and hands off to the pipeline from where the work actually stands.
argument-hint: '[free-form notes]'
---

You are running `/idc:resume`. A previous session stopped this repo's pipeline run on purpose with
`/idc:pause`; this picks it back up.

**There is nothing to reconstruct.** Pause is graceful by contract — it finished the item that was in
flight, including its board card, before it stopped — so resume never inherits a half-done item. The
work's state was, and still is, **the board**: resume re-reads it live and continues from there,
exactly as `/idc:autorun` already does across interruptions and usage-window resets. The pause record
holds no work state, so clearing it loses nothing.

A paused run is **also** picked up automatically by the next `/idc:autorun` — a pause the operator
forgets about never strands work. This command is the explicit path for when you want to say so.

## Command lifecycle — verify at entry

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" status \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --json
```

## 1 — See what was paused, then clear it

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_pause_state.py" --cwd "$PWD" status
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_pause_state.py" --cwd "$PWD" resume \
  --session "$CLAUDE_CODE_SESSION_ID"
```

- `resume: cleared (paused)` — the run was deliberately paused and is now live again.
- `resume: cleared (pause-requested)` — a pause was **asked for but never achieved** (something was
  still in flight when the pausing session stopped). Nothing was ever recorded as a clean stop, so
  treat this as an ordinary interrupted run: the checks below will surface anything left half-done.
- `resume: not-paused` — nothing was paused. That is a **safe, honest no-op**, not an error. Carry on;
  the handoff below still tells the operator where the run stands.
- `resume: error …` (exit 2) — the pause record could **not** be removed, so this repo is **still
  paused**. STOP HERE: do not run step 2, and do not dispatch any work. Resuming over a surviving
  pause record is the worst of both worlds — the run starts working again while the Stop gate, reading
  that record, still believes the run is cleanly stopped and will allow an undrained walk-away. Relay
  the printed cure (make the record path writable) and end the session.

## 2 — Re-read where the run actually stands

The board is the source of truth, so derive the handoff from it rather than from anything remembered:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_next_action.py" --repo "$PWD" --json
```

If the paused run left anything unfinished, the same read-only reader `/idc:pause` uses will say so —
run it once and relay its findings before dispatching new work:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_pause_check.py" --repo "$PWD"
```

`pause-ready: in-flight …` here means the run did **not** stop cleanly (a hard kill, or a pause that
was requested and never confirmed). Each finding names its cure; resolve them before dispatching new
work, and say so in your report rather than continuing over the top of them.

## 3 — Continue the run

Hand off to the pipeline the oracle names. In practice that is `/idc:autorun` (the full-pipe drain,
which re-reads the live board every pass and resumes across interruptions by design) — read
`${CLAUDE_PLUGIN_ROOT}/agents/idc-autorun.md` and run its loop, or quote the oracle's command for the
operator. Resume itself dispatches no build work of its own: its product is a live, unpaused run and an
honest statement of where it stands.

## 4 — Closeout

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" finish \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --command resume \
  --status <complete|blocked_external> --evidence-json '{"schema_version":1,"refs":{}}'
```

- **`complete`** — no pause record remains (re-read from disk) **and** a fresh, valid next-action oracle
  read backs the handoff. Both are re-derived by the validator, so `refs:{}` is enough. Resuming when
  nothing was paused satisfies this honestly — an unpaused repo IS the intended end state.
- **`blocked_external`** — the board could not be read, so nothing could be resumed from it. Cite
  `blocker:{helper:"idc_pause_check.py", exit:<its nonzero exit>, diagnostic:"<why>"}`; the validator
  re-runs that check and requires the cited exit to match what it actually does now.

Then report in plain words: what was paused (and by which session), what you cleared, whether anything
was left unfinished, and the oracle's next action.
