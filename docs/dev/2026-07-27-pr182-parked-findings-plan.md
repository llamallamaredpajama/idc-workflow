# Plan — PR-182 parked findings, rolled into the follow-up build

**Written:** 2026-07-27, grounded against `integration/idc-pathway-integrity` @ `9e50a1e` and the
review-fix branch `fix/pr-182-pathway-integrity` @ `fd87097` (rounds 1–5, still moving).
**Source of the findings:** `docs/reviews/2026-07-26-pr-182-pathway-integrity-review.md`
(8-reviewer FAIL/BLOCKED verdict on PR 182) and the fix-branch round work since.
**Consumes:** the four items the operator pulled out on 2026-07-27 (one contested finding, three
architectural follow-ups). **Feeds:** Part 0 and Part 4 of the follow-up-build kickoff
(`docs/dev/2026-07-26-verification-contract-kickoff.md`, updated same day as this plan).

Because the fix branch is still adding rounds, every item below carries a **re-ground check**
the executing session performs first — facts may have moved by kickoff time.

---

## Item A — CONTESTED: "deny requests without identity" (review Blocker #3, denial clause)

### Grounded facts (integration @ 9e50a1e)
- The gate compares ticket/graph-node identity only when the request supplies it:
  `scripts/idc_path_gate.py:533-538` (`is not None and !=` → deny). Absent identity skips the
  comparison by design.
- Spec §3.2 (`docs/specs/idc-convergent-pathway-integrity-spec.md:158-160`) requires denial when
  authorization is "bound to the **wrong** ticket/graph node" — mismatch, not absence. The spec
  never requires requests to carry identity.
- The governance test pins absent-identity→ALLOW as intended:
  `tests/smoke/governance/path-gate-boundaries.sh:116` (allow with no identity), `:144`/`:147`
  (deny on wrong ticket / wrong node).
- All three adapters send only `action` + `paths` (or `raw_reason`): Claude interlock
  `scripts/hooks/idc_interlock_gate.py:2346-2382`; Pi harness
  `runtime/pi/extensions/idc-role-harness.ts:606-741`; git backstop
  `scripts/idc_git_path_gate.py:281-282`. **Codex has no per-tool adapter at all** — only the git
  backstop covers it (see Discovered item D1).

### Adjudication recommendation (the operator's merge-time decision)
**Uphold the parked disposition: merge PR 182 without the literal "deny absent identity" change.**
- The literal fix denies every legitimate edit from every runtime — executably proven by the
  implementer and consistent with the adapter map above.
- The rule the spec actually requires (mismatch denial) is implemented and red-when-broken tested.
- The reviewer's underlying concern is legitimate but is a **spec evolution**, not a release
  defect. It is honestly resolvable only by making adapters carry identity first — which is
  exactly Item D's mechanism. Fold the durable fix into Unit V-AUTH below; do not hold the
  release for it.

### Durable resolution (in Unit V-AUTH)
Adapters echo `ticket`/`graph_node` read from the live authorization
(`scripts/idc_path_gate.py:452-465` `_read_authorization`) into every request; once all request
paths carry identity, flip `:533-538` to required-and-must-match, amend spec §3.2 in the same PR,
and flip the boundary test's `:116` case from allow to deny. Red-when-broken: the flipped test
must FAIL against the pre-flip gate.

---

## Item B — Remove the public authorization door (review Blocker #2 residue)

### Grounded facts
- The door: `authorize` CLI subcommand, `scripts/idc_path_gate.py:586-599` (handler) /
  `:617-627` (parser) → `write_authorization()` `:401-449`. Callable from any Bash in a session;
  honors caller-chosen `--command`/`--allow-action`/`--allow-path`; only precondition is an
  active command record (`:414-430`). Read-only commands (`doctor`, `pause` —
  `READ_ONLY_COMMANDS`, `:43`) get no actions by default (`_default_profile`, `:331-334`), and
  the door lets them override that — the escalation the review flagged.
- Integration's round of hardening (`7df4d52`, `aec102d`, …) fixed the **evaluation/admission**
  side (protected-surface ordering, fail-closed reads, serialized admission with nonce CAS) but
  added no role guard to the door. The **fix branch** adds a role-action ceiling
  (`_role_action_ceiling` / `_normalize_actions` in `write_authorization`/`_evaluate_request`) —
  the interim closure of the escalation. RE-GROUND: confirm the ceiling and its test landed in
  whatever finally merges.
- Sole production caller: `commands/init.md:144-146` — only because init defers registration
  (`DEFERS_REGISTRATION = {"init"}`, `scripts/hooks/idc_command_entry_gate.py:67`): at init's
  expansion the repo isn't governed yet, so the entry gate mints nothing, and init self-mints
  after self-registering (`init.md:139-141`). Every other command is minted by the hook through
  the Python API (`idc_command_entry_gate.py:329`) with **no caller-chosen actions**.
- Init needs none of the door's flexibility: its requirement is exactly the fixed default
  profile (`write/edit/git` on `.`) bound to its just-opened record's nonce.
- Test-only callers: `path-gate-git-backstops.sh`, `path-gate-boundaries.sh`,
  `path-gate-interlock-denial.sh`, `path-gate-overhead.sh`, `phase8-pi-guard-acl.ts` — all can
  migrate to the Python API (one unit test already does).
- Coverage gap on integration: **no test asserts a read-only command cannot self-grant write via
  the door** (verify whether a fix-branch round added one).

### Plan (Unit V-DOOR)
1. Give init an internal mint: fold the fixed-profile authorization into
   `idc_command_contract.py start --command init` (init.md already calls `start` immediately
   before `authorize` — same transaction, one less public verb), OR un-defer init's registration.
   Decide by reading the merged state of the entry gate at execution time; prefer the smallest
   diff that keeps register→mint atomic under `admission_lock`.
2. Delete the `authorize` subcommand; migrate the test callers to `PG.write_authorization` (or a
   test-only fixture helper under `tests/`).
3. Keep the fix-branch action ceiling on the Python API as defense-in-depth.
4. Tests (each shown red-when-broken): (a) `authorize` verb no longer parses (door gone);
   (b) init e2e still scaffolds a governed repo (phase1 suite + one install-sandbox init run);
   (c) NEW negative test — with only a read-only command record active, no CLI path exists that
   yields a write-action authorization.

---

## Item C — SHA-pin the GitHub Actions references (review Blocker #1, pinning clause)

### Grounded facts
- Exactly three unpinned `uses:` lines exist; only one reaches user repos:
  - **`.github/workflows/idc-pathway-integrity.yml:31`** (`actions/checkout@v4`) — inside the
    workflow whose job name IS the required check `idc/pathway-integrity` that the shipped
    ruleset pins (`.github/rulesets/idc-pathway-integrity.json:41-42`). Load-bearing: a bad ref
    fails checkout → fails the required check → blocks every governed merge. (Fix branch adds a
    second job — two checkout lines there; RE-GROUND the exact count at execution.)
  - `.github/workflows/ci.yml:13` (`actions/checkout@v4`) and `:22` (`oven-sh/setup-bun@v2`) —
    plugin's own CI only.
- No local lint/test inspects the pin value; verification is live-CI-only. This is why the fix
  round deferred it.
- The online-lookup blocker is already resolved (2026-07-27): `actions/checkout@v4` dereferences
  to commit `11d5960a326750d5838078e36cf38b85af677262` (tag last MOVED 2026-07-16 — a live
  demonstration of the mutable-tag risk); newest v4 point release `v4.3.1` =
  `34e114876b0b11c390a56381ad16ebd13914f8d5`.

### Plan (Unit V-PIN — small; can ride in the V-DOOR PR)
1. Pin all three lines to full commit SHAs with a trailing version comment. Default choice: the
   SHA the tag resolves to on execution day (re-run the lookup; it makes the change a provable
   no-op that day). `# v4` / `# v2` comments preserve readability.
2. Verification: the PR's own CI run exercises `ci.yml`; the required-check workflow is proven by
   the PR run of `idc-pathway-integrity.yml` itself (it triggers on pull_request) — a wrong pin
   is loudly visible before merge, which defuses the original deferral reason.
3. Add a lint rule (in `scripts/lint-references.sh` or a small governance test): any `uses:` line
   in `.github/workflows/` not matching `@[0-9a-f]{40}` fails. Hermetic, red-when-broken provable
   by reverting one pin locally.

---

## Item D — Transition-scoped path authorization (review Blocker #3, minting clause)

### Grounded facts — the reframe: **the spec already mandates this; the implementation deviates**
- Spec: "No source-write authorization is issued before a Build claim is proven In Progress"
  (§3.3:195); "A successful claim transaction issues the limited Path Gate authorization"
  (§4.2:296-297); "The authorization expires after finish or block" (§4.2:310).
- Reality: one mint per command at entry — `_ensure_path_gate_auth()`
  (`scripts/hooks/idc_command_entry_gate.py:308-337`, the ONLY runtime `write_authorization`
  caller) with `_default_profile` whole-repo scope `["."]` + `write/edit/git` + 4h TTL
  (`scripts/idc_path_gate.py:44,331-334`). The `claim` op (`scripts/idc_transition.py:1781,1857`)
  mints nothing.
- The narrow path set already exists: the frozen validation contract stores `touch`/`off_limits`
  (`scripts/idc_validation_contract.py:430-431,454-455`) — but it is enforced only as a post-hoc
  diff check at receipt time (`scripts/idc_build_receipt.py:61-72`), never at mutation time.
- The change is write-side-only: all readers (interlock, git backstops) resolve the same
  `authorization.json` through `evaluate_request` and need no modification. Narrow minting
  already works and is tested (`--allow-path` in `path-gate-boundaries.sh:95-96,159-160`); the
  nonce/TTL/digest/admission-lock machinery is in place (`idc_path_gate.py:144-179,226-257,
  323-351,395,411`).
- Pairing worth taking: `contract_digest` today is a self-hash (`:337-351`), not a binding to
  the frozen contract the spec intends (spec `:154`).

### Plan (Unit V-AUTH — the substantial one; subsumes Item A's durable half)
Staged, each stage green + reviewed before the next:
1. **Contract-scoped entry mint for build:** `_ensure_path_gate_auth` passes
   `allowed_paths = touch − off_limits` from the frozen contract instead of defaulting to `["."]`
   (fall back to current behavior only when no contract exists, e.g. non-build commands).
   Test: a Write inside the repo but outside `touch` is DENIED at mutation time (today it passes
   the gate and only fails the receipt diff) — red-when-broken by reverting the mint change.
2. **Claim-time mint (the spec's seam):** the `claim` op re-mints `authorization.json` with the
   claim's scope and a short TTL; finish re-mints narrower still (finish surfaces only); entry
   mint for build shrinks to read-only-until-claim. Test: write before claim → DENY;
   write after claim inside scope → ALLOW; after finish → DENY.
3. **Identity required (Item A durable):** adapters echo `ticket`/`graph_node`; flip
   `idc_path_gate.py:533-538` to required-and-must-match; amend spec §3.2 and flip
   `path-gate-boundaries.sh:116`; bind `contract_digest` to the frozen contract.
Sandbox receipt: one full install-sandbox Build lifecycle (codex-exec driver per CLAUDE.md)
proving the staged mints fire and the drain still completes — this changes build behavior, so a
green smoke suite alone is not sufficient proof.

---

## Discovered while grounding (new items for the roll-in triage)
- **D1 — Codex per-tool gate coverage is absent.** Spec §3.2:167-168 mandates Codex write/edit/
  apply_patch tool coverage; `scripts/install-codex.sh` wires no hook — Codex is protected only
  by the git backstop. Triage: verify against the merged state; if still true, it is a spec
  conformance gap of the same class as the parked items (likely its own small unit; it also
  gates V-AUTH stage 3, since "all adapters echo identity" must include whatever Codex adapter
  exists).
- **D2 — No negative test for read-only self-grant** (see Item B; may be closed by a fix-branch
  round — verify).
- **D3 — Run-review nits still open:** N1 — `idc_pathway_check.py` + `idc_ruleset_check.py` not
  in CODEOWNERS/`protected_surfaces` (fix branch added `.github/CODEOWNERS` — verify coverage of
  these two scripts specifically); N2 — CHANGELOG 5.0.0 date/remediation note (cosmetic, fold
  into any Part-4 PR).

## Execution order and preconditions
1. **Nothing here starts until PR 182 (with its fix-branch rounds) is merged to main.** All four
   items were deliberately parked out of the release; do not reopen them against the moving
   integration/fix branches. Single exception: the Item-A adjudication above is FOR the merge
   decision itself.
2. **Part 0 sweep first** (defined in the kickoff file): re-ground every fact in this plan
   against merged main; enumerate any round-6+ parked items from the PR body/comments, the
   fix-branch round commits, `docs/reviews/2026-07-26-pr-182-*.md` and successors, and the run's
   final-review nits; triage each as done / roll-in / defer-with-owner.
3. Then the original verification-contract Parts 1–3, then Part 4 units in order:
   **V-PIN + V-DOOR** (small, one PR) → **V-AUTH** (own PR, staged) — with D1 triaged either into
   V-AUTH or its own unit.
4. Workflow pattern, gates, review discipline, and merge authorization: per the kickoff file.
