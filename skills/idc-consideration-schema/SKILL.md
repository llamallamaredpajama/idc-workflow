---
name: idc-consideration-schema
description: 'Use when authoring or validating a /idc:think consideration file — the function-first, Plan-ready shape and its mechanical check.'
---
# idc-consideration-schema

The shape of a consideration — `/idc:think`'s function-first output (`WORKFLOW.md §4.1`). A
consideration describes what the code should do for the user and how it behaves, organized by
domain where natural. It is heavily PRD-shaped (intended product function, not implementation
tasks). In v3 Think **crystallizes** the consideration into a **PRD + TRD draft** and fires the one
gate at the end of Think (the Think PR), so the consideration declares **both** the user-facing
*what* (`PRD impact`) and the technical *how* (`TRD impact`) it drives.

## Required shape

```
# <topic> — Consideration

- Date: <YYYY-MM-DD>
- Status: Active
- PRD impact: <yes|no> — <one plain phrase on whether user-facing function changes>
- TRD impact: <yes|no> — <one plain phrase on whether the technical approach changes>

## What this does for the user
<plain, function-first description — what someone using the product gets and notices>

## Behavior by domain
<how it behaves, grouped by the touched domains where natural>

## Open questions
<unresolved decisions handed to Plan>
```

Function FIRST: lead with user-facing function, not a task list or file plan. The
`PRD impact` and `TRD impact` lines name the requirements the consideration drives — Think
crystallizes them into the gated PRD + TRD draft and fires the one gate at the end of Think.

## Mechanical check

Validate a consideration with the shipped checker (standard-library Python, no deps):

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_consideration_check.py" docs/considerations/<file>.md
```

It is a lean guardrail — it requires only the load-bearing essentials and exits non-zero
with a reason list when any are absent:

1. an H1 title;
2. a function-first section (a heading mentioning the user or the function);
3. a `PRD impact:` statement;
4. a `TRD impact:` statement;
5. an `Open questions` section.

`/idc:think` runs this on its emitted file before finishing; `/idc:plan` may re-run it on
intake. It checks structure, not prose quality.

## Authority boundaries

- Describes + validates the consideration shape only. Never writes the PRD or any canonical
  doc, never admits scope, never spawns teammates.
