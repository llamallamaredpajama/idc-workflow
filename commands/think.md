---
description: IDC Think — brainstorm an idea (or a reviewed intake unit), crystallize it into a PRD+TRD draft, and fire the one gate at the end on the Think PR
argument-hint: '"<topic-or-anchor-doc>" [--doc <intake-manifest> --unit <id>[,<id>]] [--slug <name>]'
---

You are running `/idc:think`. This is the front door of the IDC pipeline — and (v3) its **one
human gate**. Thinking starts free: a brainstorm/interview held **in this main session with zero
durable workers**. You talk with the operator and shape one **function-first consideration**, then
**crystallize it into a PRD + TRD draft** and **fire the single gate at the end of Think** by
opening the **Think PR** (`WORKFLOW.md §2`, `§4.1`). Admission to the pipeline is the operator
merging that PR.

Operator input: `$ARGUMENTS` — a topic, an anchor doc (`--doc <path>`), and/or a slug; **or** a
reviewed external-intake selection `--doc <intake-manifest> --unit <id>[,<id>]` (a validated intake
manifest and the unit(s) that route to `think`). A foreign plan is **evidence, never execution
authority** — Think consumes only units the intake compiled and an independent review PASSED, and
never routes one to Build or Autorun.

## Command lifecycle — verify at entry, close out through the oracle

The command entry gate opened this command's lifecycle record at expansion; verify it before working,
and **close it with a validated terminal status** before your final answer (the Stop closeout gate
refuses a walk-away from an open command):

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" status \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --json
```

## Intake selection (only with `--doc <manifest> --unit …`)

Before drafting, validate the manifest **and** its independent review, then confirm every selected
unit's `route` is `think` (reject any other route; never build from a foreign plan):

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_intake_manifest.py" status --manifest "$MANIFEST" --json
```

Use each selected unit's `summary` as the seed for the consideration. The un-selected expected units
stay exactly where the manifest left them (their durable disposition is not yours to change here).

## How to run it

1. **Interview, don't lecture.** Draw the idea out: what should the product *do for the
   user*, how should it behave, what's in and out. A grill-me-style back-and-forth is
   welcome when the operator wants to stress-test the idea. Keep the operator in the loop;
   this is a conversation, not a delivery. The conversation itself is ungated — it is the
   crystallized output that the operator gates.
2. **Research on demand via bounded fan-out.** When a question needs the codebase or the
   web, send it to a throwaway subagent / Workflow fan-out (per the runtime adapter) and
   fold back the digest. **Never spawn a durable worker** and never let research stall the
   conversation — the budget here is zero teammates.
3. **Crystallize: function-first, then PRD + TRD.** Capture what the user gets and how it
   behaves, organized by domain where natural — function FIRST, not an implementation task
   list. Then draft the **two gated requirements docs**: the **PRD** (the user-facing *what*)
   and the **TRD** (the technical *how* — the `spec` layer). The consideration records the
   `PRD impact:` and `TRD impact:` it drives. These are the only requirements docs in the
   system, and they are authored **here**, at Think.

## Output

Write the consideration and the PRD + TRD draft, then open the Think PR:

1. Write `docs/considerations/<YYYY-MM-DD>-<slug>-considerations.md` following
   `idc:idc-consideration-schema` (H1 title; Date/Status/PRD-impact/TRD-impact metadata; a
   "What this does for the user" function-first section; behavior by domain; Open questions for
   Plan), and validate it before finishing:

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_consideration_check.py" \
     docs/considerations/<YYYY-MM-DD>-<slug>-considerations.md
   ```

   Fix anything it flags (it requires the function-first section, the `PRD impact:` and
   `TRD impact:` lines, and an Open-questions handoff) until it reports `PASS`.
2. Draft the **PRD** (`docs/prd/`) and the **TRD** (`docs/specs/`) the consideration drives —
   the user-facing *what* and the technical *how*. They stay **draft until merge**.
3. **Fire the one gate** with `idc:idc-gate-issue`: open the **Think PR** carrying the
   consideration + the PRD/TRD draft, plus the operator gate issue (plain-terms summary of what
   the app will do differently + the PRD/TRD diff + push notification), and write the
   consideration pointer (`Stage = Consideration` — open Think PR / pending admission). The Think
   PR body carries **exactly one** `<!-- idc-gate-pr: <gate#> -->` marker binding the gate issue to
   THIS PR — the same marker `idc_pr_finish.py requirements` re-verifies at admission (a markerless
   or double-marked gate fails closed). Approval is **sync or async**: the operator may approve
   in-session, or leave the PR open and approve later from the GitHub web UI. **Merge = approval =
   admission.** Until then the requirements stay draft and nothing downstream proceeds.
4. **Link each consumed intake unit** (only on a `--doc … --unit …` run). Once the Think PR / gate /
   pointer are written back, materialize each selected unit on the exact-once manifest via
   `idc_intake_manifest.py link --state materialized` — never leave the manifest stale:
   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_intake_manifest.py" link \
     --manifest "$MANIFEST" --unit "$UNIT" --state materialized \
     --target-ref "think-pr:$PR" --evidence "gate:$GATE" --evidence "pointer:$POINTER"
   ```

## Closeout — the one honest terminal status

Call the oracle, then finish the command contract. The final prose **quotes the oracle's command/reason
or names the open gate**; it never invents a different handoff:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_next_action.py" --repo "$PWD" --json
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" finish \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --command think \
  --status <complete|waiting_gate|blocked_external> --evidence-json '<envelope>'
```

- **`complete`** — the operator merged the Think PR. Evidence refs: `consideration:"pass"`, `think_pr`,
  `think_pr_state:"MERGED"`, `gate`, `gate_markers:1`, `gate_disposition:"disposed"`, `pointer`,
  `pointer_state:"admitted"`, and — for a `--doc` run — `intake_manifest:"<repo-rel>"` +
  `intake_selected:[<ids>]`. The closeout re-reads the manifest and enforces the **intake remainder**:
  every **selected** unit is `materialized` AND **every unselected expected unit** keeps a valid
  durable disposition (`queued`/`materialized`/`verified_done`/`ignored`) — a closeout that materializes
  one unit but drops the rest of the exact-once set is refused.
- **`waiting_gate`** — the Think PR is still OPEN (pending admission): same artifacts with
  `think_pr_state:"OPEN"`, `gate_disposition:"blocked"`, `pointer_state:"blocked"`.
- **`blocked_external`** — a deterministic helper failed: `blocker:{helper, exit (nonzero), diagnostic}`.

## Boundaries

Think authors **the consideration, the PRD, and the TRD** (on the Think PR, draft until merge),
opens the gate issue, and writes the consideration pointer — nothing else. Do **not** decompose,
write plans, edit the tracker beyond the gate issue + pointer, or touch source/tests — that is
Plan and Build. End by naming the Think PR + gate issue and the consideration's open questions;
once the operator merges the Think PR, the next stage is whatever the oracle above reports (`/idc:plan`,
or `/idc:autorun` to drain the whole pipe from the admitted consideration).
