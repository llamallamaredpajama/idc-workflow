---
description: IDC Ask — say what you want in plain English and IDC routes you to the right command. Reads live state, explains where you stand, never acts without confirming.
argument-hint: '[what you want, in plain English]'
---

You are running `/idc:ask` on its advisory path. The resolver could not confidently name one command.
That is a deliberate refusal to guess, not a failure.

## Command lifecycle — verify at entry

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" status \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --json
```

## 1 — Read the live state

Both of these commands are read-only:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_next_action.py" --repo "$PWD" --json
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_pause_state.py" --cwd "$PWD" status
```

## 2 — Answer plainly

Answer in this order: where the pipeline stands now; what the operator seems to want; the one command
that does it, spelled exactly (for example `/idc:plan`); and one plain-English sentence about what that
command will do.

If the oracle says a human gate is open, name that gate and say only the operator can open it; no
command will move until they do. If the request is outside IDC (for example, "just open a PR"), say
that governed work enters through the pipeline, name the IDC route that gets them there, and cite
`WORKFLOW.md` §1.1.

**Hard boundary:** `/idc:ask` has no write authority. It never edits files, touches the board, opens
or merges anything. If the operator wants the work done, they type the command you named. Say so
plainly rather than appearing to stall.

## 3 — Closeout

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" finish \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --command ask \
  --status <complete|no_action|blocked_external> --evidence-json '<envelope>'
```

- `complete` — a fresh oracle read backed a named recommendation.
- `no_action` — the oracle reports a fixpoint: nothing to do, and saying so is the product.
- `blocked_external` — the oracle could not read (rate-limited or invalid state); cite
  `blocker:{helper:"idc_next_action.py", exit:<2|3>, diagnostic:"<why>"}`.
