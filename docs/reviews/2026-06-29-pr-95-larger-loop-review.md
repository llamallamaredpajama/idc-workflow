# PR 95 Larger Loop Review

Scope: `fb260431e4db37d0651a955aede95a5a5f8f6d2e..eb0a1124693a0857fb0ff16a60a363521652d3ac` (10 commits, 18 files, +1052 / -38 lines)
**Verdict:** FAIL/BLOCKED
**Risk tier:** full
**Packet:** `.code-review/runs/20260629-151848-pr-95-larger-loop`
**Reviewer completion:** 8/8 required reviewers succeeded

## 13-Dimension Coverage

| # | Dimension | Mode | Status | Evidence |
|---|---|---|---|---|
| 1 | Repo Protocol | subagent accepted | FAIL | Grant path can authorize shipped instruction/playbook files; build command parity drift. |
| 2 | Schema & Contract Drift | subagent accepted | FAIL | Missing cap counter protocol; `grant.change` dropped. |
| 3 | Error Handling Integrity | subagent accepted | FAIL | Malformed ticket/path values can still route. |
| 4 | Resource Management | inline | PASS | No new long-lived resources or cleanup-sensitive handles in reviewed code. |
| 5 | Security | subagent accepted | FAIL | Line-protocol injection and overbroad grant paths. |
| 6 | Stack Gotcha Audit | inline | PASS-WITH-NITS | zsh loop and GitHub pagination gotchas are covered by changed tests/docs; no new stack-specific blocker found. |
| 7 | Unit-Test Rigor | subagent accepted | FAIL | No stdout-empty assertion for fail-closed closeout; mixed-blocker case missing. |
| 8 | Integration-Test Gap | inline | PASS-WITH-NITS | PR body claims e2e, but this review did not rerun live sandbox e2e; report keeps that verification limit explicit. |
| 9 | Dependency & Bloat | script fallback accepted | PASS | Helper absent; fallback found no dependency manifest/lockfile changes. |
| 10 | Complexity Budget | inline | PASS-WITH-NITS | Large prose feature is understandable, but closeout protocol should become structured rather than adding parser rules around strings. |
| 11 | Git-History Narrative | script fallback accepted | PASS | Helper absent; 10 commits are coherent conventional feature/fix/simplify stack. |
| 12 | Stale-Docs Sweep | subagent accepted | PASS-WITH-NITS | Minor stale one-shot header and missing Row 9b dropped-handoff classification. |
| 13 | Simplification Applied | status row | PASS | Not requested - default read-only review. |

## Reviewer Results

| Reviewer | Required | Status | Verdict | Findings |
|---|---|---|---|---:|
| protocol-reviewer | yes | accepted | fail | 2 |
| type-design-analyzer | yes | accepted | fail | 4 |
| silent-failure-hunter | yes | accepted | fail | 2 |
| security-reviewer | yes | accepted | fail | 2 |
| test-analyzer | yes | accepted | fail | 3 |
| comment-analyzer | yes | accepted | pass-with-nits | 2 |
| dependency-bloat | yes | accepted | pass | 0 |
| git-history-narrative | yes | accepted | pass | 0 |

## Summary

PR #95 completes substantial larger-loop wiring, but the review found multiple high-confidence Major issues in the new closeout/trivial-grant contract. The central problem is that the validator accepts untrusted JSON, validates part of it, then emits a lossy whitespace-delimited line for a parent that is explicitly documented as a dumb router. That creates both injection/misrouting risk and contract drift around what Build is actually allowed to do.

## Blocker

None.

## Major

1. **Closeout dispatch is an unstructured line protocol fed by untrusted fields**
   - Location: `scripts/idc_recirc_closeout.py:104`
   - Category: `security`; confidence: 0.97; reviewers: security-reviewer, silent-failure-hunter, test-analyzer
   - Evidence: The validator emits `dispatch: launch-plan consideration=... ticket=...`, `dispatch: notify-gated think_pr=... ticket=...`, and `dispatch: grant-build issue=... paths=... ticket=...` using raw closeout values. `ticket` is not type-checked, routed values are not delimiter/control-character safe, and malformed-closeout tests discard stdout instead of proving no dispatch line is emitted.
   - Failure path: A malformed or hostile closeout can still produce a routable line with ambiguous tokens, spoofed ticket fields, or extra delimiters while the parent is documented as a dumb router that acts on the line.
   - Unblock: Use structured JSON for the validated dispatch payload, or fail closed on unsafe scalar values and assert malformed inputs emit zero stdout.
   - Fingerprint: `5f85dc70eb410f978afc7f7a55d22ae3429d32a1cd442648f78bfae62b26ecba`

2. **Trivial grants are broader than the canonical-doc exception they are meant to authorize**
   - Location: `scripts/idc_recirc_closeout.py:56`
   - Category: `security`; confidence: 0.96; reviewers: security-reviewer, protocol-reviewer, silent-failure-hunter
   - Evidence: `_is_canonical_doc_path()` accepts any `docs/` prefix, any repo-relative `*.md`, and any `*.schema.json`. That includes directories such as `docs/workflow`, shipped instruction/playbook markdown under `agents/` and `commands/`, and symlink-looking doc paths because no realpath/file check exists.
   - Failure path: A trivial closeout can authorize Build to edit governing instruction files or a whole docs subtree through the tiny doc-PR path, bypassing the normal recirculation sync/gate discipline.
   - Unblock: Restrict trivial grants to explicit subordinate artifact files, reject directories/symlinks/shipped instruction surfaces, and resolve allowed paths against the repo root before granting Build write permission.
   - Fingerprint: `45c24cb4b867f7de048d68d3a8b112ba52e5627870befc3f474408ead5fffba2`

3. **Validated `grant.change` is dropped before Build receives the trivial grant**
   - Location: `scripts/idc_recirc_closeout.py:126`
   - Category: `contract`; confidence: 0.96; reviewers: type-design-analyzer
   - Evidence: The helper requires `grant.change` but emits only `issue`, `paths`, and `ticket` in the `grant-build` dispatch line. The Build playbook says the consultant grants permission for one specific canonical-doc change, but the routed payload loses that specific change.
   - Failure path: Build can make unrelated edits within an approved path because the only data it receives is the path list, not the approved change.
   - Unblock: Carry the validated `change` through the dispatch payload, preferably as part of a structured validated grant object, and test that the consumer sees it.
   - Fingerprint: `ccfd9a301006ba358cfed813f9c53e5d4885441790723065c2b0abc7e30d34e1`

4. **Runaway-cap counters are required by Build but absent from the producer protocol**
   - Location: `agents/idc-build.md:101`
   - Category: `contract`; confidence: 0.97; reviewers: type-design-analyzer
   - Evidence: Build requires `idc_recirc_caps.py --recirc-count <n> --cascade-depth <d>`, while the structured closeout contracts in the recirculator docs and validator define no count/depth fields or authoritative board source.
   - Failure path: A runtime cannot enforce the advertised park-not-churn bound without inventing or skipping these inputs.
   - Unblock: Define and validate the count/depth source in the recirculator-to-Build protocol, or derive it deterministically from board state before consulting the caps helper.
   - Fingerprint: `742d2cfde574bbda75d72fc58d0c9e2f86b324812918bd8ea3ac6ef10b16c6e6`

5. **`/idc:build` command parity still forbids the new trivial doc-edit exception**
   - Location: `commands/build.md:37`
   - Category: `protocol`; confidence: 0.95; reviewers: type-design-analyzer
   - Evidence: The command entry says builders never edit canonical docs, while the updated Build playbook authorizes a `grant-build` trivial path for a separate tiny canonical-doc PR.
   - Failure path: A session bootstrapped from the command entry can reject or recirculate a valid trivial closeout instead of using the new path.
   - Unblock: Update `commands/build.md` to preserve the no-doc-edit rule with the precise consultant-authorized trivial exception.
   - Fingerprint: `4ba4410de4dce0278c490b4b0117e03eb6d790131e7d2208339fb751f6e45f3b`

6. **Closeout fail-closed tests do not verify the no-dispatch half of the contract**
   - Location: `tests/smoke/phase4-larger-loop.sh:68`
   - Category: `test-gap`; confidence: 0.96; reviewers: test-analyzer, security-reviewer
   - Evidence: The malformed-closeout helper `co_rc()` discards stdout and stderr, so the test suite only checks exit 2. The feature claim is stronger: malformed input must print no dispatch line.
   - Failure path: A helper that prints a dispatch line and exits 2 would still pass, leaving the parent with a routable action even on malformed input.
   - Unblock: Capture stdout for every malformed closeout case and assert it is empty; add delimiter/control-character/ticket-type adversarial cases.
   - Fingerprint: `d101b6abe6b11ea800d33de13990082137fcc4dca60c6a41c381784629e82716`

## Minor

1. **Retired-recirc rule over-reports mixed-blocker issues**
   - Location: `scripts/idc_board_lint.py:165`
   - Category: `protocol`; confidence: 0.96; reviewers: protocol-reviewer, test-analyzer, comment-analyzer
   - Evidence: The docs describe an issue whose only remaining blocker is a retired Recirculation ticket, but `retired_recirc_evidence()` returns on any retired recirc blocker and explicitly does not verify it is the sole remaining blocker.
   - Failure path: Doctor can tell the operator to re-point a paused issue that is still blocked by live work and is not spuriously eligible.
   - Unblock: Either enforce the sole/satisfied-blocker condition in code and add a mixed-blocker regression test, or narrow the docs/output wording to match the broader advisory.
   - Fingerprint: `19df8d23b416cb2ea4f54d7c404506cc7f63dae4207e63ce279b1b3dde2a8b4c`

2. **Doctor Row 9b does not classify dropped-handoff sweep output**
   - Location: `commands/doctor.md:258`
   - Category: `contract`; confidence: 0.91; reviewers: type-design-analyzer
   - Evidence: `idc_recirc_sweep.py` can now print `dropped larger-loop handoff` and `dropped handoff(s)`, but Row 9b only describes skipped/clean/rogue/ambiguous/capture/error outputs.
   - Failure path: A doctor run can surface a new finding class without command-level instructions for how to report or hint it.
   - Unblock: Add dropped-handoff output handling and fix hints to Row 9b.
   - Fingerprint: `9726ce6d5f48d92c7abeca3fe49e05f1fd137a057773584b91bd4e468685ab01`

3. **Autorun command header still says one-shot after adding fixpoint re-loop**
   - Location: `commands/autorun.md:2`
   - Category: `docs`; confidence: 0.98; reviewers: comment-analyzer
   - Evidence: The command body says re-loop to a fixpoint and explicitly not one-shot, while the YAML description still says one-shot full-pipe drainer.
   - Failure path: Readers of the command summary get the old mental model even though the command body changed.
   - Unblock: Update the command description to say fixpoint/full-pipe loop rather than one-shot.
   - Fingerprint: `175d32acdd60784031efa23a67677e59ab701c131908c6a0b4199426fe9cfa15`

4. **Recirculate-command smoke allows closeout or trivial instead of requiring both**
   - Location: `tests/smoke/phase4-larger-loop.sh:136`
   - Category: `test-gap`; confidence: 0.99; reviewers: test-analyzer
   - Evidence: The grep pattern `closeout|trivial` passes if either term remains, despite the assertion text requiring both structured closeout and trivial-outcome coverage.
   - Failure path: A future edit can delete the trivial outcome from command docs while the test stays green.
   - Unblock: Split the assertion into two greps: one for closeout, one for trivial/grant-build semantics.
   - Fingerprint: `592a979a1c36cbe5c9126d76cb498ed8aaa2f618ba9790f57aeaf96298870347`

## Nit

None.

## Test Gaps

- Malformed closeout tests need to assert no stdout dispatch, not just exit code 2.
- Add adversarial closeout cases for delimiters/control characters, non-integer tickets, unsafe `grant.paths`, and preservation of `grant.change`.
- Add the retired-recirc mixed-blocker fixture and decide whether the helper should require sole/satisfied blocker semantics or document broader advisory semantics.
- Add command/playbook parity coverage for the new `grant-build` exception in `/idc:build`.

## Surfaces Cleared

- Base-branch authority loaded from `AGENTS.md` and `CLAUDE.md`; no changed instruction files in scope.
- No dependency manifests or lockfiles changed.
- No personal `/Users/...` paths introduced in changed shipped files.
- `scripts/idc_recirc_caps.py` fail-closed malformed/negative count behavior was statically reviewed as present.
- Doctor Row 9 whole-board pagination/index plumbing is present; remaining retired-recirc issue is mixed-blocker semantics, not dormant wiring.
- This review was read-only and did not run the smoke suite or sandbox e2e.

## Security Watchlist (low-confidence, not in verdict)

None.

## Coordinator Notes

- Review mode was read-only. No source, test, config, or doc remediation edits were made.
- Packet helper scripts were absent, so packet assembly, risk tiering, dependency audit, and commit narrative checks used the skill's inline fallback path.
- PR posting was not requested and was not performed.
