---
name: idc-gate-issue
description: 'Use to fire IDC''s one human gate — requirements admission. Think uses it at the end of Think to gate a new PRD+TRD on the Think PR; the Recirculator reuses it when backflow needs a requirements change. Supports sync-or-async approval and draft-until-merge.'
---
# idc-gate-issue

The requirements gate. This is the **only** gate in IDC — everything else flows autonomously and
automerges when green (`WORKFLOW.md §2`). It fires when an idea's **requirements** are admitted: a
**PRD** change (user-facing *what*, always gated while `gating.prd: on`) and/or a **TRD** change
(the technical *how* — the `spec` layer — gated when `gating.trd: on`). **Think** fires it at the
**end of Think** on the **Think PR**; the **Recirculator** reuses this **identical** mechanism when
backflow needs a requirements change. Nothing else in the system asks the operator for permission.

The gate has two coupled parts:

- **The Think PR** — an unmerged PR carrying the PRD/TRD draft. The requirements stay **draft until
  merge**: **merge = approval = admission** to the pipeline.
- **The gate issue** — a tracker-native `operator-action` issue carrying the plain-terms decision,
  so the operator can approve from the GitHub web UI on their phone, and so later runs can detect
  the approval without anyone watching the PR.

Approval is **sync or async**: the operator may approve in-session (merge now), or leave the Think
PR open and approve later (you, a teammate, or a coding agent reviewing on GitHub). A saved-but-
unapproved idea is just an open Think PR; nothing downstream proceeds until it merges.

## What the gate issue carries

A plain-terms decision an operator (a non-engineer) can make from a phone:

```
TITLE: [operator-action] Requirements change — <one plain phrase: what the app will do differently>

WHAT YOUR APP WILL DO DIFFERENTLY
<2–5 sentences in plain terms. No code, no file paths, no jargon. The user-facing
 behaviour change only — what someone using the product would notice.>

PROPOSED REQUIREMENTS CHANGE (PRD / TRD)
<the proposed PRD/TRD diff: inline fenced diff if short, else a link to the diff in the
 Think PR (or the recirculation PR)>

TO APPROVE: merge the Think PR (or close this issue / comment "approved"). Merge = admission —
the idea enters the pipeline and Plan decomposes it. To reject: comment what to change and
leave it open.

Gates: <the consideration pointer (at Think) or the affected work issues (at the Recirculator)>
```

Label it `operator-action` (the gate label) so it is findable. The body is plain terms +
the diff + a pointer to the Think PR — nothing else.

## Procedure (identical for Think and the Recirculator)

All tracker ops route through `idc:idc-tracker-adapter` (`createTicket`, `setField`,
`link`, `comment`, `query`) — **never hard-code github vs filesystem semantics**; the
adapter reads the backend from config and dispatches. An outside or cloud agent runs these
four steps over the plain tracker API.

**1 — Open the Think PR + the gate.** Open the (draft) Think PR carrying the PRD/TRD diff, then
`createTicket` the gate issue with the plain-terms body above; `setField` `Status=Todo` and the
`operator-action` label. One gate issue per admission, no matter how much it gates.

**2 — Chain what's pending.** Block what must wait on admission, via `setField` `Status=Blocked`
+ `link kind=blocks` from the gate issue:
- **At Think** — the **consideration pointer** (`Stage = Consideration`): it is pending admission
  while the Think PR is open.
- **At the Recirculator** — each affected work issue (the requirements-touching set only). Work
  from the same run that does **not** touch the requirements is left alone — it stays `Todo` and
  flows.
Record the chained ids in the gate body's `Gates:` line.

**3 — Notify the operator.** Send one push notification (see below). Never block the run on
delivery.

**4 — Detect approval + unblock (sync now or on a later run).** Approval is **the Think PR merging**
(the durable admission signal); a closed gate issue or an `approved` comment is an equivalent
manual signal. `/idc:think` (in-session), `/idc:plan`, `/idc:recirculate`, and `/idc:autorun`
re-check open gates at the start of a run: `query` for `operator-action` issues. When a gate is
**approved** (its Think PR merged, or the issue closed/`approved`), for each thing it blocked:
remove the blocks link via the adapter and `setField` `Status=Todo`. The admitted consideration is
now Plan's to decompose; chained work builders claim on the next cycle. A gate still open → leave
the chain `Blocked` and move on; the run never waits on the operator.

## Push notification (graceful no-op fallback)

Use whatever notification surface the environment provides, in this order, and **degrade
silently** — notification being unavailable must **never** fail the run:

1. A `cmux notify` CLI, if present on PATH — send a one-line "Requirements approval needed: <title>
   (gate issue #<n>)".
2. Otherwise a `PushNotification` tool/hook, if available in the harness.
3. Otherwise **no-op fallback**: log that the gate issue is open and awaiting the operator
   (issue id + title + "awaiting operator approval — merge the Think PR from the GitHub web UI"),
   and continue. The Think PR + gate issue are the durable signal; the next run still detects
   approval without any notification ever having been sent.

The operator merging the Think PR (or approving from the GitHub web UI) is the real mechanism; the
push is only a convenience nudge.

## Authority boundaries

- Creates **exactly one** gate issue per admission and chains what is pending admission behind it
  (the consideration pointer at Think; the requirements-affected work at the Recirculator). It does
  not create or modify any other issue.
- **Never edits canonical docs.** The PRD/TRD diff is authored upstream (by `/idc:think` or
  `/idc:recirculate`) and only referenced here; this skill writes the gate issue, not the PRD/TRD.
- **Never approves on the operator's behalf** and never merges the Think PR / closes the gate
  itself — approval is the operator's act. This skill only *detects* an approval and clears the
  resulting block.
- All tracker mutation goes through `idc:idc-tracker-adapter`; this skill holds no
  backend-specific logic.
