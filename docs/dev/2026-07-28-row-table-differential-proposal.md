# Proposal — per-row outcome tables + a baseline↔final row differential for the validation contract

**Status: PROPOSAL, not adjudicated.** Written 2026-07-28 by an agent session working in
wildcat-jig, from evidence produced there the same night. Nothing here is authorized to build.
It is sequenced STRICTLY AFTER the verification-contract follow-up build finishes — the lead
session running in the main checkout against the 2026-07-27 kickoff, with writer worktrees
`idc-workflow-p2a` / `-p2b` / `-part3`. `p2b` in particular has uncommitted edits to
`scripts/idc_validation_contract.py`, spec §3.4, `agents/idc-implementer.md`,
`agents/idc-finisher.md`, `commands/build.md`, `commands/doctor.md`, and the `build-*` governance
tests (re-checked 2026-07-28 late). Wait for ALL parts plus the #184 follow-ups to land, then
re-ground: every file:line below was read at `main` @ `6c1254c` and WILL have moved (unit U-R0).

## The incident this generalizes (wildcat-jig #48, 2026-07-28)

A canary error classifier was mislabeling generic local crashes as provider-side problems —
worst case: `disk quota exceeded while writing scratch file` (out of disk on the operator's
machine) reported as "provider access unavailable", exit "not our bug". The fix that landed is
trustworthy for one reason: it was measured, not eyeballed.

- A 49-row fixture table (23 crash lines, 26 provider lines, each row commented with why it
  exists) was run against the UNCHANGED classifier first: 26 of 49 rows wrong. Red proven,
  baseline recorded.
- After implementation the WHOLE table was re-run — not just the rows the fix targeted. That
  re-measurement caught that the planned fix would have flipped three benign crash lines
  ("expired tokens purged from the cache", "no api-key rotation policy configured",
  "missing credentials.json fixture") into the exact false-BLOCKED class the fix existed to
  close. The plan was corrected before landing.
- A tried-and-rejected regex variant left its counterexamples pinned as permanent table rows.
- The commit message carries the numbers: 26/49 before, 0 after, sibling tables (34 FAIL + 20
  BLOCKED rows) untouched and green.

The transferable lesson: **an agent's plan is a hypothesis; a per-row table measured before and
after is the referee.** Aggregate green/red is not enough — the three would-be leaks were only
visible row-by-row.

## Where IDC's validation contract stops short of this today

IDC already enforces the hard part (spec §3.4; `idc_validation_contract.py` freeze/run;
`build-validation-baseline.sh`): frozen gate, declared `expected-red`/`expected-green` baseline,
refusal on unexpected-green, re-run at final head, receipts bound to the exact diff. Two gaps
remain, both at row granularity (readings at `6c1254c`; re-verify in U-R0):

1. **The baseline is one aggregate boolean.** `_baseline_state`
   (`scripts/idc_validation_contract.py:737-738`) returns `expected-green` iff ALL verify
   commands exit 0, else `expected-red`. A contract whose surface has three already-green
   commands and two red ones collapses to `expected-red`; the three green rows are never pinned,
   so a regression in them during implementation is invisible to freeze/run.
2. **The stored baseline is never consumed.** `run_contract` re-executes the commands and emits
   an aggregate `result: pass|fail` (`:958`) but never compares row-by-row against
   `contract["baseline"]["results"]`, which the freeze already stores (`:883-887`). The data for
   a differential exists; nothing reads it.

(Adjacent but NOT this proposal: behavioral collateral lives only as prose today — `CONSTRAINTS`,
"existing suite green" — while `idc_build_receipt.py` checks collateral as PATHS. The design below
gets the minimal behavioral version for free via collateral rows, without new machinery.)

## Design (minimal, inside the standing constraints)

**Naming discipline:** the new primitive is called the **outcome table** and the **row
differential** — deliberately NOT "baseline table", because `baseline` already means two things
here (validation baseline vs. `idc_reconciliation_baseline.py`'s adoption baseline).

1. **Per-row expectation at freeze.** Each verify command row may declare `expect: red|green`.
   Freeze executes every row (as today) and refuses when any row's actual state differs from its
   declaration, naming the row — generalizing the existing aggregate `unexpected-green baseline
   refusal` (`:851-854`), which remains as-is for contracts that declare no per-row expectations.
   Backward compatible: a contract without `expect` fields behaves byte-for-byte as today.
2. **Row differential at run.** After the final-head execution, compare per row against the
   frozen baseline results: every `expect: red` row must now be green (the fix worked), every
   `expect: green` row must still be green (no collateral regression). Any other transition fails
   the run and the receipt names the exact rows — the same "exact failures back to the same Build
   attempt record" shape the loop already uses. This is the machine-enforced version of the catch
   that saved #48.
3. **Collateral rows at Plan.** `agents/idc-plan.md` Phase 3 guidance: when a goal touches what
   code accepts, rejects, or classifies, the authored contract includes at least one
   `expect: green` collateral row (e.g. the targeted sibling suite). Mechanically it is just a
   row; the differential does the rest.
4. **Fail-closed collateral floor at freeze.** A contract declaring any `expect: red` row is
   REFUSED at freeze unless it also declares at least one `expect: green` row or an explicit
   `no_collateral_reason` field (the `skip_reason` idiom: fail closed, escape by named reason
   that lands in the frozen contract and its receipts). Without the floor, the differential's
   collateral protection is optional exactly when it matters; with it, the #48-style catch is the
   default and skipping it is a visible, attributable decision. This floor is deliberately NOT
   left as advisory guidance — advisory was the first draft of this proposal, and it was the one
   watered-down piece.

**Explicitly out of scope / already owned elsewhere — do not fold in:**
- Risk-gate digest binding (F64-binding) — tracked in issue #184; different mechanism.
- Gate quality at Plan (the research doc's "gate tests the right thing" ceiling) — the outcome
  table makes gates more expressive; it does not judge them.
- A per-ticket runtime `/verify` stage — explicitly rejected in
  `docs/dev/2026-07-23-verification-contract-research-recommendations.md:199-202`.
- No new top-level workflow stage, no model-authored validators, no WORKFLOW.md renumbering
  (at most one sentence inside §3.2's VERIFICATION SURFACE element, operator's call).

## Units

**U-R0 — re-grounding sweep (read-only; the Part-0 idiom).** After p2b merges: re-read
`idc_validation_contract.py` (line anchors above WILL have moved), spec §3.4, and the three
`build-*` governance tests; confirm no landed unit already added per-row expectations (as of
2026-07-28, `rg -i "per-row|row-by-row|truth table|per-command"` over the three controlling
docs/dev work orders returns nothing); output the triage table.

**U-R1 — freeze: outcome table + per-row refusal.** Governance test FIRST
(`tests/smoke/governance/build-validation-row-table.sh`, auto-discovered, zero registration):
(a) a declared-red row that is actually green at freeze → refusal naming the row;
(b) a declared-green row that is actually red at freeze → refusal naming the row;
(c) a legacy contract with no `expect` fields → behavior identical to today's, including the
aggregate refusal string;
(g) a contract with `expect: red` rows, zero `expect: green` rows, and no `no_collateral_reason`
→ refusal naming the missing floor;
(h) the same contract WITH `no_collateral_reason` → freeze proceeds and the reason appears in the
frozen contract bytes. Then implement. Every new guard gets a red-when-broken receipt per the
standing rules (`docs/dev/2026-07-27-followup-build-kickoff.md:92-98`), each probe under an
explicit per-case `timeout`, timeout treated as RED.

**U-R2 — run: the row differential.** Same test file, cases:
(d) a frozen-green row red at final head → run fails, receipt names the row;
(e) a declared-red row still red at final head → run fails, receipt names the row;
(f) all rows land in their declared final state → pass, receipt records per-row transitions.
Implement by consuming the already-stored `baseline.results`.

**U-R3 — prose, same PR as the code it describes.** Spec §3.4 loop amended (per the standing
rule that spec text updates ride the implementing PR); `agents/idc-plan.md` Phase 3 collateral-row
guidance, including the floor's escape semantics and one sentence that a row which killed an
attempted approach stays in its test file permanently (cross-ticket pinning);
`agents/idc-implementer.md` step 2 one-line mention that the frozen gate's re-run is
row-differential. Optional, operator's call: one sentence in `templates/WORKFLOW.md` §3.2 (no
renumbering) and promoting the red-when-broken receipt rule from the (untracked) work order into
the spec so it outlives the work order.

## Gates and receipts

- `bash scripts/lint-references.sh` · `bash tests/smoke/run-all.sh` · `bash scripts/run-evals.sh`
  all exit 0; PR CI green at the exact final head. Environment traps apply (prepend
  `/opt/homebrew/bin` to PATH; run suites from `cd "$(pwd -P)"`).
- E2E receipt: one sandbox freeze → implement → run round-trip in which a collateral
  `expect: green` row is deliberately regressed and the run names it at final head. Unit tests
  alone are not done.
- Workflow pattern: as in the 2026-07-27 kickoff — feature branch, one PR, dual independent
  fresh reviews in disposable clones re-running the evidence, one consolidated fix commit per
  round, hard cap of 2 rounds. Release lockstep prepared (plugin.json + marketplace.json +
  CHANGELOG), not published.

## Considered and rejected (so nobody re-litigates silently)

- **Comparing row OUTPUT (stdout hashes) instead of exit codes.** Rejected: outputs carry
  timestamps, paths, and ordering noise; a hash differential would red on noise and train people
  to ignore it. Exit-code-per-row is the honest deterministic primitive here; content-level
  pinning belongs inside the test the row runs.
- **Model-judged row verdicts.** Violates the fixed-validators law; a PASS string is already
  "never sufficient evidence" (spec §3.4).
- **A weaker, advisory-only collateral rule.** Rejected above (design item 4) — that was the
  watered-down version.
- **Wildcat's clause "rejected variants pin their counterexamples" as new contract machinery.**
  Not needed as machinery: within a ticket, the freeze already makes rows immutable (the builder
  cannot delete an inconvenient row), which is that clause enforced. ACROSS tickets, the pinning
  belongs in the test files the rows execute — U-R3's Plan guidance gets one sentence saying a
  row that killed an attempted approach stays in the test file permanently.

## Decisions the operator owns before any build

1. Adopt at all? (This doc is a proposal from outside the repo's own adjudication loop.)
2. Field name: `expect` vs `expected_outcome` (schema-visible, worth one deliberate choice).
3. The collateral floor's escape hatch: field name `no_collateral_reason`, and whether review
   treats its use as a finding to justify (recommended: yes, like `skip_reason`).
4. The two optional U-R3 prose items (WORKFLOW.md §3.2 sentence; red-when-broken promotion).

Provenance: wildcat-jig commit `733b02f` (#48) is the worked example; its commit message carries
the full measurement narrative. Cross-checked against issue #184 and the three controlling
docs/dev work orders on 2026-07-28 — no overlap found.
