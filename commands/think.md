---
description: IDC Think — a free-form brainstorm/interview that emits a function-first consideration file
argument-hint: '"<topic-or-anchor-doc>" [--doc <path>] [--slug <name>]'
---

You are running `/idc:think`. This is the free-thinking front door of the IDC v2 pipeline:
a brainstorm/interview held **in this main session with zero durable workers**. You talk
with the operator and shape one **function-first consideration file**. Thinking stays free
— there are no gates, no teammates, no admission language here; the requirements gate (the PRD
always, the TRD when `gating.trd: on`) lives in Plan (`WORKFLOW.md §2`, `§4.1`).

Operator input: `$ARGUMENTS` — a topic, an anchor doc (`--doc <path>`), and/or a slug.

## How to run it

1. **Interview, don't lecture.** Draw the idea out: what should the product *do for the
   user*, how should it behave, what's in and out. A grill-me-style back-and-forth is
   welcome when the operator wants to stress-test the idea. Keep the operator in the loop;
   this is a conversation, not a delivery.
2. **Research on demand via bounded fan-out.** When a question needs the codebase or the
   web, send it to a throwaway subagent / Workflow fan-out (per the runtime adapter) and
   fold back the digest. **Never spawn a durable worker** and never let research stall the
   conversation — the budget here is zero teammates.
3. **Stay function-first.** Capture what the user gets and how it behaves, organized by
   domain where natural. Describe intended product function, not implementation tasks or a
   file plan. Note `PRD impact:` (does user-facing function change?) — and, where the technical
   approach shifts, the TRD/spec impact too — state them, do not act on them; Plan owns the gate
   (which covers the TRD only when `gating.trd: on`).

## Output

Write exactly one file: `docs/considerations/<YYYY-MM-DD>-<slug>-considerations.md`,
following `idc:idc-consideration-schema` (H1 title; Date/Status/PRD-impact metadata; a
"What this does for the user" function-first section; behavior by domain; Open questions for
Plan). Then validate it before finishing:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_consideration_check.py" \
  docs/considerations/<YYYY-MM-DD>-<slug>-considerations.md
```

Fix anything it flags (it requires the function-first section, the PRD-impact line, and an
Open-questions handoff) until it reports `PASS`.

## Boundaries

Write **only** `docs/considerations/`. Do not edit the PRD, specs, plans, the tracker, or
source. Do not declare scope admitted or recommend admission — that is Plan's seat. End by
naming the consideration file and its open questions; the next stage is `/idc:plan` (or
`/idc:autorun` to drain the whole pipe).
