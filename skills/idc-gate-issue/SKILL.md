---
name: idc-gate-issue
description: 'Use to fire IDC''s human gates — the one requirements-admission gate (Think''s end-of-Think Think PR; the Recirculator reuses it for a requirements-changing backflow; draft-until-merge), and the rare strategic operator-decision gate: a non-requirements GO/NO-GO modeled as a board state so the orchestrator never improvises one.'
---
# idc-gate-issue

The requirements gate. This is the **only requirements-admission gate** in IDC — everything else
flows autonomously and automerges when green (`WORKFLOW.md §2`). It fires when an idea's
**requirements** are admitted: a
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

TO APPROVE: merge the Think PR. Merge = admission — the idea enters the pipeline and Plan
decomposes it. (Closing this issue or commenting does NOT admit: the PRD/TRD live in the Think
PR and only merging it lands them.) To reject: comment what to change and leave the PR open.

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

**4 — Detect admission + unblock (sync now or on a later run).** Admission is **the Think PR
merging** — the single, durable block-clearing signal. A closed gate issue or an `approved`
comment is **not** admission: it records intent, but the PRD/TRD stay **draft until the Think PR
merges**, so a closed-but-unmerged gate must **not** unblock anything — else Plan/Autorun would
proceed against requirements that are still only draft in an open PR (the draft-until-merge
contract). `/idc:think` (in-session), `/idc:plan`, `/idc:recirculate`, and `/idc:autorun` re-check
open gates at the start of a run: `query` for `operator-action` issues and confirm the linked
**Think PR has merged**. Only once it has, for each thing the gate blocked: remove the blocks link
via the adapter and `setField` `Status=Todo`. The admitted consideration is now Plan's to
decompose; chained work builders claim on the next cycle. A gate whose Think PR is **not yet
merged** (still open, even if the issue was closed) → leave the chain `Blocked` and move on; the
run never waits on the operator.

## The strategic decision gate (the second gate type — `operator-decision`)

The requirements gate above is the only thing that **admits** an idea. But a run sometimes hits a
genuine **non-requirements** strategic GO/NO-GO — e.g. a proving-spike result that decides whether
to commit to an approach — that changes **no** PRD/TRD and so fits neither the requirements gate
nor any blocked-by structure. With no modeled slot the orchestrator **improvises** the prompt (the
autorun audit's Stops 1/2), and "an unmodeled-but-real gate is a gateway drug to improvised gates
everywhere." The `operator-decision` gate gives that decision a **real board slot** so the
orchestrator never has to invent one — it reports a board state, exactly as it reports a pending
Think PR (the no-ask invariant in `idc:idc-autorun` / `idc:idc-build`).

It is **not** an admission gate: it never lands a PRD/TRD, and it does **not** reuse the Think-PR
merge signal (there is no requirements diff to land). It reuses **only the existing tracker
operations** (`createTicket`, `setField`, `link`, `query`, `comment` — no seventh op; `WORKFLOW.md
§3.3` holds).

**What it carries.** A plain-terms GO/NO-GO an operator can decide from a phone:

```
TITLE: [operator-action] Decision — <one plain phrase: the GO/NO-GO being asked>

THE DECISION
<2–4 plain sentences: what is being decided and what each choice means downstream. No code, no
 jargon. e.g. "The two-store proving spike passed all 5 criteria. GO commits the campaign to the
 two-store rework; NO-GO keeps the single-store path.">

TO APPROVE (GO): add the `decision-approved` label to this issue (from the GitHub web UI on your
phone), or merge the linked decision-PR if one is attached. To reject (NO-GO): add
`decision-rejected` (or comment what to change). Adding the label / merging the decision-PR is the
admission signal — nothing else proceeds until then.

Decides: <the dependent issue ids this GO/NO-GO gates>
```

Label it `operator-action` (findable, and the autorun drain already skips `[operator-action]`
titles as non-build work) plus the `decision` marker that distinguishes it from a requirements gate.

**Procedure** (mirrors the requirements gate, different approval signal):

1. **Open the gate.** `createTicket` the decision issue with the body above; `setField`
   `Status=Todo` + the `operator-action` label. Optionally open a lightweight **decision-PR** (a
   one-line entry in a decisions log) when a durable artifact is wanted — its **merge** is then a
   second valid GO signal, identical in spirit to the Think-PR merge.
2. **Chain only its dependents.** For each issue this decision gates, `setField` `Status=Blocked` +
   `link kind=blocks` from the gate issue. Everything the decision does **not** gate is left alone
   and keeps flowing — the gate pauses *only its dependents*, never the whole pipe.
3. **Notify** the operator once (the push fallback below), with a "Decision needed" message. Never
   block the run on delivery.
4. **Detect the decision (fail-closed) + unblock.** The admission signal is an **explicit positive
   act**: the `decision-approved` label present on the gate issue, **or** the attached decision-PR
   merged. A **closed-but-unapproved** gate is **not** a GO — a bare close or a stray comment never
   unblocks (just as a closed-but-unmerged requirements gate never admits); absence of the explicit
   signal leaves the dependents `Blocked`, and the run **reports the pending decision and moves on,
   never waiting**. On a detected GO, for each gated dependent: remove the blocks link and `setField`
   `Status=Todo`. On a `decision-rejected` (NO-GO): drop or re-sequence the dependents per the
   operator's note via the adapter — never silently proceed. `/idc:autorun`, `/idc:build`, and
   `/idc:plan` re-check open `operator-decision` gates at the start of a run via `query`, the same
   way they re-check the requirements gate.

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

- Creates **exactly one** gate issue per gated event — one **requirements** gate per admission
  (chaining what is pending admission: the consideration pointer at Think; the requirements-affected
  work at the Recirculator), or one **`operator-decision`** gate per strategic GO/NO-GO (chaining
  only that decision's dependents). It does not create or modify any other issue.
- **Never edits canonical docs.** The PRD/TRD diff is authored upstream (by `/idc:think` or
  `/idc:recirculate`) and only referenced here; this skill writes the gate issue, not the PRD/TRD.
- **Never approves on the operator's behalf** — never merges the Think PR, never adds the
  `decision-approved` label or merges a decision-PR, never closes the gate itself. Approval is the
  operator's act; this skill only *detects* it and clears the resulting block.
- All tracker mutation goes through `idc:idc-tracker-adapter`; this skill holds no
  backend-specific logic.
