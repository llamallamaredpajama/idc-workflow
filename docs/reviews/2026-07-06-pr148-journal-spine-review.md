# Adversarial review: PR #148 journal-spine
Scope: `llamallamaredpajama/idc-workflow` PR #148 (`te/phase4-2026-07-06-u1`), base `68bc19578214772fc6a02c8c924cfa916ea2da3a` .. head `072aa0832b4761e590b7eec663d219f307360655`
Verdict: FAIL/BLOCKED

## Findings

### [BLOCKER] Journal append failures are swallowed after the tracker mutation succeeds
- Evidence: `scripts/idc_transition.py:544`, `scripts/idc_transition.py:570`, `scripts/idc_transition.py:582`, `scripts/idc_transition.py:586` append after the backend mutation; `scripts/idc_transition.py:365-366` catches every exception and only writes a warning to stderr.
- Attack: make the journal path unwritable/invalid, then run an engine op. The operation exits 0 and mutates tracker state with no `docs/workflow/transition-journal.ndjson` line, violating #141's “every engine op appends one NDJSON line” / reliable append-only spine.
- Reproduction:
  ```bash
  cd /tmp/pi-harnesses/review/pr148
  bash -c '. tests/smoke/governance/lib.sh; gov_engine_env; : > "$REPO/docs"; out=$(eng create-ticket --title no-journal --stage Buildable --status Todo 2>"$REPO/err"); rc=$?; echo "rc=$rc out=$out"; echo "stderr=$(cat "$REPO/err")"; echo "tracker_status=$(python3 "$GOV_TRK" --tracker "$T" show --num "$out" --field Status 2>/dev/null || true)"; if [ -e "$REPO/docs/workflow/transition-journal.ndjson" ]; then echo journal_exists; else echo no_journal; fi'
  # observed: rc=0, tracker_status=Todo, no_journal
  ```
- Unblock condition: journal persistence must be part of the success contract. Do not report an op as successful if its journal record cannot be persisted; add a red test that forces journal creation/open/write failure and proves the op fails closed (or otherwise cannot leave an unjournaled successful mutation).
- Gate impact: Blocks merge; the central Done-When condition is not enforceable.

### [BLOCKER] PR head regresses an existing governance test by making same-status retries illegal
- Evidence: `scripts/idc_transition.py:555-556` newly raises when the current status already equals `to_status`; existing `tests/smoke/governance/engine-readback-verify.sh:63` expects a clean retry of `move --to-status "In Progress"` to succeed after the read-back-divergence seam test has already landed the write.
- Attack/reproduction:
  ```bash
  cd /tmp/pi-harnesses/review/pr148
  bash tests/smoke/governance/engine-readback-verify.sh
  # observed: idc_transition.TransitionError: illegal transition: #1 is already 'In Progress'
  ```
  Full focused sweep also fails exactly this test:
  ```bash
  cd /tmp/pi-harnesses/review/pr148
  for t in tests/smoke/governance/engine-*.sh tests/smoke/governance/journal-*.sh; do bash "$t" || exit 1; done
  ```
- Unblock condition: remove or redesign the same-status denial so existing read-back/retry semantics remain green, or intentionally update the contract plus all dependent tests/callers. The journal append-only test should not require a hidden transition-semantics change.
- Gate impact: Blocks merge; existing governance lane is red.

### [MAJOR] Red-when-broken coverage misses the `link` journal enforcement line
- Evidence: `scripts/idc_transition.py:584-586` appends for `kind == "link"`, but `tests/smoke/governance/journal-append.sh:68-69` exercises only github `move` and `close`, and the filesystem half exercises only `move`/`close` after a raw `gov_seed_item` seed. No test runs `E.run("link", ...)` or CLI `eng link` and asserts the journal line count/shape.
- Attack/reproduction: deleting the link `journal_append(...)` line still leaves both new journal tests green.
  ```bash
  cd /tmp/pi-harnesses/review/pr148-mut-link
  bash scripts/lint-references.sh \
    && bash tests/smoke/governance/journal-append.sh \
    && bash tests/smoke/governance/journal-append-only.sh
  # observed: all PASS after removing scripts/idc_transition.py's link journal_append call
  ```
- Unblock condition: add red-when-broken assertions for link on at least the filesystem backend and ideally both backends; broaden the lifecycle test to cover every op kind that #141 claims is journaled (`create`, `transition`, `terminal`, `link`).
- Gate impact: Fails the requested red-when-broken criterion; merge should remain blocked until the enforcement line is pinned.

## Test gaps
- Add `journal-failure-fail-closed.sh`: create an invalid `docs` path or unwritable journal parent, run an engine write, and assert no successful unjournaled mutation is reported.
- Add link coverage: perform `eng link --parent P --child C` and a monkeypatched github link, then assert one additional NDJSON record with the required keys.
- Add mutation checks for each `journal_append(...)` call site (`create`, `transition`, `terminal`, `link`) so deleting any one call fails at least one governance test.

## Surfaces checked
- TDD ordering: commit order is test first (`7627bc6 test(u1): red - journal spine tests`), then feature (`f60653b feat(u1): green - implement journal spine`), then test adjustment (`072aa08 test(u1): fix acceptance criteria for journal tests`). First test commit is red against its parent with `bash tests/smoke/governance/journal-append.sh`.
- Done-When: not satisfied because journal write failures can leave successful ops unjournaled, and link enforcement is unpinned.
- Layers claim: true at file/layer level; changes are confined to engine script plus governance tests.
- File-surface trespass: none found. Changed files are `scripts/idc_transition.py`, `tests/smoke/governance/journal-append.sh`, and `tests/smoke/governance/journal-append-only.sh`, all within #141's allowed surface.
- Weakened tests/guards: no deleted tests found, but the new same-status guard is an out-of-scope transition behavior change and breaks an existing governance test.

## Verification evidence
- PR issue command on head: `bash scripts/lint-references.sh && bash tests/smoke/governance/journal-append.sh` — PASS.
- Added append-only test on head: `bash tests/smoke/governance/journal-append-only.sh` — PASS.
- First test commit red check: `bash scripts/lint-references.sh && bash tests/smoke/governance/journal-append.sh` at `7627bc6` — FAIL as expected on missing required journal keys.
- Focused engine/journal sweep at head: `for t in tests/smoke/governance/engine-*.sh tests/smoke/governance/journal-*.sh; do bash "$t" || exit 1; done` — FAIL at `engine-readback-verify.sh`.
- Mutation check: delete only the `link` journal append line, then run lint + both new journal tests — PASS, proving the link enforcement line is unpinned.
