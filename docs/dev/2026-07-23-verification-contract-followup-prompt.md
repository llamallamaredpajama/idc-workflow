# Follow-up build prompt — verification-contract research (audit + close gaps + remaining recs)

Recovered from the cleared planning session of 2026-07-23 (session `c91f856b`). Fire this ONLY
after the pathway-integrity run (U8/U9, other session) is finished and merged to main. Companion
work order: `docs/dev/2026-07-23-verification-contract-research-recommendations.md` (its
Disposition table).

```text
CONTEXT + MISSION
Fresh session in /Users/jeremy/dev/proj/idc-workflow, starting from merged main. The convergent
pathway-integrity spec (docs/specs/idc-convergent-pathway-integrity-spec.md) has been implemented
and merged, including four research-driven amendments injected mid-run. Read
docs/dev/2026-07-23-verification-contract-research-recommendations.md end-to-end FIRST — its
Disposition table is your work order. Three parts, in order: (1) audit that the four injected
items actually landed as specified, (2) close any gaps the audit finds, (3) implement the two
remaining never-handed-off recommendations. Decisions are baked in below — do not re-ask them.

PART 1 — AUDIT (read-only; trust files and tests, never the prior run's closeout report)
For each Disposition row, verify against merged main — code, spec text, AND tests:
  1. Dedupe-against-seen: Janitor pass ledger + finisher review-round ledger exist; a rejected
     finding cannot recycle the convergence/attempt counters; spec §4.4/§8 text updated; the
     negative test goes red when you neuter the ledger locally (then revert).
  2. Surface-typed contracts: the validation-contract schema carries surface + evidence_kind with
     the fixed pairing table; the validator rejects a gate/evidence mismatch and an unjustified
     surface:none; gate receipts carry the declared evidence kind; the review engine treats a
     mismatch as a deterministic contract-drift FAIL.
  3. Verification-handle registry: the registry file exists (planned as
     docs/workflow/verification-handles.yaml — find the landed equivalent); Plan cites entries in
     contracts; Build appends proven recipes at finish; a missing handle becomes a named routed
     obligation; doctor warns on a dangling citation.
  4. Divergent gate discovery: deterministic risk trigger; branches return
     {promise, failure_mode, observable_evidence, executable_check}; skeptic falsification of each
     proposed gate; a test proves trivial pillars SKIP the pass.
Output a table: item → landed-as-specified / landed-with-gaps (named) / not-landed.
ESCALATION RULE: if items 2–4 turn out wholesale-deferred (not just gappy), STOP after Part 1 and
report — that is its own planned build, not a sweep.

PART 2 — CLOSE THE GAPS
Fix every named gap under the standing constraints: no new top-level workflow stage; fixed
validators only — no model-authored artifact ever mutates tracker/graph/receipt state; every fix
lands with a red-when-broken test (show fail-on-neuter, then pass); spec text updated in the same
PR so the controlling doc never drifts from code.

PART 3 — REMAINING RECOMMENDATIONS (decisions baked in)
  a. IMPLEMENT (playbook change, no new scripts): opt-in divergent risk pass in
     commands/think.md — when the operator asks to stress-test an idea, fan out 3–5 bounded
     read-only branches with distinct lenses (user-confusion, broken-expectation, churn,
     promised-but-missing), each returning {promise, failure_mode, observable_evidence,
     executable_check}; digests feed the PRD draft before its human gate. Zero durable workers.
     Deliberately NO new script, validator, or trigger predicate: the pass is human-invoked and
     its output is human-gated, so machine enforcement here would exceed the Think stage's
     standard. If you believe a script is genuinely required, STOP and surface the reasoning as
     a choice rather than building it.
     Verification: this changes think behavior, so give it a receipt proportional to its risk —
     one sandbox run of /idc:think (install sandbox, codex exec driver per CLAUDE.md) where the
     prompt asks for the stress-test, showing the branches fire and the digests land in the PRD
     draft. Full lifecycle e2e is not required for an opt-in conversational pass.
  b. IMPLEMENT (documentation): record the standing boundary in docs/architecture.md —
     model-authored orchestration is welcome for read-only fan-outs; admission, scheduling,
     tracker mutation, and completion always go through fixed validators, never a generated
     script. One paragraph, so future sessions don't relitigate it.
  c. SKIP: the Plan pipeline-over-barrier refactor. Plan is not the wall-clock long pole and
     several of its barriers are genuine. Leave the recommendations doc's note as-is.

GATES (all exit 0 before claiming done)
  bash scripts/lint-references.sh
  bash tests/smoke/run-all.sh
  bash scripts/run-evals.sh
Shipped-file changes follow repo conventions (idc: namespacing, ${CLAUDE_PLUGIN_ROOT} rules, no
personal paths). Sandbox receipts: Part 2 fixes that changed command/agent/skill BEHAVIOR (not
just wording) get a sandbox e2e per CLAUDE.md (codex exec driver; think/plan surface → the
install sandbox); Part 3a gets exactly the scoped /idc:think receipt specified above; Part 3b
needs no e2e. If shipped files changed, prepare the release bump (plugin.json + marketplace.json
in lockstep + CHANGELOG) in the PR but do not publish it.

CLOSEOUT
Update the Disposition section of
docs/dev/2026-07-23-verification-contract-research-recommendations.md with the audit results and
what this session landed. PR body carries the audit table + every red⇒green receipt pair. Do not
merge without operator sign-off unless authorized in-session.
```
