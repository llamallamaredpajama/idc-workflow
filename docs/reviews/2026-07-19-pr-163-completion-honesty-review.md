# PR #163 Completion Honesty Review

Scope: `7f4860684c5315f7dc6b345b0b9184ebf5648614..aa4879f4b405546a4d69b827fddd97e91766242f` (17 commits, 52 files, +6745 / -292 lines)

**Verdict:** FAIL/BLOCKED

**Risk tier:** full

**Packet:** `.code-review/runs/20260720-045319-pr-163-completion-honesty`
**Reviewer completion:** 8/8 required review lanes succeeded

| # | Dimension | Result |
|---:|---|---|
| 1 | Repo Protocol | 4 Major — emitted cure paths, autorun failure handling, resume closeout, and pause lifecycle |
| 2 | Schema & Contract Drift | 4 Major — durable finish record, strict ledger proof, resume proof, pause-record trust |
| 3 | Error Handling Integrity | 5 Major, 2 Minor — git probe, pause/resume errors, persistence, and lost diagnostics |
| 4 | Resource Management | 0 findings — subprocess groups, bounded capture, temporary files, and atomic cleanup reviewed |
| 5 | Security | 1 Blocker, 3 Major — redaction boundary, commit attribution, freshness, and path confinement |
| 6 | Stack Gotcha Audit | 2 Major — tolerant state reads and working-tree/commit identity |
| 7 | Unit-Test Rigor | 5 gaps tied to Major or Blocker findings |
| 8 | Integration-Test Gap | 6 cross-component paths lack the failure-mode test that would expose the defect |
| 9 | Dependency & Bloat | 0 findings — dependency audit passed; no dependency-source change |
| 10 | Complexity Budget | 0 findings — no material unbounded or superlinear path found |
| 11 | Git-History Narrative | 1 Nit — four subject-style issues across 17 commits |
| 12 | Stale-Docs Sweep | 1 Major, 2 Minor — accepted limits overstated, command table stale, handoff obsolete |
| 13 | Simplification Applied | Not requested — default read-only review |

## Reviewer results

| Reviewer | Required | Status | Verdict | Findings |
|---|---|---|---|---:|
| protocol-reviewer | yes | accepted | fail | 1 |
| type-design-analyzer | yes | accepted | fail | 4 |
| silent-failure-hunter | yes | accepted | fail | 6 |
| test-analyzer | yes | accepted | fail | 2 |
| comment-analyzer | yes | accepted | fail | 5 |
| security-reviewer | yes | accepted | fail | 4 |
| dependency audit | yes | accepted | pass | 0 |
| git-history narrative | yes | accepted | pass-with-nits | 1 |
| senior code reviewer | supporting | accepted | fail | 2 |

## Accepted limits

These are known product boundaries, not demands to expand this PR:

- IDC does not inspect cloud resources or permissions directly. Out-of-band cloud and permission drift is found only when the project-authored `verify:` command actually exercises the broken behavior.
- The audit trusts the local evidence file. A determined agent can still fabricate it; this PR is expected to remove cheap and accidental false-green routes, not provide cryptographic provenance.

Finding 13 asks only that shipped wording state those boundaries honestly. Findings about dirty code, stale verifier scripts, and credential leakage are cheaper accidental paths inside the feature's claimed contract, so they remain merge blockers.

## Blocker

1. **Credential context can be truncated before redaction.** `scripts/idc_live_check.py:601` takes the last 4 KB first and redacts second. If the cutoff removes a label such as `password=` but keeps its short value, the remaining value no longer matches a contextual rule or the 40-character fallback and is written to the committed evidence file. Redact the full already-bounded buffer before taking the display tail, then add a boundary-straddling credential regression that checks every persisted and printed surface. Confidence: 0.98.

## Major

1. **The merge still proceeds when its recovery obligation did not persist.** `scripts/idc_git_finish.py:156-167,801-804` treats `mid_finish` as best-effort, while the ledger API drops its atomic writer's false return. The irreversible merge is unconditional. A disk, permissions, or replace failure followed by process death can therefore recreate the exact merged-PR / stale-board state this PR claims to prevent, with no record for recovery. Require a successful write plus readback before `pr_merge`, and prove with a forced-write-failure test that merge is never reached. Confidence: 0.99.

2. **Printed recovery commands cannot run as written.** `scripts/idc_pause_check.py:86-101` and `scripts/hooks/idc_stop_fixpoint_gate.py:348,364,476` emit `${CLAUDE_PLUGIN_ROOT}` from Python runtime strings. That token is substituted only in shipped command/agent/skill Markdown; in a normal shell it becomes empty and points at `/scripts/...`. Resolve the real plugin root in Python and test that every emitted cure names an existing helper and contains no literal token. Confidence: 0.99.

3. **A corrupt obligation ledger is treated as proof that nothing is half-done.** `scripts/idc_pause_check.py:190-201` uses the ledger's tolerant reader, which collapses missing, unreadable, malformed, and wrong-shaped state to an empty list. A hidden `mid_finish` or `recirc_checkpoint` can therefore yield `pause-ready: ok`. Add a strict proof-reading API that treats a genuinely absent ledger as empty but an existing unreadable or invalid ledger as indeterminate, and cover both cases. Confidence: 0.99.

4. **Operational Git failures become a clean `not-applicable` result.** `scripts/idc_finish_coherence.py:175-183` maps every nonzero `git rev-parse` result to exit 0, discarding stderr. Corruption, unsafe ownership, an unreadable checkout, or a bad path can therefore disable the shipped-versus-board check. Reserve `not-applicable` for the explicitly supported non-Git filesystem case; fail with exit 2 and bounded diagnostics for every operational failure and for GitHub-backed repos without valid Git state. Confidence: 0.98.

5. **Autorun continues after automatic resume fails.** `commands/autorun.md:67-75` and `agents/idc-autorun.md:61-70` document only successful/no-op resume outcomes. If deletion fails, the CLI exits 2 and deliberately leaves the pause record, but the playbook still proceeds toward recovery and drain work while the Stop hook can later excuse an undrained exit. Both playbooks must abort before any mutation or dispatch on a nonzero/error outcome, with an integration test proving the next step is not run. Confidence: 0.96.

6. **A pause-record deletion failure gives `/idc:resume` no legal terminal outcome.** `commands/resume.md:39-43` correctly says to stop, but `scripts/idc_command_contract.py:284-299,449-459` makes `complete` impossible while the record survives and allows `blocked_external` only when the unrelated quiescence helper is currently failing. A readable but undeletable record leaves the lifecycle open forever. Add a source-owned, re-derived pause-state failure receipt as a legal blocker, and cover `ClearFailed` through command closeout. Confidence: 0.97.

7. **`resume complete` does not prove the quiescence check in its own instructions ran.** `scripts/idc_command_contract.py:449-465,2700-2703` requires only that the record is absent and the next-action oracle is readable. Clearing a failed `pause-requested` record can therefore close complete while an item or checkpoint remains half-done. Add a fresh exit-0 pause-check claim to explicit resume and require the same check before automatic autorun resume dispatches work. Confidence: 0.96.

8. **The Stop hook trusts any JSON object containing `state: paused`.** `scripts/hooks/idc_stop_fixpoint_gate.py:154-163,460-465` bypasses the drain before validating the rest of the record or its lifecycle. A minimal handwritten record, or a real record that became stale after work resumed, buys an undrained stop; the test suite checks forgery only through command closeout, not through this hook. Bind the bypass to a complete, lifecycle-backed confirmed record that is invalidated when work resumes, and add forged and stale-record Stop-hook regressions. Confidence: 0.98.

9. **The normal pause journey refuses its own active command record.** `scripts/idc_pause_state.py:239-255` walks every active command. A real `/idc:pause` has an active `pause` record opened by the entry gate, but `pause` is not in the pausable set, so `close-open` always emits `REFUSED` and exits nonzero. The smoke test opens only `autorun`, hiding the defect. Skip the current pause lifecycle record while closing the interrupted pipeline records, and test both active records together. Confidence: 0.99.

10. **A dirty working tree can produce evidence falsely attributed to `HEAD`.** `scripts/idc_live_check.py:897-908` records the current commit but executes scripts and product files from the mutable working tree. A temporary local verifier edit can produce a passing receipt for committed code that never ran. Execute in an isolated checkout pinned to the recorded commit, or reject dirty tracked and untracked inputs except controlled evidence outputs; add the corresponding regression. Confidence: 0.99.

11. **Changing the verifier implementation does not necessarily expire old evidence.** `scripts/idc_live_check.py:840-847` checks only declared surface paths; command identity hashes the unchanged command text. The shipped example runs `scripts/verify-live-web.sh` but does not include that script in `paths`, so a verifier-only commit leaves prior evidence current. Require explicit verifier implementation paths, include them in freshness, and test a verifier-only change. Confidence: 0.98.

12. **Evidence output can escape the repository and overwrite another file.** `scripts/idc_live_check.py:473` accepts absolute paths and traversal, and the default path incorporates an unvalidated surface name. Later writes create parents and truncate the resolved target. Require a normalized repository-relative destination, reject path-like names, prove the resolved target remains below the repo, reject symlink escapes, and test all four cases. Confidence: 0.97.

13. **Shipped documentation contradicts the two accepted limits.** `templates/WORKFLOW.md:239-252` calls the receipt machine-generated, says verification is never attested, and claims provisioning drift cannot hide. The same overclaim appears in the template config, Build agent, changelog, architecture, development note, and live-check docstring. The audit has no provenance check and path expiry sees committed repo changes, not direct cloud or permission drift. State the local-evidence trust boundary and the verify-script-only cloud detection limit consistently everywhere. Confidence: 0.99.

## Minor

1. **Stop blocks hide the item or surface that caused them.** `scripts/hooks/idc_stop_fixpoint_gate.py:184-196` keeps only the final drain token and counts, then tells the operator to inspect a finding line it discarded. Carry the bounded coherence/live/acceptance line into the block text. Confidence: 0.99.

2. **Checker crashes lose the useful error.** `scripts/idc_autorun_drain.py:442-455` captures stderr but returns only a generic “no verdict” when the checker exits before its stdout token. Include the return code and a bounded, credential-safe stderr tail. Confidence: 0.97.

3. **The public command table is stale.** `README.md:182-195` still says ten commands and omits `intake`, `pause`, and `resume`, while the release correctly advertises 13 elsewhere. Confidence: 1.00.

4. **The new integration handoff is already obsolete.** `docs/dev/pause-resume-autorun-integration.md:3-18` says autorun integration, command counts, changelog, and version bump remain undone even though all are present at this head. Remove it or mark it explicitly completed/historical. Confidence: 1.00.

## Nit

1. **Four commit subjects miss repository history style.** `55607d2` is 92 characters; merge commits `ac967bf`, `6e894fa`, and `e970df0` are not Conventional Commits, and `e970df0` is also 75 characters. This does not affect the merge verdict.

## Test gaps

- Force the `mid_finish` write/readback to fail and assert the merge stub is never called.
- Put a short named credential across the output-tail boundary and assert it is absent everywhere.
- Exercise the real simultaneous `autorun` plus `pause` lifecycle through `close-open`.
- Drive pause-record deletion failure through explicit resume closeout and autorun preflight, with a sentinel proving no later step runs.
- Corrupt or make unreadable a ledger that previously contained a half-done taint.
- Combine an undrained orchestrator session with forged and stale confirmed-pause sidecars at the Stop hook.
- Cover dirty verifier inputs, verifier-only commits, absolute/traversal destinations, and symlink escapes.
- Make the Git probe fail operationally rather than because the fixture is simply non-Git.
- Add behavior-level coverage for the new GitHub-backend owner/project/project-item branches; current end-to-end coverage is filesystem-only.

## Surfaces cleared

- Release metadata agrees on version 4.2.0 and 13 command files across both manifests, the registry, and hook matcher.
- Dependency audit found no new dependency or source change.
- Candidate credential literals in the diff are synthetic scrubber fixtures; no hardcoded credential was found.
- The repository-authored verify command is the intended shell boundary; no board, PR, or captured-output value is concatenated into it.
- Subprocess timeout handling kills process groups and capture size is bounded.
- Captured output cannot plant a second parseable live-evidence marker; the writer neutralizes marker text and the reader anchors to the final marker.
- Drain-verdict v1 compatibility remains readable but cannot prove the new completion gates ran.
- The normal readable `mid_finish` recovery path is cross-session, board-first, idempotent, and preserves unresolved obligations.
- The new smoke suites cover broad happy-path and ordinary failure behavior for filesystem coherence, live verification, recovery, pause/resume, credential scrubbing, and broken pipes.

## Verification receipts

- GitHub reported PR #163 open and mergeable at reviewed head `aa4879f4b405546a4d69b827fddd97e91766242f`; its CI check was green when the review began.
- `git diff --check 7f4860684c5315f7dc6b345b0b9184ebf5648614..aa4879f4b405546a4d69b827fddd97e91766242f` — clean.
- Dependency audit — pass, no findings.
- Git-history audit — 17 commits reviewed; four style nits after manual triage.
- This was a static review. In accordance with the review harness, candidate code and tests were not executed locally. GitHub's green workflow is useful evidence, but it does not cover the failure modes above.

No review was posted to GitHub, and no merge was attempted.
