---
description: IDC Pause — stop a long autonomous run on purpose, gracefully. Finish what is in flight, prove nothing is half-done, record the pause, and stop. /idc:resume (or the next /idc:autorun) picks it back up.
argument-hint: '[why you are pausing]'
---

You are running `/idc:pause`. This is a **graceful, deliberate stop** of this repo's pipeline run — the
alternative to killing the session, which is what leaves work half-done in the first place.

**The promise this command makes, and must never break:** when pause returns, **nothing is half-done**.
Resume never has to reconstruct a partially-finished item, because pause finished the in-flight item —
including flipping its board card and confirming that landed — before it stopped. If pause cannot prove
that, it says so loudly and does **not** report a clean pause.

Pause is not a halt of the *repo*. It changes nothing on the board, opens nothing, closes nothing, and
files nothing. The board remains the durable state of the work; the only thing pause writes down is the
one fact the board cannot hold — *this run was stopped on purpose and is meant to be picked up*.

## Command lifecycle — verify at entry

The command entry gate opened this command's lifecycle record at expansion. Verify it, and note **every
other still-open record** in this session: those are the runs you are pausing.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" status \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --json
```

## 1 — Record that a pause was asked for

Do this **first**, before finishing anything, so that a session which dies mid-pause leaves a true
record of what happened rather than silence:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_pause_state.py" --cwd "$PWD" request \
  --session "$CLAUDE_CODE_SESSION_ID" --note "$ARGUMENTS"
```

`pause: already-recorded` means this repo was already paused (or a pause was already requested).
That is a **safe no-op** — do not treat it as an error, and do not record a second pause. Carry on to
step 2 and confirm it.

## 2 — Finish what is in flight (this is the graceful part)

Ask the deterministic reader what, if anything, is still half-done. It is **read-only** and safe to
re-run as often as you like:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_pause_check.py" --repo "$PWD"
```

- `pause-ready: ok` — nothing is in flight. Go to step 3.
- `pause-ready: in-flight …` — each finding prints its own `cure:` line naming the deterministic
  command that resolves it. **Do the cures, then re-run the check.** Finish the item that is genuinely
  mid-flight through the normal finisher; repair a shipped-but-unflipped board card with the idempotent
  close-only finisher the cure names. Do not start anything **new** — that is the whole point of a pause.
- `pause-ready: error …` — ground truth could not be established (an unreadable board, an unresolvable
  backend). Fix that first; an unprovable state is **never** recorded as a clean pause.

## 3 — Confirm the pause

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_pause_state.py" --cwd "$PWD" confirm \
  --session "$CLAUDE_CODE_SESSION_ID"
```

`confirm` **re-runs the quiescence check itself** and refuses to record a pause on any nonzero result.
There is no override flag, and you cannot pass it a "looks fine to me" — the value of a pause is the
proof behind it. On `pause: paused` the record is durable and this repo is paused.

If it prints `pause: NOT paused (check_exit N)`, the pause did **not** happen. Say that plainly in your
final message — name what is still in flight — and close this command as `blocked_external` (below).
Never describe a refused pause as a clean stop.

## 4 — Close the runs you paused

The pipeline commands still open in this session were interrupted by your pause. Close them with the
`paused` terminal status — the one that tells the truth about a deliberate stop:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_pause_state.py" --cwd "$PWD" close-open \
  --session "$CLAUDE_CODE_SESSION_ID"
```

Every close goes through the validating command-contract door, which re-derives the confirmed pause
record **and** re-runs the quiescence check. A `REFUSED` line means that record could not honestly
close as paused — report it; do not work around it.

**A pause covers `/idc:build`, `/idc:autorun` and `/idc:recirculate` — not `/idc:think`,
`/idc:intake` or `/idc:plan`,** and those three are refused with `paused-stage-unobservable`. The
reason is a limit, stated rather than glossed: `paused` promises that resume never has to reconstruct
partial work, and the quiescence check earns that promise by reading the board and the obligations
ledger. A half-built plan or a half-written requirements doc lives in a branch, which nothing there
reads — so those stages would pass quiescence trivially, and the certificate would mean nothing.
Finish or abandon such a run deliberately, and say in your report which runs the pause did **not**
cover.

## 5 — Closeout

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_next_action.py" --repo "$PWD" --json
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" finish \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --command pause \
  --status <complete|blocked_external> --evidence-json '{"schema_version":1,"refs":{}}'
```

- **`complete`** — the repo carries a **confirmed** pause record and a fresh re-derivation says nothing
  is half-done. The validator re-checks both for real, so the evidence refs may be empty (`refs:{}`).
- **`blocked_external`** — the quiescence check refused the pause. Cite it:
  `blocker:{helper:"idc_pause_check.py", exit:<its nonzero exit>, diagnostic:"<what is in flight>"}`.
  The validator **re-runs the check** and requires the cited exit to match what it actually does now.

Then report, in plain words: what you finished before stopping, that the run is paused, and that
`/idc:resume` — or simply the next `/idc:autorun` — picks it up from the board. Quote the oracle for
where the run stands; never invent a different handoff.
