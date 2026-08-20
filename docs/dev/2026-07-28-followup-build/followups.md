# Follow-ups from the verification-contract follow-up build (2026-07-28)

Everything here is deliberately NOT done in this build, with the reason. Nothing is "vanished" — each has an
owner and enough detail to act on cold. Issue #184 already carries the relay-2 findings from the prior effort;
do not re-file those here.

## A. The process finding — the highest-value item

**Nine guards across four branches were found to be inert, incomplete, or untested.** Five distinct shapes, each
with a durable countermeasure. This is worth writing into the governance lane's conventions, because it recurred
in *every* branch of this build including the ones written to fix it.

| Shape | How it hides | Countermeasure |
|---|---|---|
| **Assertion satisfied by its own fixture** | greps a word that appears in the fixture's temp filename, its own input string, or its own heading | never grep a token the fixture supplies; grep a fixed sentence from the *source*; check the assertion against corollary (c) before committing |
| **Assertion satisfied by a different guard** | the setup trips an earlier check, so the test passes for the wrong reason and the named guard is never reached | choose an input that *only* the guard under test refuses; verify by neutering that guard alone |
| **Claim outruns code** | a spec line, code comment, or playbook asserts enforcement nothing implements | every claim of enforcement names its enforcer, or is reworded; a `MUST prove` bullet without a prover is a defect |
| **Enumerated instead of derived** | the guard lists what the author pictured, so a variant the author didn't picture passes | derive the check from the real data, bidirectionally (the one guard built this way found a genuine pre-existing bug nobody knew about) |
| **Unrealistic fixture input** | a security fixture uses sanitized placeholders that lack the real shape of the thing being caught | security fixtures must use the real alphabet/shape; assert the *property that decides the outcome*, not an incidental one (length is not the alphabet) |

Plus the fail-closed rule already adopted mid-build: **every fail-closed / refuse / skip assertion must key on a
discriminating artifact unique to that path** (a unique stderr marker, a distinct exit code), never the shared
outcome — and needs a positive control proving the marker is absent otherwise.

## B. Named, deferred with an owner

| id | Item | Why deferred | Owner |
|---|---|---|---|
| **V-AUTH (Part 4b)** | Transition-scoped path authorization, staged 1→2→3: contract-scoped entry mint, claim-time mint + finish re-mint, then adapters echo identity and the gate requires it. Also absorbs NEW-3 (no TTL renewal — flat 4 h, no `renew` verb) and NEW-5 (live-tracker comparison, satisfied structurally by claim-time minting). | Not started. It rewrites `scripts/idc_path_gate.py`, which the V-PIN/V-DOOR branch is actively editing — two writers on one file is how work gets lost. It also needs a full install-sandbox Build lifecycle receipt, not a smoke run. | next session, after 4a merges |
| **D1** | Codex has NO per-tool gate. `scripts/install-codex.sh` wires zero hooks (337 lines, all skill symlinks); Codex is covered only by the git backstop. Spec §3.2:167 mandates coverage. | Own unit — needs research into what Codex's runtime actually supports before designing an adapter. NOT a V-AUTH stage-3 blocker: the git backstop is Codex's request path and can echo identity like the others. | next session |
| **doctor writes while claiming read-only** | `commands/doctor.md:7` says checks are "read-only for source files and tracker/board state"; the run's Row 10 created `docs/workflow/reconciliation-seen-findings.json` in the governed tree. Verified independently by the lead. The write is in the janitor seen-ledger path (`scripts/idc_reconciliation_baseline.py::record_seen_findings`, wired from `scripts/idc_git_janitor.py`). | Pre-existing; found by this build's sandbox e2e. Its surface belongs to a branch already at its final fix round, and the 2-round cap exists precisely to stop a relay sprawling. | next session |
| **second spec file, same overstatement** | `docs/specs/reconciled-execution-graph-receipts-active-janitor-spec.md:692` and `:972` both still claim the janitor "halts after three non-converging passes" — the overstatement the primary spec corrected this build. | Outside the ownership any branch was given; three writers were concurrent. | next session, one-line each |
| **NEW-4** | No sanctioned finisher/merge helper for **Pi**. Claude and Codex self-merge through `idc_pr_finish.py` / `idc_git_finish.py`; only Pi requires the operator to merge. | Pi-runtime unit, not pathway-integrity. | Pi runtime owner |
| **NEW-6** | The required check's workflow definition is PR-head-controlled: a PR can keep the job name and replace the run step with `exit 0`. Compensating control is CODEOWNERS review (verified present). | The real fix is an org-level required check or a pinned reusable workflow a PR head cannot redefine — needs org admin. | operator |
| **NEW-9** | `app-locked` mode's live write path is unreceipted: a GitHub App cannot write user-owned Projects v2, so proving it needs an ORG-owned board. | Platform constraint + provisioning. | operator |
| **NEW-10** | `pi-runtime` full-drain e2e never run (closed by proxy coverage); `update-adoption` and `claude-hook-fidelity` never re-driven at the final head. | Belongs to an e2e wave, not a build unit. | next e2e wave |
| **NEW-11** | `GIT_NO_LAZY_FETCH=1` deliberately unset, so a blobless/treeless partial clone still makes a network fetch during ruleset dry-run. One-line flip. | Genuine operator policy choice: strict (refuse partial clones) vs permissive (today). | operator preference |
| **NEW-13** | `_gh_json_all_pages` / `_MAX_LISTING_PAGES` duplicated between `idc_ruleset_check.py` and `idc_ruleset_install.py`. | Pure refactor, zero behaviour change, low value. | opportunistic |

## C. Adjudicated this build — do NOT reopen

- **F3** (deny requests carrying no identity) — the literal change denies every legitimate edit from all three
  runtimes; no adapter sends identity. The durable fix is V-AUTH stage 3. Settled.
- **F42** (dotted-directory rule over-refuses) — accepted tradeoff, safe direction.
- **M5** (a receipt-writer drift check believed reachable) — adjudicated by a round-2 reviewer across five
  executed experiments: it was genuinely unreachable, the round-1 reviewer had quoted a different guard's
  sentence. The duplicate was deleted and nothing was lost.
- **B1(a)** (a spec `MUST prove` bullet with no enforcer) — moving the sentence rather than building the enforcer
  was correct: a satisfying ordering exists only in a plan shape the shipped Plan never produces.
- **The "breaking change" I flagged mid-build was NOT one.** `idc_ruleset_check.py` / `idc_ruleset_install.py`
  are invoked by no shipped command, agent, skill or template — they govern this repo via its own CI. No
  downstream governed repo is affected, and no release-note warning is needed.
