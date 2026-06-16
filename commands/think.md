---
description: IDC Think — brainstorm an idea, crystallize it into a PRD+TRD draft, and fire the one gate at the end on the Think PR
argument-hint: '"<topic-or-anchor-doc>" [--doc <path>] [--slug <name>]'
---

You are running `/idc:think`. This is the front door of the IDC pipeline — and (v3) its **one
human gate**. Thinking starts free: a brainstorm/interview held **in this main session with zero
durable workers**. You talk with the operator and shape one **function-first consideration**, then
**crystallize it into a PRD + TRD draft** and **fire the single gate at the end of Think** by
opening the **Think PR** (`WORKFLOW.md §2`, `§4.1`). Admission to the pipeline is the operator
merging that PR.

Operator input: `$ARGUMENTS` — a topic, an anchor doc (`--doc <path>`), and/or a slug.

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
   consideration pointer (`Stage = Consideration` — open Think PR / pending admission). Approval
   is **sync or async**: the operator may approve in-session, or leave the PR open and approve
   later from the GitHub web UI (you, a teammate, or a coding agent). **Merge = approval =
   admission.** Until then the requirements stay draft and nothing downstream proceeds.

## Boundaries

Think authors **the consideration, the PRD, and the TRD** (on the Think PR, draft until merge),
opens the gate issue, and writes the consideration pointer — nothing else. Do **not** decompose,
write plans, edit the tracker beyond the gate issue + pointer, or touch source/tests — that is
Plan and Build. End by naming the Think PR + gate issue and the consideration's open questions;
once the operator merges the Think PR, the next stage is `/idc:plan` (or `/idc:autorun` to drain
the whole pipe from the admitted consideration).
