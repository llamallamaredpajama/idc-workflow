# 2026-07-19 — completion honesty: the failure record

The record `scripts/idc_finish_coherence.py` and `scripts/idc_live_check.py` both cite. Kept short on
purpose: the reasoning lives in those two files, next to the code it justifies.

## What happened

A governed repo reported a phase complete. Every PR was merged, every issue closed, every review
dimension green, the build lane empty. Two things were nonetheless true:

1. **Seven fully-merged, issue-closed items still showed `In Progress` on the board.** The finish tail
   merges the PR — which auto-closes the issue via the mandated closing keyword — several steps before
   it flips the board Status. A session dying in that window strands a shipped item at `In Progress`
   forever. Nothing downstream noticed: the acceptance check audits only merged-`Done` items, and the
   drain counts only `Todo`, so neither ever looked at them.
2. **The deployed app could neither ingest nor open an item.** Its buckets were never created and a
   runtime env var was never set. Neither appears in any reviewed diff, so no code gate could have
   caught it. The plan's own written finish line — drive the real signed-in app — was simply skipped.

The common root cause is one sentence: **the pipe's definition of "finished" was "the build lane is
empty"**, and "all PRs merged + reviewed" was read as "the product works".

## What was built (4.2.0)

Two fail-closed wave-close checks, wired onto the drain's existing non-terminal exit 4 — the code the
Stop fixpoint gate already refuses a stop on, so enforcement needed no new hook.

- `idc_finish_coherence.py` — *does the board still claim work that already shipped?* Reuses the
  janitor's existing coherence verdict rather than minting a second definition of it. Repairs go
  through the existing idempotent `--close-only` door; a hand-edited Status launders the journal.
- `idc_live_check.py` — *does the deployed product actually work?*

## The correction that mattered most

The live check shipped, in its first cut, requiring a **human** to drive the app and hand-write an
evidence note. The operator rejected it, correctly: an unattended overnight run would either stall
waiting for a person or wake one up at 2am — and an agent is perfectly capable of running a test
against a real deployment.

It was rebuilt so that **verification is executed, never attested**:

- the project declares a `verify:` **command** per surface (IDC never hardcodes a browser, an HTTP
  client, or a cloud SDK — the project owns the technology, so this stays portable);
- `idc_live_check.py --run` **executes** it at wave close and writes a machine-generated receipt
  (command, exit code, commit, timestamp, bounded credential-redacted output excerpt);
- the drain and the Stop gate **audit** that receipt read-only, so the stop path stays sub-second;
- a hand-written claim no longer satisfies the gate at all. The one escape hatch, `attested: true`, is
  for surfaces that genuinely cannot be automated and reports on its own `live: ok (attested)` line;
- a failing verify command is a **finding the pipeline works**, like a failing test — not a page.

Writing the verify script is ordinary build work for the implementing agent, and it must never print a
credential: the receipt is committed.

## What the tests are worth

`tests/smoke/phase4-completion-honesty.sh` — every guard was broken in the real source, one at a time,
and observed to turn the suite red (16 mutations for the original gates, 19 more for the executable
rebuild). Three honest exceptions are stated in that file's header rather than glossed. The discipline
paid immediately: the bounded-output test exposed a real hang — redaction ran over the whole capture
with an unbounded quantifier, so a verify script printing 400 KB wedged the gate for minutes *after*
its timeout could no longer save it.
