# PR #171 Shared Path Gate Review

Scope: `ef226cbcce5e489442a0a6d1baa72f2da3c11020..88cbb9a1477f2de36107dd9759ff180242240b9c` (9 commits, 20 files, +2,324 / -121 lines)

**Verdict:** FAIL/BLOCKED

**Risk tier:** full

**Packet:** `.code-review/runs/20260722-165401-pr-171-shared-path-gate`

**Reviewer completion:** 8/8 required review lanes succeeded

| # | Dimension | Result |
|---:|---|---|
| 1 | Repo Protocol | 4 Blocker, 5 Major — rollout mode, Build topology, runtime lifecycle, Git scope |
| 2 | Schema & Contract Drift | 4 Blocker, 2 Major — authorization timing, identity, action, branch/worktree contracts |
| 3 | Error Handling Integrity | 5 Major, 1 Minor — stranded records, expiry, hook installation/chaining, diagnostics |
| 4 | Resource Management | 1 Minor — Pi starts one Python process for every path decision |
| 5 | Security | 4 Blocker, 6 Major — shell-variable bypass, push-history gap, identity loss, tool coverage |
| 6 | Stack Gotcha Audit | 5 Major — worktree Git paths, APFS case behavior, non-Git repos, hooksPath, stdin |
| 7 | Unit-Test Rigor | 10 concrete gaps; current fixtures manufacture the state real Build and Pi do not have |
| 8 | Integration-Test Gap | No real Build worktree or Pi-launcher receipt; no sandbox e2e receipt in the PR |
| 9 | Dependency & Bloat | 0 findings — no dependency, lockfile, CI dependency, or image change |
| 10 | Complexity Budget | 2 Minor — broad shell heuristics create false positives; Pi process-per-path overhead |
| 11 | Git-History Narrative | 0 findings — clear RED/GREEN history with three append-only fix rounds |
| 12 | Stale-Docs Sweep | 1 Blocker, 5 Major — default-off contract, Pi prompts, human Git, transport limits |
| 13 | Simplification Applied | Not requested — default read-only review |

## Reviewer results

| Reviewer | Required | Status | Verdict | Findings |
|---|---|---|---|---:|
| protocol-reviewer | yes | accepted | fail | 11 |
| type-design-analyzer | yes | accepted | fail | 13 |
| silent-failure-hunter | yes | accepted | fail | 10 |
| test-analyzer | yes | accepted | fail | 11 |
| comment-analyzer | yes | accepted | fail | 8 |
| security-reviewer | yes | accepted | fail | 11 |
| dependency audit | yes | accepted (inline fallback) | pass | 0 |
| git-history narrative | yes | accepted (inline fallback) | pass | 0 |

## Blocker

1. **The documented default `off` profile is ignored, so this silently enables hard enforcement everywhere.** `templates/WORKFLOW-config.yaml:24-31` and `README.md:100-106` say `off` is non-enforcing and that default enablement has not landed. The PR registers Claude hard-deny hooks at `hooks/hooks.json:4-31` and installs Git hooks from `scripts/idc_init_scaffold.sh:114-119`; none of the three gate implementations reads `pathway_enforcement.mode`. A routine update therefore changes every default-off governed repo. Either make all transports honor the profile or obtain an explicit product decision and ship the breaking migration. Confidence: 0.99.

2. **Claude grants repository-wide mutation authority before the required ticket claim and path boundary exist.** `scripts/hooks/idc_command_entry_gate.py:240-258,278-296` calls `write_authorization` with only repo, session, and command. `scripts/idc_path_gate.py:151-154,239-250` fills that with `allowed_paths=["."]` and all three mutation actions. This contradicts the base specification's rule that Build authorization is issued only after a successful `In Progress` claim and means Think, Plan, Build, and Recirculate start with a broad grant. Mint only at the transition that proves authority, with the real ticket, graph node, action set, and declared paths. Confidence: 0.99.

3. **Branch-bound, worktree-local authorization cannot survive the real Build topology.** `scripts/idc_path_gate.py:77-83,239-255,304-308` stores the grant through a worktree-sensitive Git path, stamps the current branch, and rejects a later branch. Build requires pre-created worker worktrees (`agents/idc-build.md:83-84`), but the only Claude producer runs once in the original checkout. The user's live probes reproduced both the branch-mismatch and missing-worktree-auth failures. Define per-worker authorization and ledger visibility, mint it only after the worktree/branch exists, and require a sandbox `/idc:build` receipt through write, commit, push, and finish. Confidence: 1.00.

4. **Non-Claude runtimes have no producer for the authorization they now consume.** Pi routes every otherwise-allowed write through the shared evaluator at `runtime/pi/extensions/idc-role-harness.ts:327-351,701-732`; Codex's adapter starts a command record but does not mint a Path Gate grant. The Pi test hides this by manually creating both state files at `tests/smoke/phase8-pi-guard-acl.ts:37-58`. Real Pi denies its first write, while Codex reaches installed Git hooks with no authorization. Add first-class Pi and Codex lifecycle producers tied to their real session/worktree identities and test the actual launchers without pre-seeding. Confidence: 0.99.

5. **Pi's required merge path is unconditionally denied.** `runtime/pi/extensions/idc-role-harness.ts:543-560` denies every raw `gh pr merge`, while `runtime/pi/.pi/agents/idc/build-finisher.md:35,50` and `runtime/pi/.pi/agents/idc/plan.md:35` still require that exact operation. Even a manually authorized Pi run dead-ends at completion. Replace the prompts with an implemented sanctioned finisher/merge helper and prove Plan and Build Finisher can complete through it. Confidence: 1.00.

6. **A protected mutation can be smuggled in an earlier commit on a new branch.** For a new remote ref, `scripts/idc_git_path_gate.py:144-164` runs `diff-tree` only on the local tip. An innocent tip therefore hides protected paths in earlier outgoing commits. Enumerate all newly reachable commits (for example, `rev-list <local> --not --remotes`) and union their paths; add the exact multi-commit exploit test. Confidence: 1.00.

7. **Top-level shell variables bypass both path detection and hook-suppression detection.** `scripts/hooks/idc_interlock_gate.py:1270-1285` silently drops `$`-bearing path candidates, and `:1523-1529` recognizes only literal `--no-verify`/`-n`. Callers then return no gate request at `:1845-1850`. The user's `T=TRACKER.md; cp ... $T` plus `G=--no-verify; git commit $G ...` chain therefore reaches the remote. Dynamic tokens in mutation targets or policy-sensitive Git positions must hard-deny unless safely resolved, with exploit-style tests for the paired escape. Confidence: 1.00.

8. **Ticket, graph-node, and live-tracker bindings are not enforced by any real transport.** `scripts/idc_path_gate.py:314-319` checks ticket and graph only when a request supplies them, but Claude (`scripts/hooks/idc_interlock_gate.py:1896`), Git (`scripts/idc_git_path_gate.py:167-169`), and Pi (`runtime/pi/extensions/idc-role-harness.ts:728-732`) send only actions and paths. No shared decision compares live tracker state either. Make identity mandatory for scoped grants, derive it from trusted lifecycle state in every adapter, and reject missing or stale identity. Confidence: 0.99.

## Major

1. **External scratch paths are denied instead of treated as outside repository jurisdiction.** `scripts/idc_path_gate.py:104-115,282-285` converts every outside path into an invalid-request denial. This breaks Claude `/tmp` writes and Pi's explicitly allowed scratch roots (`runtime/pi/extensions/idc-role-harness.ts:79-168`). Classify outside paths as out of this gate's jurisdiction and leave them to the runtime's existing role and secret policy. Confidence: 1.00.

2. **Pi collapses Edit into the Write action.** The Pi tool handler sends both events through the same path evaluator, and `runtime/pi/extensions/idc-role-harness.ts:728-732` always emits `action: "write"`. An edit-only grant is rejected and a write-only grant can admit Edit. Preserve the originating action and test write-only/edit-only grants. Confidence: 0.98.

3. **Ordinary human Git is silently blocked outside a live IDC command.** `scripts/idc_git_path_gate.py:185-205` gates every staged/pushed path and `scripts/idc_path_gate.py:290-292` denies any missing authorization; the Claude-only observe setting is not read by Git hooks. This needs an explicit operator choice before release: either unauthenticated Git denies only protected machine-owned paths, or blanket locking becomes a documented breaking policy with a safe, auditable human workflow. Confidence: 0.99.

4. **A still-active long command loses all mutation authority after four hours.** `scripts/idc_path_gate.py:42,204-215,310-312` imposes the fixed expiry, while the only producers run at command entry or Init and no heartbeat refresh exists. Long Autorun/Build drains can fail mid-run despite a valid active record. Add bounded renewal that cannot widen the original grant and an elapsed-time lifecycle test. Confidence: 0.95.

5. **An authorization-write failure strands the command record for a command that never expanded.** `scripts/hooks/idc_command_entry_gate.py:278-296` persists the record first, then blocks on authorization failure without aborting that new record; `_ensure_path_gate_auth` also discards the underlying exception. Make record plus authorization transactional and prove a forced auth-write failure leaves no new obligation. Confidence: 0.99.

6. **Hook installation can rewrite a shared or machine-global `core.hooksPath`.** `scripts/idc_git_path_gate.py:29-34,86-107` trusts `git rev-parse --git-path hooks/...` and moves/writes that location without proving repository ownership. A globally configured hooks directory can therefore be changed for unrelated repositories. Detect shared/external hook paths and refuse or use a verified repository-specific dispatcher. Confidence: 0.96.

7. **The managed pre-push hook consumes stdin before the user's original hook runs.** The wrapper runs IDC first at `scripts/idc_git_path_gate.py:41-63`; `cmd_pre_push` consumes all pushed-ref records at `:197-202`, and only then is the saved hook execed on EOF. Buffer once and replay identical bytes to both hooks, preserving arguments and failure status. Confidence: 1.00.

8. **Pre-commit silently ignores protected-file deletions.** `scripts/idc_git_path_gate.py:139-141` uses `--diff-filter=ACMRTUXB`, omitting `D`; a deletion-only commit therefore returns early at `:185-190` without policy evaluation. Include deletions and add protected plus ordinary authorized deletion tests. Confidence: 0.99.

9. **A failed hook install can strand the user's original hook outside the active chain.** `scripts/idc_git_path_gate.py:100-107` moves the existing hook before writing the managed replacement, and the replacement write is not atomic. Interruption leaves only the backup; a retry sees no live hook and can install a wrapper with no chain reference. Use atomic install with rollback and recover an existing IDC backup on retry. Confidence: 0.96.

10. **Governed non-Git repositories are denied every Write/Edit mutation.** `scripts/hooks/idc_interlock_gate.py:1874-1879,1890-1895` hard-denies when Git worktree detection fails, while the scaffold explicitly guards Git-hook installation for non-Git targets. Init's authorization step also requires a branch. Either restore non-Git behavior with a separate state location or remove support through an approved contract and align the scaffold/docs/tests. Confidence: 0.96.

11. **Mutation tools outside Bash, Write, and Edit bypass the gate.** `hooks/hooks.json:4-31` matches only those three names. NotebookEdit and configured MCP filesystem mutation tools do not reach authorization or protected-path checks. Add transports for every supported mutation tool or prevent unsupported writers in governed sessions and publish the exact boundary. Confidence: 0.90.

12. **Protected paths are compared case-sensitively on the primary case-insensitive host.** `scripts/idc_path_gate.py:139-140` uses `fnmatchcase` on caller spelling. On default macOS/APFS, a case variant can address the same protected file while missing `TRACKER.md` and similar rules. Compare canonical filesystem identity or a platform-safe case-folded/Unicode-normalized path and add case-variant tests. Confidence: 0.84.

## Minor

1. **Bare `authorize` succeeds with no allowed actions.** `scripts/idc_path_gate.py:397-398` defaults repeatable CLI flags to empty lists, while the API selects defaults only for `None` at `:240-243`. Use `None` for omitted flags and test the minimal CLI. Confidence: 1.00.

2. **Unreadable or malformed authorization is misreported as absent.** `scripts/idc_path_gate.py:259-265` collapses I/O and JSON failures to `None`, producing the wrong route-work-through-IDC advice. Distinguish absent, unreadable, and corrupt state with scrubbed diagnostics. Confidence: 0.98.

3. **New hard-deny heuristics interrupt harmless commands.** `scripts/hooks/idc_interlock_gate.py:1744-1748` rejects every `find -exec`, including read-only grep, and `:1782-1789` rejects mutation-shaped interpreter code when its literal target is outside the repo. Narrow the opaque rule to repository-capable mutations or apply outside-jurisdiction handling before denial; cover the reported read-only and `/tmp` cases. Confidence: 0.96.

4. **Pi starts a full Python process per path evaluation.** `runtime/pi/extensions/idc-role-harness.ts:701-709` calls synchronous `spawnSync` for each write path. This is correct but adds noticeable per-write latency; batch paths or keep a small deterministic evaluator process after the correctness blockers are resolved. Confidence: 0.90.

## Nit

1. **Small cleanup debt remains.** `scripts/idc_git_path_gate.py:55-62` checks `rc` after a command under `set -e`, so the branch is unreachable; `tests/smoke/governance/path-gate-boundaries.sh` lacks its final newline. Neither affects the merge verdict.

## Test gaps

- Start `/idc:build` through the real command-entry gate, then create the normal branch and linked worktree before the first Write/Edit/commit/push.
- Launch Pi and Codex through their actual adapters without manually creating authorization state.
- Drive Pi Plan and Build Finisher from their shipped prompt through the sanctioned merge path.
- Push a new multi-commit branch with a protected lower commit and an innocent tip.
- Add direct top-level variable targets and variable `--no-verify` flags to the existing `deny_or_exploit` pattern.
- Test out-of-repo scratch paths, non-Git governed repos, APFS case variants, and every supported mutation tool.
- Test ordinary human Git with no authorization under the operator-approved policy.
- Test custom/global `core.hooksPath`, interruption during hook install, a chained pre-push hook that reads stdin, and staged deletions.
- Exercise minimal `authorize`, malformed/unreadable auth, and renewal across a short test TTL.
- Require a real sandbox Build receipt after the fixes; the current same-branch fixtures cannot prove lifecycle compatibility.

## Surfaces cleared

- Symlink aliases resolve through `realpath` before protected-path and allowed-boundary checks.
- Authorization JSON writes use a same-directory temporary file, flush, `fsync`, and atomic replace.
- Missing required fields, expiry, digest mismatch, branch mismatch, and missing active records fail closed.
- Git child-process diagnostics are scrubbed while retaining bounded useful context.
- Managed-hook paths are shell-quoted, and unchanged hooks are verified byte-for-byte.
- No dependency, lockfile, CI workflow, container, network-fetch, or cryptographic-secret handling change is present.
- Commit history is auditable and follows Conventional Commit style.

## Verification receipts

- PR #171 was open, draft, mergeable, and CI-green at reviewed head `88cbb9a1477f2de36107dd9759ff180242240b9c` when review began.
- `git diff --check ef226cbcce5e489442a0a6d1baa72f2da3c11020..88cbb9a1477f2de36107dd9759ff180242240b9c` — clean.
- Dependency audit fallback — pass; the repository helper was absent, so the pinned diff was inspected directly.
- Git-history narrative fallback — pass; the repository helper was absent, so all nine commit subjects/order were inspected directly.
- This was a static review. In accordance with the review harness, candidate code and tests were not executed. The user's supplied runtime probes independently reproduced the six stated failures, and the pinned code paths match those reports. GitHub's green CI does not cover the lifecycle and integration gaps above.
- No review was posted to GitHub, no source code was changed, and no merge was attempted.
