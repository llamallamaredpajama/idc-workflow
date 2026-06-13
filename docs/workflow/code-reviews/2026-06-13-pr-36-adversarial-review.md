# Codex Adversarial Review

Target: branch diff against main
Verdict: needs-attention

No-ship: the Pi adapter is not launchable as vendored, the glass-wall ACL is bypassable at the hub, and the concurrency/drift guarantees are mostly prose rather than enforced mechanics.

Findings:
- [critical] Vendored Pi launcher references assets that were not vendored (runtime/pi/scripts/idc-pi:634-642)
  The role launch command loads `extensions/minimal.ts`, `extensions/theme-cycler.ts`, and a role prompt from `role_prompt`, but the vendored `runtime/pi` tree only contains coms-net, guard, role-harness, review files, themeMap, and scripts. A fresh install will fail before any resident starts. This also weakens the attribution/fidelity claim: the runtime is neither complete nor self-checking for the files the launcher actually uses.
  Recommendation: Either vendor every launch-time dependency, including the role prompt tree and secondary extensions, or remove those dependencies from the launcher. Extend `install-pi.sh --check` to verify exactly the files used by `idc-pi run`.
- [high] Glass-wall ACL is client-side only and can be bypassed by direct hub calls (runtime/pi/scripts/coms-net-server.ts:855-981)
  `handleSendMessage` accepts any authenticated request, verifies only that the sender session is registered, resolves the target, then queues and delivers the prompt. There is no server-side call to the IDC role ACL before enqueue. Since the bearer token is shared for the hub, any process or compromised resident with the token can POST `/v1/messages` with an upstream target or `target_session` and bypass the deny-upstream rule enforced in the extension UI path.
  Recommendation: Move the directional ACL enforcement into the hub as the authoritative gate, using registered sender/target role metadata or scoped per-role tokens. Treat the client-side check as defense in depth only.
- [high] Board-backed merge lease is specified but has no enforceable primitive (skills/idc-adapter-pi/SKILL.md:60-65)
  The Pi adapter says the GitHub Projects board is the single-holder merge lease, but no lease field, lease item, acquire/release operation, fencing token, expiry, or compare-and-set behavior is defined here. The tracker adapter still exposes only create/set/link/move/query/comment operations, so two finisher residents have no atomic way to prove exclusive ownership before updating the integration ref. The likely failure is either concurrent merges or finishers proceeding on incompatible local assumptions.
  Recommendation: Add an explicit tracker-level lease contract and backend implementations: owner, token, acquired_at/expires_at, atomic acquire-if-empty-or-expired, release-by-token, and tests with two concurrent finishers. Until then, keep Pi merging behind one orchestrator.
- [high] Governance drift checker is not wired into resident startup or lifecycle (runtime/pi/scripts/idc-pi:634-662)
  The launcher builds the `pi` command directly and starts role residents without compiling, loading, or checking `docs/workflow/idc-governance-contract.yaml`. The new check script can detect drift, but an unenforced helper does not protect long-lived residents from stale governance. This is an inference from the launch path and repository search: the governance scripts are referenced by tests/docs, not by `idc-pi` or a loaded extension.
  Recommendation: Make governance validation part of the Pi runtime contract: compile/check before launch, load the sidecar explicitly, and add a session-start plus periodic fail-closed check that blocks role action on drift until reload completes.
- [medium] Stage migration breaks legacy empty-stage work despite promising compatibility (scripts/idc_tracker_fs.py:169-183)
  The filesystem tracker query uses exact equality for `--stage`, so `--stage Buildable` excludes issues with missing or empty `stage`. That contradicts the template promise that an empty Stage on a legacy 4-field board reads as buildable. If Build or the GitHub adapter queries `Stage=Buildable`, existing boards can silently stop surfacing all previously valid Todo work.
  Recommendation: Normalize missing/empty `Stage` to `Buildable` in every backend filter and add a regression test with a legacy no-stage Todo issue returned by a Buildable query.
- [medium] Pi review verdicts do not match the IDC validator contract (runtime/pi/extensions/review-orchestrator-core.ts:442-455)
  The vendored review core emits `FAIL/BLOCKED` for any blocker or major finding and for incomplete runs. The IDC review agent and validator use the hyphenated ladder `FAIL-BLOCKED` for blockers and `FAIL` for majors. A Pi review report using this core will fail the structured verdict validator or collapse major/blocker semantics, making it unsafe as an automerge gate.
  Recommendation: Change the Pi review core to emit the same verdict enum as `idc_review_verdict_check.py`: blocker -> `FAIL-BLOCKED`, major -> `FAIL`, minor/nit -> `PASS-WITH-NITS`, none -> `PASS`, then validate emitted coordinator JSON with the shared checker.

Next steps:
- Block shipping until the Pi launcher can boot from the vendored tree and the hub enforces the ACL server-side.
- Require real concurrency tests for the merge lease and legacy Stage migration before treating Pi as a third runtime adapter.
