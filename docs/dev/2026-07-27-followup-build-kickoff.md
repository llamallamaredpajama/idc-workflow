# Kickoff prompt — verification-contract follow-up build (Parts 0–4)

**Supersedes** `docs/dev/2026-07-26-verification-contract-kickoff.md`, which was written before the
PR-182 review fixes were finished. Paste the block below into a fresh session in this repo, ONLY
after **PR #183 has been merged into `integration/idc-pathway-integrity` AND PR #182 has been merged
to `main`** — in that order.

Controlling work orders (both read in full by the executing session):
`docs/dev/2026-07-23-verification-contract-followup-prompt.md` (Parts 1–3) and
`docs/dev/2026-07-27-pr182-parked-findings-plan.md` (Part 0 sweep + Part 4 units).

The merge-on-green authorization in GATES was granted by the operator on 2026-07-23. Delete that
sentence if you want manual sign-off on each follow-up PR instead.

```text
Fresh session in /Users/jeremy/dev/proj/idc-workflow. PR #183 (all 55 pathway-integrity review
fixes) was merged into PR #182's branch, and PR #182 (the 5.0.0 release) was then merged to main. I
have confirmed both myself. Your job is the follow-up build: the verification-contract work order
PLUS the parked PR-182 findings. Run it autonomously to green; stop only at the named escalation
points below.

STEP 0 — PRECONDITION CHECK (stop and report if ANY fails; do not start building):
git fetch origin, then confirm origin/main contains BOTH the release AND its review fixes. Check
CODE markers, not just file presence — #182 merged WITHOUT #183 would satisfy a file-existence
check while carrying none of the 55 fixes. That exact trap already cost this effort a day.
  Release markers (files must exist at origin/main):
    scripts/idc_pilot_metrics.py
    tests/smoke/governance/janitor-seen-finding-ledger.sh
  Review-fix markers (all must be present at origin/main):
    grep -q '_surface_declares_class'   scripts/idc_ruleset_check.py       # F51/F52 root split
    grep -q '_CLONE_SCHEMES'            scripts/idc_ruleset_install.py     # F53
    grep -q 'LEGACY_RECEIPT_RECOVERY'   scripts/idc_validation_contract.py # F55
    test -f tests/smoke/governance/planning-receipt-write-witness-atomic.sh   # F54
    test -f tests/smoke/governance/planning-receipt-legacy-upgrade.sh         # F55
  If the release markers pass but the review-fix markers do not, STOP: main has the release without
  its fixes, which is a merge-order mistake, not a starting condition.

ENVIRONMENT TRAPS (verified the hard way across five agents — apply in EVERY gate/test shell):
- prepend /opt/homebrew/bin to PATH; python >= 3.10 and `timeout` are required (ambient python is
  3.9.6 and the suite silently behaves differently on it);
- run test suites from a physical path (cd "$(pwd -P)") — tests/smoke/phase8-pi-launchable.sh
  false-fails from symlink-aliased paths.

STEP 1 — CONTROLLING WORK ORDERS (read both completely before any action):
1. /Users/jeremy/dev/proj/idc-workflow/docs/dev/2026-07-23-verification-contract-followup-prompt.md
   (Parts 1–3: audit the four injected research items -> close gaps -> remaining recommendations)
2. /Users/jeremy/dev/proj/idc-workflow/docs/dev/2026-07-27-pr182-parked-findings-plan.md
   (Part 0 sweep + Part 4: V-PIN, V-DOOR, V-AUTH, discovered items D1–D3, with file:line anchors)
Decisions in both are baked in — do not re-ask them. Honor the Part-1 escalation rule exactly: if
research items 2–4 turn out wholesale-deferred (not just gappy), STOP after Part 1 and report.

PART 0 — RE-GROUNDING SWEEP (before Part 1; read-only). The parked-findings plan was written against
integration @ 9e50a1e and fix branch @ fd87097. The fix branch ran to 11 commits (final 97f6da3), so
several of its "grounded facts" have MOVED. Re-verify each against merged main, and specifically:
- V-PIN is now FOUR unpinned `uses:` lines, not three: .github/workflows/idc-pathway-integrity.yml
  has two checkout steps (a second job was added), plus ci.yml's checkout and setup-bun. Re-run the
  count yourself; do not trust this number either.
- D2 (no negative test for read-only self-grant) — verify whether a fix round closed it.
- D3/N1 — verify whether .github/CODEOWNERS now covers scripts/idc_pathway_check.py AND
  scripts/idc_ruleset_check.py specifically.
- Re-read the ownership gate before touching it: F50/F51/F52 were closed by SPLITTING class
  MEMBERSHIP (_surface_declares_class) from surface TYPING (_authoritative_surface_type). That split
  is the design decision; the git-check-ignore differential grid
  (tests/smoke/governance/codeowners-ownership-differential.sh) is what proves it safe. Do not
  re-fuse them, and re-run that grid after ANY change to that file.
Output a triage table: item -> already-done (verify, close) / roll into Part 4 / defer with a named
owner. Fold confirmed roll-ins into the Part-4 unit list.

ALREADY ADJUDICATED — do NOT re-litigate these, and do not hold anything for them:
- F3 ("deny requests that carry no ticket/graph identity") — the literal change denies every
  legitimate edit from all three runtimes (verified: no adapter sends identity). The spec's MUST is
  deny-on-MISMATCH, which is implemented and tested. The durable fix is V-AUTH stage 3 (adapters
  echo identity FIRST, then the gate requires it, spec amended in the same PR). Nothing to decide.
- F42 (dotted-directory rule false-REFUSES a surface) — an over-refusal in the SAFE direction, the
  documented cost of the F28 residual, with a clear operator remedy (add an anchored recursive
  rule). Accepted tradeoff. No action.
- F2 residual (removing the public `authorize` door) — that IS unit V-DOOR. Build it there.

EXECUTION ORDER: Part 0 -> Parts 1–3 (verification-contract) -> Part 4 units:
V-PIN + V-DOOR (one small PR) -> V-AUTH (its own PR, staged 1->2->3 per the plan; D1 triaged into it
or split out). ONE PR at a time; each through the full review pattern below.

WORKFLOW PATTERN (how, not what):
- Feature branch off origin/main; one PR to main per unit.
- Fresh writer agent per part. After the build: dual independent fresh reviews (spec/security +
  tests/evidence), each in its own disposable clone, each re-running the evidence itself — never
  trusting transcripts or PR text.
- One consolidated fix commit per review round; fresh reviewer pair each round; hard cap of 2 fix
  rounds, then stop and report honestly. (The PR-182 relay burned 12 rounds chasing variants of one
  root defect — if round 2 surfaces the same CLASS of finding again, re-diagnose the root instead of
  patching the case.)
- EVERY fix and EVERY new test needs a red-when-broken receipt: neuter the guard, SHOW the test
  fail, restore, show it pass. Two hard-won rules:
  (a) When a test passes with its guard neutered, the FIXTURE is wrong, not the finding — it is
      refusing for a different reason and would never have caught a regression. Rebuild it.
  (b) When the guard you neuter is a BOUND (a ceiling, timeout, or retry cap), removing it HANGS the
      lane instead of reddening it, and a hang looks like a slow pass. Run every red-when-broken
      probe under an explicit per-case `timeout`, and treat a timeout as RED.

GATES (all exit 0 before claiming any unit done):
  bash scripts/lint-references.sh
  bash tests/smoke/run-all.sh
  bash scripts/run-evals.sh
plus PR CI green at the exact final head.

E2E RECEIPTS (unit tests alone are NOT done — this is the finish line the operator asked for):
- V-AUTH: one full install-sandbox Build lifecycle proving the staged mints fire and the drain still
  completes. It changes Build behavior, so a green smoke suite is not sufficient proof.
- V-DOOR: the phase1 init suite plus one sandbox init run.
- V-PIN: proven by the PR's own live CI runs (the required-check workflow triggers on pull_request,
  so a wrong pin is loudly visible before merge).
- Part 3a: one /idc:think sandbox run showing the stress-test branches fire and their digests land in
  the PRD draft.
Drive EVERY sandbox run yourself via direct `codex exec --cd <sandbox>
--dangerously-bypass-approvals-and-sandbox` per this repo's CLAUDE.md. Never a nested claude (spend
policy), never the codex-companion `task` wrapper (it network-sandboxes the job and `gh` dies).
State the hook-fidelity caveat in your report: Claude Code hooks do not fire inside Codex, so assert
hook behavior by invoking the hook scripts directly with synthetic payloads against the REAL
artifacts the run leaves.

MERGE + CLOSE-OUT:
When both reviews PASS with 0 blockers, all gates are green, and the unit's e2e receipt is in hand,
merge that PR to main — the operator authorized these merges on 2026-07-23. Prepare the release bump
in each shipped-file PR (plugin.json + marketplace.json in lockstep + CHANGELOG) but do NOT publish.
Then update the Disposition section of
docs/dev/2026-07-23-verification-contract-research-recommendations.md and the Part-0 triage table
with final dispositions.

STOP AND ASK only for: a Part-1 wholesale deferral; a finding that needs a product/PRD decision;
anything touching secrets or a live (non-sandbox) repo; or a second review round surfacing the same
class of defect a third time.

FINAL REPORT in plain English: what landed, the receipts (exact commands and their outcomes), what
is still unverified, and anything you deliberately left out and why.
```
