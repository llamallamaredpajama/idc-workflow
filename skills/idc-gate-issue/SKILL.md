---
name: idc-gate-issue
description: 'Use when Plan or the Recirculator determines the PRD (user-facing product function) must change and the affected work must be gated behind one operator approval.'
---
# idc-gate-issue

The PRD gate. This is the **only** gate in IDC v2 — everything else flows autonomously and
automerges when green (`WORKFLOW.md §2`). It fires **only** when user-facing product function
changes, i.e. the PRD must change. Both `/idc:plan` and `/idc:recirculate` use this **identical**
mechanism; nothing else in the system asks the operator for permission.

The gate is **tracker-native**: one gate issue carries the human decision; every affected
work issue is chained `Blocked` behind it by native blocked-by; the operator approves from
the GitHub web UI on their phone; approval clears the block and builders pick the work up on
the next claim cycle. Non-PRD work from the same run is **never chained** — it flows through
untouched.

## What the gate issue carries

A plain-terms decision an operator (a non-engineer) can make from a phone:

```
TITLE: [operator-action] PRD change — <one plain phrase: what the app will do differently>

WHAT YOUR APP WILL DO DIFFERENTLY
<2–5 sentences in plain terms. No code, no file paths, no jargon. The user-facing
 behaviour change only — what someone using the product would notice.>

PROPOSED PRD CHANGE
<the proposed PRD diff: inline fenced diff if short, else a link to the PRD diff in
 the planning/recirculation PR>

TO APPROVE: close this issue (or comment "approved"). That unblocks the work below and
builders start on the next cycle. To reject: comment what to change and leave it open.

Blocks: <the chained work issues>
```

Label it `operator-action` (the gate label) so it is findable. The body is plain terms +
the diff — nothing else.

## Procedure (identical for Plan and the Recirculator)

All tracker ops route through `idc:idc-tracker-adapter` (`createTicket`, `setField`,
`link`, `comment`, `query`) — **never hard-code github vs filesystem semantics**; the
adapter reads the backend from config and dispatches. An outside or cloud agent runs these
four steps over the plain tracker API.

**1 — Open the gate.** `createTicket` with the plain-terms body above; `setField`
`Status=Todo` and the `operator-action` label. One gate issue per run, no matter how many
work issues it gates.

**2 — Chain the dependents.** For each affected work issue (the PRD-touching set only):
`setField` `Status=Blocked`, then `link kind=blocks` from the gate issue to that issue
(the work issue is blocked-by the gate). Record the chained ids in the gate body's
`Blocks:` line. Issues from the same run that do **not** touch the PRD are left alone —
they stay `Todo` and flow.

**3 — Notify the operator.** Send one push notification (see below). Never block the run on
delivery.

**4 — Detect approval + unblock (on a later run).** `/idc:plan`, `/idc:recirculate`, and
`/idc:autorun` re-check open gates at the start of a run: `query` for `operator-action`
issues. When a gate is **closed** (or carries an `approved` comment), for each issue it
blocked: remove the blocks link via the adapter and `setField` `Status=Todo`. Builders
claim them on the next cycle. A gate still open → leave the chain `Blocked` and move on;
the run never waits on the operator.

## Push notification (graceful no-op fallback)

Use whatever notification surface the environment provides, in this order, and **degrade
silently** — notification being unavailable must **never** fail the run:

1. A `cmux notify` CLI, if present on PATH — send a one-line "PRD approval needed: <title>
   (gate issue #<n>)".
2. Otherwise a `PushNotification` tool/hook, if available in the harness.
3. Otherwise **no-op fallback**: log that the gate issue is open and awaiting the operator
   (issue id + title + "awaiting operator approval from the GitHub web UI"), and continue.
   The gate issue itself is the durable signal; the next run still detects approval without
   any notification ever having been sent.

The operator approving from the GitHub web UI is the real mechanism; the push is only a
convenience nudge.

## Authority boundaries

- Creates **exactly one** gate issue per run and chains the PRD-affected work issues behind
  it. It does not create or modify any other issue.
- **Never edits canonical docs.** The PRD diff is authored upstream (by `/idc:plan` or
  `/idc:recirculate`) and only referenced here; this skill writes the gate issue, not the PRD.
- **Never approves on the operator's behalf** and never closes the gate itself — approval is
  the operator's act in the GitHub web UI. This skill only *detects* an approval and clears
  the resulting block.
- All tracker mutation goes through `idc:idc-tracker-adapter`; this skill holds no
  backend-specific logic.
