# PR 182 — IDC convergent pathway integrity 5.0.0

**Scope:** `71d711ad6be9e5346597ddff8e7cf8dc8df94259..9e50a1ea553e5267cdb88ef68ba6a7899eb714a1` — 80 commits, 163 files, +21,759 / -778 lines  
**PR:** #182 — `release: IDC convergent pathway integrity 5.0.0 (U1-U13) — operator review required, do not merge`  
**Verdict:** FAIL/BLOCKED  
**Risk tier:** full  
**Packet:** `.code-review/runs/20260726-232053-pr-182-pathway-integrity`  
**Reviewer completion:** 8/8 required reviewers succeeded  
**Polish mode:** Not requested — default read-only review  
**Counts:** 7 Blocker · 5 Major · 1 Minor · 2 Nit

| # | Dimension | Result |
|---:|---|---|
| 1 | Repo Protocol | FAIL — the required check does not enforce the spec's evidence boundary; ownership coverage is absent; Pi merge behavior contradicts the general autonomous contract |
| 2 | Schema & Contract Drift | FAIL — planning receipts can be forged, unverified planning digests enter Build contracts, and the configured attempt ceiling is ignored |
| 3 | Error Handling Integrity | FAIL — an invalid pathway mode is silently converted to `off`; the recovery authorization rollback failure path lacks a regression |
| 4 | Resource Management | Cleared statically — no separate high-confidence leak or cleanup defect found |
| 5 | Security | FAIL — the required check runs candidate-controlled validation code; the public authorization CLI can mint grants; ticket/graph identity is not enforced |
| 6 | Stack Gotcha Audit | No separate finding beyond the configuration parser and exact-SHA issues reported below |
| 7 | Unit-Test Rigor | FAIL — critical recovery and handle-backed contract paths lack focused end-to-end coverage |
| 8 | Integration-Test Gap | FAIL — app-locked remains unexecuted and no live ruleset/API verification was performed in this review |
| 9 | Dependency & Bloat | PASS — trusted audit found no dependency or lockfile changes |
| 10 | Complexity Budget | No standalone finding; the large enforcement surfaces were reviewed by dedicated security/error lenses |
| 11 | Git-History Narrative | PASS-WITH-NITS — 91 mechanical narrative flags across 80 commits; correctness-neutral |
| 12 | Stale-Docs Sweep | FAIL — Pi/manual-merge behavior conflicts with general automerge claims; one seen-ledger description overstates suppression |
| 13 | Simplification Applied | Not requested — default read-only review |

## Reviewer results

| Reviewer | Required | Status | Verdict | Findings |
|---|---|---|---|---:|
| protocol-reviewer | yes | accepted | fail | 3 |
| type-design-analyzer | yes | accepted | fail | 3 |
| silent-failure-hunter | yes | accepted | fail | 3 |
| test-analyzer | yes | accepted | fail | 2 |
| comment-analyzer | yes | accepted | pass-with-nits | 1 |
| security-reviewer | yes (sensitive scope) | accepted | fail | 3 |
| dependency-audit | yes (script dimension) | accepted | pass | 0 |
| git-narrative | yes (script dimension) | accepted | pass-with-nits | 1 |
| coordinator-inline | no | accepted | fail | 1 |

## Blocker

### 1. Required pathway check is self-verifying

**Location:** `.github/workflows/idc-pathway-integrity.yml:30`  
**Confidence:** 0.98  
**Reviewers:** security-reviewer, silent-failure-hunter

The workflow checks out the PR head and runs `scripts/idc_pathway_check.py` from that same untrusted head (`:30-44`). The checker only tests head/source strings and path existence (`scripts/idc_pathway_check.py:87-115`); the entire hook surface is reduced to the existence of `scripts/hooks` (`:45-51`).

**Failure:** A PR can weaken the checker, remove a load-bearing hook while leaving the directory, or weaken validation code, then make its own required check green.

**Unblock:** Run trusted, base-controlled or immutably pinned checker code and validate the protected content, not merely path existence.

### 2. Public authorization CLI can mint repo-wide grants

**Location:** `scripts/idc_path_gate.py:401`  
**Confidence:** 0.96  
**Reviewer:** security-reviewer

`write_authorization()` accepts a repo/session/command and defaults omitted limits to the whole repo plus `write`/`edit`/`git` (`:401-449`). The public `authorize` subcommand exposes that writer without an admission-only nonce (`:586-627`), while the interlock exempts plugin scripts from inspection (`scripts/hooks/idc_interlock_gate.py:705-711`).

**Failure:** Any active command record—including a read-only command record—can be used to mint or renew a broad mutation grant outside the entry-gate transaction.

**Unblock:** Remove the public minting door or require an admission-only capability unavailable after command expansion, and deny direct invocation through the interlock.

### 3. Ticket and graph-node checks are optional in practice

**Location:** `scripts/idc_path_gate.py:533`  
**Confidence:** 0.99  
**Reviewer:** coordinator-inline

The core compares ticket and graph identity only if the request supplies them (`:533-538`). Claude, Pi, and Git adapters submit only action/path or raw-reason fields, while authorization defaults to repo-wide paths and `command:<command>` graph identity.

**Failure:** Mutations for another ticket or graph node omit both identities, skip both comparisons, and pass the repo-wide path grant despite spec §3.2 requiring denial.

**Unblock:** Mint non-null ticket/graph/path scopes from the claimed transition; require them on every mutation request; deny missing identity; compare with live tracker state.

### 4. Required check omits the spec's evidence-bound merge gate

**Location:** `scripts/idc_pathway_check.py:6`  
**Confidence:** 0.99  
**Reviewer:** protocol-reviewer

Spec §2.3 requires merge refusal when tracker, graph, journal, authorization, validation, review, or finish evidence is missing, stale, corrupt, or divergent. The only required checker explicitly evaluates just exact head, source token, and protected-surface presence (`:6-24,87-116`).

**Failure:** A PR with missing or stale pathway evidence can satisfy the required status check.

**Unblock:** Make the required check validate every evidence class in spec §2.3, or narrow the published contract so it no longer claims that behavior.

### 5. Planning receipt verifier accepts hand-forged receipts

**Location:** `scripts/idc_planning_receipt.py:273`  
**Confidence:** 0.99  
**Reviewer:** type-design-analyzer

The writer emits `written_by` and `receipt_digest` (`:232-260`), but `verify_receipt()` neither requires the writer field nor recomputes the receipt digest (`:273-305`).

**Failure:** A caller can construct or edit a receipt whose embedded projection matches the current board and have Plan closeout accept it as machine-owned.

**Unblock:** Require the source owner, recompute `receipt_digest`, and add a matching-board tamper regression.

### 6. Protected-surface ownership is absent but validation passes

**Location:** `scripts/idc_ruleset_check.py:117`  
**Confidence:** 0.97  
**Reviewers:** protocol-reviewer, security-reviewer

The ruleset enables code-owner review but admits it only works once CODEOWNERS names the surfaces. The PR head has no CODEOWNERS file, and `validate_contract()` checks only that four string classes appear (`:117-139`).

**Failure:** Local validation and update can report the ownership boundary valid when no protected surface has an owner.

**Unblock:** Add CODEOWNERS coverage for every protected surface and make deterministic validation reject absent or incomplete ownership.

### 7. Build contracts trust unverified planning receipt digests

**Location:** `scripts/idc_validation_contract.py:393`  
**Confidence:** 0.97  
**Reviewer:** type-design-analyzer

`_planning_receipt_info()` checks only a caller-controlled `written_by` string, then copies graph/projection/final digests without invoking the planning receipt verifier (`:393-404`).

**Failure:** A repo-local edited receipt can inject arbitrary graph/projection bindings into the frozen Build contract.

**Unblock:** Fully verify the planning receipt—including digest, repo identity, and live readback—before borrowing any binding.

## Major

### 1. Pi behavior contradicts the general automerge contract

**Location:** `runtime/pi/.pi/agents/idc/build-finisher.md:9`  
**Confidence:** 0.95

README and architecture say IDC automerges when green, while Pi Build/Plan/Recirculator prompts now stop for an operator merge because no sanctioned helper exists.

**Unblock:** Wire Pi through the sanctioned finisher helpers, or explicitly exclude Pi from the autonomous merge claims everywhere those claims appear.

### 2. Recovery authorization rollback is untested

**Location:** `scripts/hooks/idc_command_entry_gate.py:293`  
**Confidence:** 0.93

The invalid-receipt recovery branch now registers and authorizes under the admission transaction, but the focused regression harness exercises only normal `build` admission.

**Unblock:** Drive a recovery command through authorization failure and prove both the active record and prior authorization snapshot are restored.

### 3. Invalid pathway mode is reported as honest `off`

**Location:** `scripts/idc_doctor_pathway_check.py:139`  
**Confidence:** 0.96

`PG.pathway_mode()` converts unknown values such as `controllled` to `off`; Doctor then reports that as an honest posture. Runtime enforcement also observes/allows because it sees `off`.

**Unblock:** Distinguish explicit `off` from missing/unknown/malformed values and make unknown state indeterminate or denied.

### 4. Configured attempt ceiling is ignored

**Location:** `scripts/idc_validation_contract.py:409`  
**Confidence:** 0.94

The repo config owns `pathway_enforcement.attempt_ceiling`, and the spec says contracts default from it, but both function and CLI hard-code `3` (`:409,599`).

**Unblock:** Read the repo config when the CLI flag is omitted and test a non-default value end to end.

### 5. Handle-backed validation path lacks end-to-end coverage

**Location:** `scripts/idc_validation_contract.py:428`  
**Confidence:** 0.96

Registry tests stop at resolver/audit behavior; validation tests use explicit commands. No test freezes via `--handle-id`, executes the resolved command, and proves handle metadata survives into execution and Build receipts.

**Unblock:** Add that end-to-end regression across contract, execution receipt, and Build receipt.

## Minor

### 1. Exact-head checker accepts abbreviated SHAs

**Location:** `scripts/idc_pathway_check.py:60`  
**Confidence:** 0.86

The checker promises an exact head but accepts a matching hexadecimal prefix of seven or more characters.

## Nit

### 1. Commit history has mechanical narrative flags

**Location:** `CHANGELOG.md:1`

The trusted history audit emitted 91 subject/body flags across 80 commits. Full raw evidence is in `packet/git-narrative.json`; this does not affect correctness.

### 2. Seen-ledger documentation overstates suppression

**Location:** `agents/idc-review-agent.md:72`

The doc says any previously seen fingerprint is suppressed; the helper suppresses only terminal non-routable dispositions.

## Test gaps

- No live GitHub ruleset/API validation was performed in this read-only review.
- Candidate code and tests were not executed; the review skill forbids executing code from the diff.
- No runtime test denies a mutation request that omits ticket/graph identity.
- No tamper test covers a planning receipt that still matches live board state.
- No non-default `attempt_ceiling` test proves config-to-contract propagation.
- No recovery-command negative test proves authorization rollback.
- No `--handle-id` end-to-end validation/build receipt test exists.
- The app-locked live lane remains an unexecuted/blocked path.

## Surfaces cleared

- Reviewer completeness — all six required subagents and both script dimensions validated on the first attempt.
- Dependency surface — no package manifest or lockfile changes.
- CI permissions — the new workflow is read-only (`contents: read`) and does not use `pull_request_target`.
- Secrets — no newly introduced hardcoded credential values found in the reviewed security-sensitive files.
- Direct interpreter sinks — no new `shell=True`, `os.system`, or `eval` sink found in the reviewed process-launch changes.
- Git hook backstops — focused tests cover hook install/rollback, new-ref path collection, and signal handling.
- Build receipt freshness — current code binds issue, PR, head, diff, verdict, and execution receipt.
- Reconciliation adoption — baseline-pending behavior and receipt-last logic have focused smoke coverage.

## Verification receipts

- `gh pr view 182 --json ...` — PR open, non-draft, mergeable; head pinned to `9e50a1ea553e5267cdb88ef68ba6a7899eb714a1`; reported checks successful at review time.
- `git merge-base <base> <head>` — exact base is the merge base.
- `git rev-list --count <base>..<head>` — 80 commits.
- `git diff --shortstat <base>...<head>` — 163 files, +21,759 / -778.
- `build-review-packet.sh` — packet created successfully.
- `classify-review-scope.sh` — `full`, 22,537 reviewable lines, 163 reviewable files, sensitive scope.
- `audit-dependencies.sh` — no findings.
- `check-commit-narrative.sh` — 80 commits audited; 91 mechanical flags.
- `validate-reviewer-output.py` — all 8 required lanes plus coordinator-inline valid on first attempt.
- `consolidate-review-findings.py` — complete run; overlaps manually deduplicated to 15 findings.

## Verification limits

This was a static, read-only review of the exact Git objects. The current working checkout is not the PR head. No source files were edited, no candidate tests or scripts were run, no sandbox lifecycle was driven, no live ruleset was installed or queried, and nothing was posted to GitHub.
