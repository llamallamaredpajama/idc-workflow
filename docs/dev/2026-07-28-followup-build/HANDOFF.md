# HANDOFF — verification-contract follow-up build (paused 2026-07-28)

Read this first, then `part0-regrounding-and-triage.md` and `part1-audit-table.md` in this directory.
**This session is paused mid-build, deliberately, at a clean boundary.** Nothing is half-committed.

## What this effort is

The follow-up build defined by two work orders (both UNTRACKED, present in the repo working tree):
- `docs/dev/2026-07-23-verification-contract-followup-prompt.md` — Parts 1–3
- `docs/dev/2026-07-27-pr182-parked-findings-plan.md` — Part 0 sweep + Part 4 units
- `docs/dev/2026-07-27-followup-build-kickoff.md` — the controlling kickoff (supersedes the 07-26 one)

**Merge authorization:** the operator authorized merge-on-green for these follow-up PRs on 2026-07-23. Part 3
was merged under it. That authorization still stands.

## STATE — what is done, in flight, and not started

| Unit | State | Branch / PR |
|---|---|---|
| **Part 0** — re-grounding + triage | **DONE** | `part0-regrounding-and-triage.md` |
| **Part 1** — audit of the 4 injected research items | **DONE** — all four LANDED WITH GAPS, none wholesale-deferred, so the stop-and-report escalation did NOT trigger | `part1-audit-table.md` |
| **Part 3** — Think divergent risk pass + architecture doctrine | **MERGED to main** | PR #185 → `54528fe` (squash) |
| **Part 2a** — seen-ledger convergence | **DONE — final round complete, PR OPEN, not merged** | PR **#186**, branch @ `afc2b5c`. Gates: lint CLEAN(38) · smoke 76 PASS/0 FAIL · governance 151 · evals 0 (no-op). Commit touches `tests/` only — shipped code byte-identical to `e75bde8`. 5 named limitations in the PR body. |
| **Part 2b** — surface contracts + verification-handle registry | **DONE — final round complete, PR OPEN, not merged** | PR **#188**, branch @ `ce205b9`. Gates: lint CLEAN(38) · smoke 76 PASS/0 FAIL · governance 149 · evals 0 (no-op). 19 one-at-a-time neuter receipts. **The append-back now works end to end** under the shipped ordering. |
| **Part 4a** — V-PIN + V-DOOR + roll-ins | **DONE — fix round 1 complete, PR OPEN, not merged** | PR **#187**, branch @ `ceabc95`. Gates: lint CLEAN(38) · smoke 76 PASS/0 FAIL · governance 148 · evals 0 (no-op). **Residual by design:** the authorization door is NARROWED, not closed — `scripts/idc_command_contract.py:3535` `_mint_or_rollback` is still reachable from any Bash via `start --command init`. Recorded at `docs/dev/known-debts.md:33`, characterized by `path-gate-boundaries.sh` D2 §3c. Gating it was REJECTED with executed evidence: a Claude-only admission token would deny every Codex/Pi commit. |
| **Part 4b** — V-AUTH | **NOT STARTED** | — |
| **Close-out** — release bump, disposition doc | **NOT STARTED** | — |

**⚠️ FIRST ACTION FOR THE NEXT SESSION: three PRs are OPEN and NOT MERGED — #186, #187, #188.** All work is
committed and pushed; the worktrees are clean. Decide merges under the standing 2026-07-23 authorization.

    /Users/jeremy/dev/proj/idc-workflow-p2a   followup/part2-seen-ledger-convergence        PR #186 @ afc2b5c
    /Users/jeremy/dev/proj/idc-workflow-p2b   followup/part2-surface-contracts-and-handles  PR #188 @ ce205b9
    /Users/jeremy/dev/proj/idc-workflow-p4a   followup/part4a-vpin-vdoor                    PR #187 @ ceabc95

Before merging, confirm PR CI is green **at the exact final head** of each — the kickoff requires that, and none
of the three had CI results yet when this session ended. Merge order does not matter (disjoint surfaces), but
**Part 4b must not start until #187 merges**, because both rewrite `scripts/idc_path_gate.py`.

## ROUND CAPS — important

The kickoff sets a **hard cap of 2 fix rounds per PR**, then stop and report honestly. Status:
- **Part 2a and Part 2b are at their FINAL round.** No round 3. Whatever their last fix commit leaves open is a
  **known limitation for the operator's report**, not another round.
- **Part 4a has used one fix round.** One more review + fix round is available.

The kickoff also says: *if round 2 surfaces the same CLASS of finding again, re-diagnose the root instead of
patching the case.* That has already happened twice — see `followups.md` §A.

## What each in-flight branch was fixing when paused

**Part 2a** (round-2 review returned FAIL, 2 blockers): an inert fail-closed fixture (hiding `TRACKER.md` is not
a read failure on the filesystem backend, so the guard is never reached); and the entire suppression half of the
feature having zero test signal (neutering it leaves all 150 governance scenarios green). Plus a root-cause task:
add a shared `tests/smoke/lib/` helper that makes a fail-closed assertion impossible to write without naming a
discriminating artifact, and document the rule.

**Part 2b** (both round-2 reviews returned FAIL, 4 distinct blockers): a **security regression** — the credential
consolidation silently stopped catching footer-less PEM headers and `private_key=` assignments on a
committed-file write path; the opaque-run backstop missing real base64 (`+`/`/` split the run), letting a
truncated private key reach git verbatim, with a fixture whose fake secrets are pure alphanumerics so it can
never catch it; **nine guards this branch added with zero coverage** (proven by neutering all nine at once and
getting a green suite); and the append-back being unusable end to end with a playbook instruction that
hard-blocks the finisher.

**Part 4a** (both reviews returned FAIL): the authorization door is **narrowed, not closed** — a helper under
`tests/` that ships with the plugin mints caller-chosen branch/ticket/graph-node grants, and one documented
command still self-mints a whole-repo grant from any shell; plus the branch's own headline fix being unverified
(deleting the one line that implements it reds nothing).

## Environment traps — apply in EVERY shell (verified the hard way across many agents)

    export PATH=/opt/homebrew/bin:$PATH     # python >= 3.10 required (ambient is 3.9.6); `timeout` must exist
    cd "$(pwd -P)"                          # physical path — tests/smoke/phase8-pi-launchable.sh false-fails
                                            # from symlink-aliased paths

**Baseline gates on merged main:**

    bash scripts/lint-references.sh   exit 0   CLEAN (38 files scanned)
    bash tests/smoke/run-all.sh       exit 0   76 PASS / 0 FAIL
    bash scripts/run-evals.sh         exit 0   "no evalsets" — a BY-DESIGN no-op on this repo, pinned by
                                               tests/smoke/phase1-run-evals-no-evalsets.sh. It is a green gate,
                                               NOT evidence about any change. The real gate is the smoke suite.

**Governance lane scenario counts:** merged main **146** real; p2a 150; p2b 149; p4a 148.

**Known flake, do NOT "fix":** `governance/path-gate-git-backstops.sh` can fail with
`subprocess.TimeoutExpired … pre-push … timed out after 5 seconds` when the machine is loaded (many concurrent
agents). Re-run that single file in isolation to confirm before treating it as real.

## Review discipline used (and worth continuing)

Per unit: a fresh writer, then **two independent reviewers in their own disposable clones**, each re-running the
evidence rather than trusting the transcript — one on spec/security, one on tests/evidence. One consolidated fix
commit per round, fresh agents each round. Every fix and every new test needs a red-when-broken receipt:
neuter the guard, show the test fail under an explicit `timeout`, restore, show it pass.

Two rules that earned their keep: **a test that still passes with its guard neutered means the FIXTURE is
wrong**, and **neutering a BOUND hangs instead of reddening, and a hang looks like a slow pass** — so run every
probe under a `timeout` and treat a timeout as RED.

## Operator rulings made this session — do not re-litigate

1. **Downgraded findings must be filed, not dropped.** When a review downgrades a finding from blocking to minor
   between rounds, the leftover work becomes a recirculation ticket rather than vanishing. Implemented red-first
   (new assertion written and shown failing against unmodified code BEFORE the fix), the old test that enshrined
   the defect replaced and annotated so nobody restores it, and the filed ticket carries provenance (review
   round + original severity). *"A merge gate reporting 'converged' over work that silently vanished is a false
   green."*
2. **The evals gate is reported as a by-design no-op**, never as evidence.

## Corrections to earlier statements (carry these forward)

- The new mandatory `ownership` surface class is **NOT** a breaking change for governed repos. Verified:
  `idc_ruleset_check.py` / `idc_ruleset_install.py` are invoked by no shipped command, agent, skill, or template;
  they govern this repo via its own CI. No release-note warning needed.
- A round-1 reviewer's claim that a receipt-writer drift check was reachable was **wrong** — adjudicated across
  five executed experiments. The duplicate was genuinely unreachable and its deletion lost nothing.

## Where everything lives

- **Session artifacts:** this directory (`docs/dev/2026-07-28-followup-build/`) — triage, audit table, both
  sandbox receipts, follow-ups, the V-PIN SHA lookup. **These are UNTRACKED**, matching the convention the
  operator uses for the other planning docs in `docs/dev/`. They survive a context clear but not a `git clean`.
- **Sandbox run captures:** `/Users/jeremy/dev/sandbox/_idc-observability/` — `run-part3a-think.txt` (189 KB),
  `run-part4a-init.txt` (452 KB), and `part3a-artifacts/` (the PRD/consideration/spec the Think run produced).
- **Install sandbox:** restored to its exact pre-session state, `fbfd107f`, plus its two untracked files. Nothing
  to clean up.

## Next actions, in order

1. Triage the three worktrees' uncommitted work (see ⚠️ above).
2. Finish Part 2a and Part 2b's final rounds; open their PRs; merge on green under the standing authorization.
   Report whatever remains open as named limitations — they have no round 3.
3. Finish Part 4a (one round available), open its PR, merge on green. Its e2e receipt already exists
   (`receipt-part4a-init-sandbox.md`) but was taken against `8827546`; re-drive it if the fix changes init's path.
4. **Then** Part 4b (V-AUTH) — it must wait for Part 4a to merge, because both rewrite `scripts/idc_path_gate.py`.
5. Close-out: ONE consolidated release bump (plugin.json + marketplace.json in lockstep + CHANGELOG), prepared
   but **not published**; update the Disposition section of
   `docs/dev/2026-07-23-verification-contract-research-recommendations.md`; finalize the Part-0 triage table; file
   the items in `followups.md`.
