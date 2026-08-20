# Part 1 — audit of the four injected research items

**Method:** four independent read-only agents, one per item, each in its own disposable clone of merged
main (`6c1254c`), each required to produce red-when-broken receipts (neuter the guard, show the test go
RED under an explicit `timeout`, restore, show GREEN) rather than trust the prior run's closeout report.

**Baseline for comparison:** `lint-references.sh` CLEAN (38 files) · `tests/smoke/run-all.sh` 76 PASS /
0 FAIL · `run-evals.sh` exit 0 with "no evalsets" (a by-design no-op on this repo, pinned by
`tests/smoke/phase1-run-evals-no-evalsets.sh`).

## Verdicts

| # | Item | Verdict | Gaps |
|---|---|---|---|
| 1 | Rec 4 — dedupe against *seen*, not *confirmed* | **LANDED WITH GAPS** | 4 (one **exploitable**) |
| 2 | Rec 1 — surface-typed validation contracts | **LANDED WITH GAPS** | 6 (two **inert fixtures**, one **secret leak**) |
| 3 | Rec 2 — verification-handle registry | **LANDED WITH GAPS** | 6 (the append-back half **not landed**) |
| 4 | Rec 3 — divergent gate discovery + falsification | **LANDED WITH GAPS** | 6 (built but **never invoked**) |

**ESCALATION RULE NOT TRIGGERED.** The rule says stop and report if items 2–4 turn out *wholesale
deferred* rather than gappy. All three landed substantially — real fixed code, real spec text, and
working red-when-broken tests for the majority of their claims. Proceeding to Part 2 as instructed.

**Honest scope note.** Part 2 was written as "close the gaps" — a sweep. On this evidence it is a real
build: it includes a new write-path subcommand, a binding between two previously unconnected stages, a
breaking CLI change, and a credential-redaction fix. Flagged, not used as grounds to stop.

## The one-sentence pattern across all four

**The machinery got built; nothing forces the pipeline to use it.** Item 4's falsifier is real, tested
code with no production caller. Item 3's registry validates correctly but Build never writes back to it,
and deleting the Plan playbook's instructions for it leaves the linter and twelve tests green. Item 2's
strictest rule is a regex that matches any string, on a surface value that is also the silent default.
Item 1's ledger is durable and fail-closed, but the convergence controller reads the unfiltered set.

## Item 1 — dedupe against seen (Rec 4)

Landed: Janitor pass ledger persisting across *processes* (`docs/workflow/reconciliation-seen-findings.json`,
fail-closed to exit 2 on an invalid ledger); the per-PR review-round ledger
(`scripts/idc_review_seen_ledger.py`, new in U7); spec §4.4 (`:347-354`) and §8 (`:474-479`).
Two guards proven genuinely red-when-broken.

| Gap | What |
|---|---|
| **1-1** | The U7 "bare-`filed` must not suppress" fix has **zero** coverage. Restoring the bug leaves 146/146 governance scenarios green. The fixture is inert because it seeds a `major` finding, which maps to `"confirmed"` — terminal both before and after the regression — so the failed-filing-retry path is never exercised. *(This is the carried follow-up the kickoff predicted.)* |
| **1-2** | `new_blockers` / `new_blocker_count` are computed and reported but have **zero consumers**. The convergence controller compares the **unfiltered** blocker set, so a blocker that disappears and resurfaces resets the stagnation counter — the exact recycling spec §8 line 478 claims is impossible. Spec overstates what ships. |
| **1-3** | **EXPLOITABLE, reproduced end-to-end.** A model-authored `record-round` downgrades a pending-retry `filed` entry → the retry suppresses it → board count 0 → the finish gate reports **no routing gap** → merge proceeds with a stranded finding. Logged by the run's own reviewer as accepted residual NIT-A, with no test and no ticket. Violates the standing "no model-authored artifact mutates routed/receipt state" constraint. |
| **1-4** | The below-floor/rejected/refuted half is **prose-enforced only** — no hook or fixed code invokes `record-round`. A coordinator round that skips the call lets a round-1 rejection resurface in round 3. |

## Item 2 — surface-typed contracts (Rec 1)

Landed: the schema and its enums; the pairing table as fixed code; two hard refusals (pair mismatch,
unjustified `surface: none`) both proven red-when-broken; spec §3.4 with the table inline.

| Gap | What |
|---|---|
| **2-1** | **Inert fixture.** Neutering the pairing check leaves all 29 referencing tests green — the fixture's mismatch is caught earlier by a different guard, and its grep is loose enough to match that other message. The behaviour the check owns is *silent normalization*, which nothing observes. |
| **2-2** | **Inert fixture.** All 7 receipt-side contract-drift refusals are deletable with zero tests red. Case (F) is doubly inert: the forgery never reaches the drift code, and the test's grep matches the word "surface" **in its own temp filename**. |
| **2-3** | The CLI producibility pattern is `re.compile(r".")` — it matches any non-empty string — and `cli` is the **silent default** when `--surface` is omitted. So Recommendation 1's headline promise (a GUI ticket can't pass on a unit-test exit code) holds only if the author volunteers `surface: gui`. Omitting the flag is easier and free. |
| **2-4** | **Security.** `stdout_excerpt` is bounded but **not redacted** — stderr is scrubbed, stdout is not. A credential-shaped token printed to stdout lands verbatim in the frozen contract and the execution receipt, both **committed repo files**. Spec promises "bounded redacted evidence"; only half is redacted. |
| **2-5** | Two independent copies of `SURFACE_EVIDENCE_TABLE` with no lock-step test; handles are typed from one copy and contracts frozen from the other, so drift makes a registry-legal handle produce an illegal contract. |
| **2-6** | The review engine treats contract drift as a **model-judgment** dimension and never mentions surface/evidence. The deterministic enforcement exists only at finish — *after* review. |

## Item 3 — verification-handle registry (Rec 2)

Landed: the registry template + scaffold + receipt preservation; a fixed-code schema/secret validator;
a fixed-code resolver; the `handle_id` citation propagating contract → execution receipt → build receipt;
the named-obligation-on-miss rule (a warning-only downgrade is forbidden); spec §3.4. Nine guards proven
red-when-broken.

| Gap | What |
|---|---|
| **3-1** | The handle-vs-explicit-command mismatch refusal is **inert** — no test passes `--handle-id` together with `--verify`. |
| **3-2** | Doctor's dangling-citation check is unwired (prose, not a runnable fence), untested, **and crashes** with an unhandled `FileNotFoundError` on the default repo state — the scaffold never creates the directory it reads, so every freshly-initialized repo hits it. Row 9 is documented "advisory; never FAIL"; a traceback is neither. |
| **3-3** | The Plan lookup step has **zero** coverage — deleting all five registry lines leaves the linter and twelve tests green. Since `handle_id` is optional in fixed code, a Plan that stops citing handles still passes every validator, and the registry becomes write-only decoration. |
| **3-4** | **Not landed.** Build/Finisher never appends newly-proven recipes back — the entire compounding half of the recommendation. No `append` subcommand exists; the finisher never mentions the registry. |
| **3-5** | Spec §4.2 was never amended (the injection required §3.4 **and** §4.2). |
| **3-6** | `/idc:update`'s registry-preservation branch is untested. |

## Item 4 — divergent gate discovery + falsification (Rec 3)

Landed: a real fixed-code risk predicate with greppable thresholds (`scripts/idc_validation_risk_gate.py`,
364 lines); the exact four-field candidate schema; the exact skeptic question as a fixed string; the
discard/repair action; the trivial-pillars-SKIP cost gate; invariant preservation; spec §3.4/§4.1/§8 and
both playbooks. **Six independent guards proven red-when-broken, no inert fixtures found.**

| Gap | What |
|---|---|
| **4-1** | **Substantial.** Nothing invokes it. `freeze` accepts no risk-gate result and nothing refuses a freeze whose risk gate never ran; the only callers are its own tests. The script says so itself in its header. A well-built tool sitting *beside* the pipeline rather than inside it. |
| **4-2** | "Majority" is a caller-supplied **boolean**, not a computed majority — one flipped flag defeats or saves any gate. That is precisely the model authority the recommendation's own guardrail forbids. |
| **4-3** | No minimum fan-out and no distinct-frame requirement. A single-candidate scenario passes a security-sensitive ticket. The four named lenses appear **nowhere** in the plugin. |
| **4-4** | The author's default gate is never falsified — a run can attack three throwaway candidates and ship the un-attacked default. |
| **4-5** | No survivor → frozen-gate handoff; `selected` is written to a file nothing consumes. |
| **4-6** | No CHANGELOG entry for the feature. |
