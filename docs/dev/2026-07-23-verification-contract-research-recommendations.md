# Research → IDC mapping: divergent test discovery, surface-typed verification, graph doctrine

- **Date:** 2026-07-23
- **Status:** Handed off — Recommendations 1–4 were injected into the pathway-integrity
  implementation run on 2026-07-23 (while it was on its U7 unit). This document is the detailed
  reference that run was told to read; do **not** re-propose or re-inject 1–4. Recommendation 5 and
  the optional Think pass remain here as documentation only. See *Disposition* at the end.
- **Companion to:** `docs/specs/idc-convergent-pathway-integrity-spec.md` (the pathway-integrity
  spec now being implemented; the run had reached U7 at injection time — the shared Path Gate,
  U4/PR #171, preceded it). The prior
  research pass mapped Fusion Harness onto **Build** as §3.4's ticket validation contract +
  auto-validation loop. This pass maps three further inputs and finds the highest-leverage site is
  **Plan Phase 3 — the authoring of the verification/validation contract** — plus four smaller,
  precisely-placed improvements.

## Inputs

| Input | Where it lives | One-line content |
|---|---|---|
| ADHD skill (divergent test discovery) | Research Wiki `wiki/youtube-m6IXL_YGqBQ-…` + Udit Akhouri's `adhd` repo | Isolated, differently-framed ideation branches propose non-obvious test strategies / product risks; a critic scores novelty, viability, fit; output is a strategy, never proof. |
| `/verify` skill (runtime-observation verification) | Research Wiki `wiki/youtube-XLA-sTSJ-Wc-…` + Piebald-AI snapshot of Claude Code's verify skill | Proof = driving the changed code at the surface a user actually meets (CLI/API/GUI/library/agent/CI), capturing that surface's native evidence; tests/typecheck are explicitly *not* verification; missing infrastructure is a named BLOCKED, never a lowered claim; the working drive recipe is persisted per-repo so the next run skips the cold start. |
| Graph engineering course | Research Wiki `wiki/youtube-QRh1a5qvm9U-…` | Nodes = schema-contracted bounded jobs; edges = data contracts; deterministic code owns routing/reduction; verifiers on edges (adversarial, perspective-diverse, judge panel); loops converge only when deduped against everything **seen**; pipeline over barrier; cheap models for bounded work. |

## Why Plan's contract authoring is the highest-leverage site

The auto-validation loop already specified for Build (§3.4) guarantees the frozen gate **runs**,
was **red before implementation**, and is **re-run against the final diff**. What it cannot
guarantee is that the gate tests the **right thing**. That ceiling is set at Plan, where the
contract is authored. Two repeated local findings confirm this is the live weakness, not a
hypothetical: the 4.2.0 desk review's sharpest catch was *a fix validated by a fixture the old
code already handled*, and the standing operator rule is *a green test proves nothing until shown
to fail when its guard breaks*. Both are authoring-quality failures — exactly the layer none of
the already-specified machinery (Path Gate, tracker transactions, receipts, frozen gates)
touches. The three inputs each strengthen a different aspect of that layer, and they compose.

Areas considered and ranked: Think (secondary — divergent product-risk discovery is useful but
sits behind a human gate that already catches requirement gaps), Build (already served by §3.4;
additions here are evidence-shape rules, not new loop mechanics), the review engine
(already perspective-diverse across 13 dimensions; gains a deterministic rule and a ledger),
Janitor/Recirculator (gains the convergence dedupe rule), Autorun (no change).

---

## Recommendation 1 — Surface-typed validation contracts *(from `/verify`; amend spec §3.4)*

Add two declarative fields to the §3.4 validation-contract schema:

```yaml
surface: cli | api | gui | library | agent | ci | none   # where a user/system meets the change
evidence_kind: pane-capture | response-body | screenshot-or-recording |
               public-import-sample | agent-run-capture | check-run | none
```

with the pairing fixed by a table (GUI → screenshot/recording, API → request+response body, CLI →
command+pane capture, library → sample through the *public* export, agent config → a real agent
run, CI workflow → a dispatched run). Enforcement is deterministic and cheap:

- `idc_schema_check.py` (or the new fixed contract validator) rejects a contract whose declared
  gate commands cannot produce the declared `evidence_kind` — the existing "all-static surface"
  FAIL generalizes from prose judgment into a rule.
- The §3.5 receipt for the gate run must carry the declared evidence kind, bounded and redacted.
  A GUI ticket whose acceptance evidence is a unit-test exit code becomes machine-refusable
  rather than a reviewer judgment call.
- `surface: none` is the honest SKIP: docs-only / types-only / config-with-no-behavioral-diff
  tickets declare it with a one-line justification instead of padding a fake test. This closes
  the opposite failure (inert padding) at zero cost and matches the goal-contract skill's
  existing "never pad a simple pillar."

This is a strictness increase over today's standard (prose rule → machine rule), flagged per the
match-existing-standard policy — but it is the same rule the review engine already fails PRs on,
so it tightens enforcement of an existing standard rather than inventing a new one.

## Recommendation 2 — A per-repo verification-handle registry *(from `/verify`'s "persist the handle"; amend spec §3.4 + §4.2)*

`/verify`'s most operational idea: the first session to figure out how to build/launch/drive a
surface **persists the recipe** so every later session skips the cold start. IDC's equivalents
are fragmented: `WORKFLOW-config.yaml::live_verification` covers deployed surfaces only, and
"existing verification commands to reuse" (§3.4) has no defined place to live, so each Plan run
re-derives it and each Build triplet risks minting a redundant script — the exact failure the
spec's pilot-acceptance list worries about ("the common ticket reuses its existing tests without
generating a redundant script").

Add one governed registry (e.g. `docs/workflow/verification-handles.yaml`), one entry per
surface: how to build, launch, and drive it; required fixtures/accounts/emulators; the proven
commands. Then:

- **Plan** resolves "existing verification commands to reuse" by lookup, citing the entry id in
  the validation contract. No entry + no in-repo test proving the goal → the contract's gate is
  authored fresh (§3.4 step 2, unchanged).
- **Build** appends newly-proven recipes back to the registry as part of finish (the same
  compounding move as `/verify` writing the project verify skill) — a small doc diff through the
  normal PR path, never a side-channel write.
- **A missing handle is a named obligation, not a lowered claim**: when a contract's surface
  cannot be driven (no emulator, no test account), Plan files it through the existing routes
  (a Recirculation ticket or a blocked dependency), mirroring `/verify`'s BLOCKED discipline and
  the 4-levels rule that missing verification infrastructure is an investment target. Nothing new
  is invented — it reuses the recirculation door.

## Recommendation 3 — Divergent gate discovery + adversarial gate falsification for high-risk tickets *(from ADHD + the graph course's verifier patterns; amend spec §4.1 / Plan Phase 3)*

For the minority of pillars where choosing the wrong gate is consequential, insert one bounded,
read-only, two-stage fan-out at contract-authoring time:

1. **Diverge (ADHD pattern):** N isolated branches, each with a different frame (data-corruption
   lens, concurrency lens, adversarial-input lens, "the fixture the old code already handled"
   lens…), each returning candidates in a fixed schema:
   `{promise, failure_mode, observable_evidence, executable_check}` — the four fields the wiki
   digest already prescribes for translating creative branches into executable evidence.
2. **Falsify (adversarial-verify pattern):** for each *proposed gate* (candidate + the author's
   default), independent skeptics attempt exactly one attack: *show how this check passes while
   the goal is actually broken*. A gate a majority of skeptics can defeat is discarded or
   repaired; survivors become the frozen gate's checks.

Guardrails, all already idiomatic in this repo:

- **Deterministically triggered, never default.** Run it only when a fixed predicate fires —
  reuse the review engine's risk-tier inputs (security-sensitive paths, cross-cutting surface,
  new runtime/infra dependency, `expected-green` baseline, large touch-set). Trivial pillars skip
  it entirely — the ADHD material itself demands gating expensive branching by uncertainty and
  consequence, and Plan's fan-outs stay zero-durable-worker, read-only, digest-absorbing.
- **Discovery is never authority.** Branch output informs what Plan freezes; the fixed validator,
  frozen-gate digest, path exclusions, and attempt ceiling from §3.4 are untouched. This adds no
  workflow stage and no model authority over tracker/graph state.

This is the piece that directly raises the auto-validation loop's ceiling: Fusion-style machinery
proves the gate ran; this proves the gate was worth running.

## Recommendation 4 — Dedupe against *seen*, not *confirmed* *(from the graph course's convergence rule; amend spec §4.4 + §8 and the review/finisher loop)*

The course's sharpest transferable rule: a discovery loop converges only when new findings are
deduplicated against **everything ever seen** — including rejected findings — otherwise every
round pays to rediscover its own discarded candidates and the loop never runs dry. Two IDC loops
carry exactly this risk:

- **The finisher's review-fix loop** (review → fix → re-review until PASS): the coordinator
  dedupes by fingerprint *within* a round; a finding rejected below the confidence floor in round
  1 can resurface in round 3. Persist the run's fingerprint ledger across rounds (the fingerprint
  shape already exists) and drop re-seen findings deterministically.
- **Janitor's observe→…→rescan loop** (§4.4, halts after three non-converging passes): "Janitor
  deduplicates findings" should be specified as dedupe-against-seen, with the seen-set persisted
  across passes, and a §8 negative test proving a rejected finding cannot recycle the pass
  counter.

Small, deterministic, and it protects the three-pass convergence bound the spec already promises.

## Recommendation 5 — Adopt the graph doctrine as confirmation, with one explicit refusal *(no spec change required)*

The graph course independently converges on IDC's existing architecture — deterministic code owns
routing and reduction (closeout verbs, the oracle, the matrix), bounded schema-shaped fan-outs,
per-role model tiers, DAG width/critical-path staffing, disjoint-surface parallelism. Two notes
worth recording so future sessions don't relitigate them:

- **Refuse the course's step 14 for tracker authority.** "Describe the objective and let the
  model draw the graph" is fine for *read-only* fan-outs (Plan's clash checks, domain experts,
  the divergent pass above) and is already how they run. For admission, scheduling, tracker
  mutation, and completion it is precisely what the spec prohibits ("no arbitrary generated
  tracker script"; the graph is compiled from authoritative inputs). The video validates the
  shapes, not a transfer of authority.
- **Pipeline-over-barrier is a real but minor Plan refinement.** Phases 3→5 currently author all
  contracts, then check all bodies; per-pillar pipelining (author → schema-check → falsify per
  pillar as each completes) trims wall-clock. Low priority: Plan is not the long pole (the
  serialized e2e in Build is), and several Plan barriers (batch dedup, matrix synthesis,
  the single tracker transaction) are *genuine* whole-set barriers that must stay.

### Secondary (optional, operator-facing): a divergent risk pass in Think

ADHD's second use case — pre-release product-risk discovery from distinct user-confusion /
broken-expectation / churn lenses — could run as an opt-in flourish during the Think interview,
feeding the PRD before its human gate. Ranked last because Think already has a human gate whose
whole purpose is catching requirement gaps, and the operator can simply ask for it; nothing needs
building beyond a paragraph in the Think playbook if desired.

---

## Disposition (2026-07-23 — injected into the implementation run at U7)

The four implementable recommendations were handed to the pathway-integrity implementation run as
a single injection prompt while that run was on U7 (Expanded Intake + Active Janitor). The
injection mapped them as follows; this table is the record of what is now owned by that run:

| Rec | Injected as | Lands in |
|---|---|---|
| 4 — dedupe-against-seen | Item 1 | U7 directly (Janitor pass ledger + the finisher's review-round ledger), with the §4.4/§8 spec edits |
| 1 — surface-typed contracts | Item 2 | Retrofit of the U6 validation-contract schema: folded into U6 if unmerged, else one amendment PR before U8 — before any release/version bump |
| 2 — verification-handle registry | Item 3 | Same U6 retrofit window |
| 3 — divergent gate discovery + falsification | Item 4 | Same U6 retrofit window (Plan's contract-emission step) |

The injection restated the standing constraints (no new top-level workflow stage; fixed validators
only; red-when-broken tests; spec text updated in the same PRs; U8/U9 deferrals untouched) and
required a per-item report: implemented / folded-into-U6 / deferred, test name, and red⇒green
receipt pair. **When auditing that run's closeout, check items against this table.**

Not handed off (no implementation intended): Recommendation 5 (doctrine confirmation + the
recorded refusal, documentation only) and the optional divergent risk pass in Think (operator can
simply ask for it; build nothing unless requested).

## Considered and rejected

- **A per-ticket runtime `/verify` stage in Build.** The spec forbids new top-level stages, and
  §3.4's frozen gate re-run against the final diff already occupies this slot. The `/verify`
  material's value is imported instead as *evidence-shape rules on the existing gate*
  (Recommendations 1–2), not as a second verification pass.
- **Running the divergent pass on every ticket.** Violates the ADHD material's own cost gate and
  Plan's token discipline; deterministic risk-triggering only.
- **Model-authored orchestration for tracker mutations.** See Recommendation 5's refusal.
