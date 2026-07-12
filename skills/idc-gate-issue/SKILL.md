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

<!-- idc-gate-pr: <the Think PR number> -->
```

Label it `operator-action` (the gate label) so it is findable. The body is plain terms + the diff +
a pointer to the Think PR, plus a hidden **`<!-- idc-gate-pr: <PR#> -->`** marker naming the gate's
approval PR (github) — nothing else. That marker **binds** the approval artifact to *this* gate: the
engine's guarded `dispose --disposition gate-approved` close mints `Done` only when the gate's own
recorded PR has merged, so an unrelated merged PR can never terminalize an unapproved gate.

## Procedure (identical for Think and the Recirculator)

All tracker ops route through `idc:idc-tracker-adapter` (`createTicket`, `setField`,
`link`, `comment`, `query`) — **never hard-code github vs filesystem semantics**; the
adapter reads the backend from config and dispatches. An outside or cloud agent runs these
four steps over the plain tracker API.

**1 — Open the Think PR + the gate.** Open the (draft) Think PR carrying the PRD/TRD diff, then
`createTicket` the gate issue with the plain-terms body above; `setField` `Status=Todo` and the
`operator-action` label. On **github**, stamp the gate body's `<!-- idc-gate-pr: <PR#> -->` marker
with the just-opened Think PR number — the engine's guarded `dispose --disposition gate-approved`
close binds approval to that recorded PR. One gate issue per admission, no matter how much it gates.

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
**Think PR has merged**. Only once it has: **first close the gate** through the engine's guarded
`dispose --disposition gate-approved --num <gate#>` — it re-verifies the gate's own recorded
approval artifact (the merged `idc-gate-pr`) before minting `Done`, so the close *records* the
operator's approval rather than *being* it. Then, **only after the dispose succeeds**, for each
thing the gate blocked: remove the blocks link via the adapter and `setField` `Status=Todo`.
**Never unblock first**: the guarded dispose IS the validation — an approval revoked between
detection and the dispose would otherwise leave already-unblocked dependents proceeding with no
current approval; a refused dispose leaves the chain `Blocked`. And dispose-first must not strand
dependents: if a prior run's dispose succeeded but was interrupted before the unblock — a `Done`
gate with still-`Blocked` dependents — the start-of-run re-check finishes the job. But a `Done`
gate does **not** by itself prove the guarded dispose ran: a legacy/manual close, a raw `Status`
edit, or a janitor repair also mint `Done` — and unblocking a raw-closed **requirements** gate
whose Think PR never merged would admit **draft** requirements. So the recovery **first verifies
the gate's journaled guarded dispose** — the `op=dispose`, `disposition=gate-approved` audit line
the guarded door always writes, naming that gate (re-dispose is NOT a clean re-proof: the terminal
op has no already-terminal guard, so it re-closes and DOUBLE-journals — the journal record is the
authoritative proof). Verify deterministically (archive-aware + lock-safe; per candidate gate
`$gate`):

```bash
python3 - "${CLAUDE_PLUGIN_ROOT}/scripts" "$gate" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import idc_journal_replay as RP
gate = int(sys.argv[2])
entries, err = RP.scan_journal_strict(os.path.join(os.getcwd(), RP.JOURNAL_REL))
if err:
    raise SystemExit(f"UNPROVEN: journal unreadable ({err}) — do not unblock")
print("PROVEN" if any(e.get("op") == "dispose" and e.get("disposition") == "gate-approved"
                      and RP.journal_item_id(e) == gate for e in entries) else "UNPROVEN")
PY
```

`PROVEN` → the gate's guarded dispose landed; `query` its still-`Blocked` dependents and finish the
unblock through the engine's journaled `unblock`. `UNPROVEN` → the gate's `Done` is not backed by a
guarded dispose: **leave the dependent `Blocked` and surface the anomaly** (the gate reached `Done`
outside the guarded door — confirm the approval, e.g. its Think PR merged, before any manual
unblock). That recovery is wired deterministically: `/idc:autorun`, `/idc:plan`, and
`/idc:recirculate` carry the Blocked-scan step (verify-the-journaled-guarded-dispose, then unblock),
and `/idc:doctor` Row 9's board-lint tiers a remaining strand — `stranded-gate` when the guarded
dispose IS journaled (safe to finish the unblock), `unproven-gate-done` when it is not (do **not**
auto-unblock). (A **legacy** gate created before the
`idc-gate-pr` marker existed — no marker in its body — must first be **migrated**: stamp its
`<!-- idc-gate-pr: <PR#> -->` marker **in the gate BODY** (a one-line body edit) with the Think PR
you confirmed merged, then dispose. The marker MUST live in the body: the gate body has no adapter
door (createTicket stamps it, `setField`/`comment` cannot edit it), so a body marker IS the gate's
own record; a **comment** is any adapter caller's door, so the engine **refuses** a gate whose only
`idc-gate-pr` marker rides a comment (codex round-14 P2 — the old comment-migration cross-check was
forgeable and is removed). Exactly **one** marker binds: a second marker in the body — e.g. one
embedded in an inline PRD/TRD diff before the canonical footer — fails the dispose closed, so an
embedded marker naming an already-merged PR can never bind while the real Think PR stays open (codex
round-14 P1). A caller-supplied `--gate-pr` alone can never approve a gate — it is only a confirming
cross-check of the gate's own recorded body marker, so approval stays bound to *this* gate.) The admitted consideration is now
Plan's to decompose; chained work builders claim on the next cycle. A gate whose Think PR is **not
yet merged** (still open, even if the issue was closed) → leave the chain `Blocked` and move on; the
run never waits on the operator (and `dispose --disposition gate-approved` would refuse it anyway —
fail-closed).

**Backend note.** The Think PR is a **github** artifact; on the **filesystem** backend the admission
signal is instead the gate issue's `Status` moved to `Done` — see *Approval signal by backend* below
(detection and the fail-closed posture are otherwise identical).

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
titles as non-build work) **plus a `decision` label** that pairs with `decision-approved` as the GO
signal. The gate's **kind**, though, is its producer-stamped **title**: the engine treats only a
gate titled `[operator-action] Decision — …` as an operator-decision gate — the title, like the
body, has no adapter door, while labels are any caller's, so labels can never *retype* a
requirements gate into a decision gate. Keep the `Decision — ` title prefix exactly; it is
load-bearing. The engine's `dispose --disposition gate-approved` accepts label approval **only** on
a decision-TITLED gate carrying the full `decision`+`decision-approved` pair — no label pair can
ever approve a *requirements* gate (which admits only via its merged Think PR). If a **decision-PR**
is attached instead of a label, stamp the gate body's `<!-- idc-gate-pr: <decision-PR#> -->` marker
so the engine binds approval to that PR's merge.

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
   never waiting**. On a detected GO: **first close the decision gate as a journaled cleanup** via
   `dispose --disposition gate-approved --num <gate#>` — it re-verifies the GO artifact (the merged
   `idc-gate-pr` decision-PR, or the `decision`+`decision-approved` label pair on this
   decision-titled gate) before minting `Done`. Then, **only after the dispose succeeds**, for each
   gated dependent: remove the blocks link and `setField` `Status=Todo` — never unblock first, so a
   GO revoked between detection and the dispose (label pulled, `decision-rejected` added) can never
   leave dependents unblocked; the same interrupted-run recovery applies (a `Done` gate with
   still-`Blocked` dependents → finish the unblock on the next re-check). On a
   `decision-rejected` (NO-GO): drop or re-sequence the dependents per the
   operator's note via the adapter — never silently proceed. `/idc:autorun`, `/idc:build`, and
   `/idc:plan` re-check open `operator-decision` gates at the start of a run via `query`, the same
   way they re-check the requirements gate. **Backend note:** the `decision-approved` label and the
   decision-PR are **github** signals; on the **filesystem** backend the GO signal is the gate
   issue's `Status` moved to `Done` (see *Approval signal by backend* below), fail-closed the same way.

## Approval signal by backend (github vs filesystem)

The four-step procedure is **identical on both backends** — only the *approval signal* the operator
emits, and how step 4 detects it, is backend-specific, because the durable requirements artifact is
backend-specific:

| Backend | Requirements gate (admission) | Strategic `operator-decision` gate (GO) |
|---|---|---|
| `github` | the **Think PR merges** | the **`decision-approved` label** on the gate issue, or the attached **decision-PR merges** |
| `filesystem` | the operator moves the **gate issue's `Status` to `Done`** | the operator moves the **gate issue's `Status` to `Done`** |

On the **filesystem** backend a repo has **no PRs and no labels**, so the github merge/label signals
cannot exist — without a portable signal a filesystem gate's dependents would stay `Blocked` forever.
The portable signal is the operator flipping the gate issue to `Done`, and that Done-move routes
through the engine's guarded terminal door —
`idc_transition.py --backend filesystem … dispose --disposition gate-approved --num <gate#>` —
which confirms the item is a genuine `[operator-action]` gate, mints `Done`, and journals the
disposition (so the janitor's board↔journal reconciliation stays clean). This is the explicit,
durable operator act that the Think-PR merge /
`decision-approved` label is on github; step 4's **fail-closed posture is unchanged** — anything less
than the gate issue being `Done` leaves the chained dependents `Blocked`, and the run **reports the
pending gate and moves on, never waiting on the operator**.

> **Why the divergence is intentional, not an inconsistency.** On github, *closing* the gate issue is
> explicitly **not** admission — the PRD/TRD only land when the PR merges, so a closed-but-unmerged
> gate must not unblock. On filesystem there is no separate PR to merge, so the gate issue reaching
> `Done` **is** the admission (the drafted PRD/TRD are already committed in the working tree). Each
> backend realizes the **same** contract — *an explicit, durable operator act, fail-closed until
> present* — with the only signal that backend can represent, realized through the engine's guarded
> terminal door (`dispose --disposition gate-approved`, the same tier as the verdict-guarded
> `close`), not a new tracker interface op (no labels, no PRs on filesystem; **no seventh core op**;
> `WORKFLOW.md §3.3` holds).

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
  `decision-approved` label or merges a decision-PR. Approval is the operator's act; this skill only
  *detects* it, closes the gate as a **journaled cleanup** via the guarded `dispose --disposition
  gate-approved` op — which **re-verifies the operator's own approval artifact** before minting
  `Done` — and only then clears the resulting blocks. The close *records* approval, and can never
  *be* it (a gate with no merged approval artifact is refused, fail-closed, and its dependents stay
  `Blocked`).
- All tracker mutation goes through `idc:idc-tracker-adapter`; this skill holds no
  backend-specific logic.
