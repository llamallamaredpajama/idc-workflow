> **SUPERSEDED 2026-07-27** — use
> [`2026-07-27-followup-build-kickoff.md`](2026-07-27-followup-build-kickoff.md) instead.
> This version predates the PR-182 review fixes: its precondition check cannot tell a main
> that merged PR #182 alone (release, zero fixes) from one that merged PR #183 first, and its
> Part-0 anchors point at a fix branch that has since moved.

# Kickoff prompt — verification-contract follow-up build (+ PR-182 parked findings)

Paste the block below into a fresh session in this repo, ONLY after PR 182 — including its
review-fix rounds from `fix/pr-182-pathway-integrity` — is merged to main. Controlling work
orders: `docs/dev/2026-07-23-verification-contract-followup-prompt.md` (Parts 1–3) and
`docs/dev/2026-07-27-pr182-parked-findings-plan.md` (Part 0 sweep + Part 4 units). The
merge-on-green authorization in the GATES section was granted by the operator on 2026-07-23;
delete that sentence if you want manual sign-off instead.

```text
Fresh session in /Users/jeremy/dev/proj/idc-workflow. The pathway-integrity run is complete and
PR 182 (with its review-fix rounds) is merged to main (I have confirmed this myself). Your job
is the follow-up build: the verification-contract work order PLUS the parked PR-182 findings.
Run it autonomously; stop only at the named escalation points.

STEP 0 — PRECONDITION CHECK (stop if any fails):
- git fetch origin, then confirm origin/main actually contains the pathway-integrity work:
  scripts/idc_pilot_metrics.py and tests/smoke/governance/janitor-seen-finding-ledger.sh must
  exist at origin/main. If not, STOP and tell me main is not ready — do not start building.
- Environment traps (verified the hard way across four agents): prepend /opt/homebrew/bin to
  PATH in every gate/test shell (python >= 3.10 and `timeout` are required; ambient python is
  3.9.6), and run test suites from a physical path (cd "$(pwd -P)") because
  tests/smoke/phase8-pi-launchable.sh false-fails from symlink-aliased paths.

STEP 1 — CONTROLLING WORK ORDERS (read both completely before any action):
1. /Users/jeremy/dev/proj/idc-workflow/docs/dev/2026-07-23-verification-contract-followup-prompt.md
   (Parts 1–3: audit the four injected research items -> close gaps -> remaining recommendations)
2. /Users/jeremy/dev/proj/idc-workflow/docs/dev/2026-07-27-pr182-parked-findings-plan.md
   (Part 0 sweep + Part 4: the parked PR-182 findings — V-PIN, V-DOOR, V-AUTH — with grounded
   file:line anchors, staged approach, and discovered items D1–D3)
Decisions in both are baked in — do not re-ask them. Honor the Part-1 escalation rule exactly:
if research items 2–4 turn out wholesale-deferred (not just gappy), STOP after Part 1 and report.

PART 0 — PARKED-FINDINGS SWEEP (before Part 1; read-only):
The other session kept working after the plan doc was written, so re-ground and re-enumerate:
- Re-verify every "Grounded facts" claim in the Part-4 plan against merged main (the plan
  anchors integration @ 9e50a1e and fix branch @ fd87097; later rounds may have moved things —
  in particular check whether the fix branch closed D2 and how many checkout lines exist).
- Enumerate any NEW parked/deferred/contested items from: PR 182's body and comments; the
  fix-branch round commit messages; docs/reviews/2026-07-26-pr-182-pathway-integrity-review.md
  and any later review docs; the run's final-review nits (N1 CODEOWNERS coverage of
  idc_pathway_check.py + idc_ruleset_check.py, N2 CHANGELOG note) in
  .pi/team-lead/runs/idc-pathway-integrity-20260722-052144/reviews/final-*-r2.md.
- Output a triage table: item -> already-done-by-fix-rounds (verify, close) / roll into Part 4 /
  defer with a named owner note. Fold confirmed roll-ins into the Part-4 unit list.

EXECUTION ORDER: Part 0 -> Parts 1–3 (verification-contract) -> Part 4 units: V-PIN + V-DOOR
(one small PR) -> V-AUTH (its own PR, staged 1->2->3 per the plan; D1 triaged into it or split
out). One PR at a time; each PR through the full review pattern below.

WORKFLOW PATTERN (how, not what):
- Feature branch off origin/main; one PR to main.
- Fresh writer agent per part. After the build: dual independent fresh reviews (spec/security +
  tests/evidence), each executed in its own disposable clone, each re-running the evidence
  itself — never trusting transcripts or PR text.
- One consolidated fix commit per review round; fresh reviewer pair each round; hard cap of
  2 fix rounds, then stop and report honestly.
- Every fix and every new test needs a red-when-broken receipt (show it fails when its guard is
  neutered, then green when restored).
- Part 3a's sandbox receipt: drive /idc:think in the install sandbox
  (/Users/jeremy/dev/sandbox/ke-idc-test-repo-install) via direct codex exec per this repo's
  CLAUDE.md — never a nested claude, never the codex-companion task wrapper.

KNOWN CARRIED FOLLOW-UPS (audit hints from the pathway-integrity run ledger):
- The Part-1 item-1 audit should surface: no committed test pins the U7 review-round fix (the
  bare-"filed" suppression predicate in the review seen-ledger) — close it in Part 2 with a
  failed-filing-retry regression test.
- Same-surface rider if cheap: the round-2 reviewer's defense-in-depth nit (a model-authored
  "rejected" record can downgrade a pending-retry "filed" ledger entry); hardening options are in
  .pi/team-lead/runs/idc-pathway-integrity-20260722-052144/reviews/pr-175-green-spec-security-r2.md.
- One-line rider: harden tests/smoke/phase8-pi-launchable.sh root resolution with pwd -P
  (four independent confirmations of the symlink false-fail).

GATES + MERGE:
All three gates exit 0 — bash scripts/lint-references.sh, bash tests/smoke/run-all.sh,
bash scripts/run-evals.sh — plus PR CI green at the exact final head. Part-4 sandbox receipts:
V-AUTH needs one full install-sandbox Build lifecycle (codex exec driver) proving the staged
mints fire and the drain completes; V-DOOR needs the phase1 init suite plus one sandbox init
run; V-PIN is proven by the PR's own live CI runs. Prepare the release bump in each shipped-file
PR (plugin.json + marketplace.json in lockstep + CHANGELOG) but do not publish it. When both
reviews PASS with 0 blockers and all gates are green, merge the PR to main — the operator
authorized this merge on 2026-07-23. Update the Disposition section of
docs/dev/2026-07-23-verification-contract-research-recommendations.md (audit results + what
landed) and the triage table produced by Part 0 (final dispositions). Then report in plain
English: what landed, the receipts, and anything that remains.
```
