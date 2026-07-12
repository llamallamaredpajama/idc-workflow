# Adversarial review: PR #147 combined U3/U4
Scope: `llamallamaredpajama/idc-workflow` PR #147 (`te/phase4-2026-07-06-u3`), base `68bc19578214772fc6a02c8c924cfa916ea2da3a` .. head `66223088ef66f5c20e740d8b47f3c7a6d578b5df`
Verdict: FAIL/BLOCKED

## Findings

### [BLOCKER] U3 cross-check does not validate transition/op references against `workflow-machine.yaml`
- Evidence: `scripts/lint-references.sh:214-216` states Rule O covers workflow `state/transition` names and op names; `scripts/idc_lint_machine_yaml_refs.py:149-156` loads `valid_ops` but passes it to a validator that never uses it; `scripts/idc_lint_machine_yaml_refs.py:124-129` explicitly no-ops the backticked-op check.
- Attack: seed a shipped markdown file with a nonexistent transition/op name. Lint still exits 0, so a prose reference to a transition absent from the yaml is not caught.
- Reproduction:
  ```bash
  cd /tmp/pi-harnesses/review/pr147
  cp -R . /tmp/pi-harnesses/review/pr147-op-gap
  cd /tmp/pi-harnesses/review/pr147-op-gap
  printf '\nBogus transition: `teleport-ticket` should not exist.\n' >> commands/doctor.md
  bash scripts/lint-references.sh
  # observed: lint-references: CLEAN (34 files scanned)
  ```
- Unblock condition: implement a low-noise transition/op reference contract or narrow the issue/Rule O contract explicitly. As written, #143's Done-When says an absent state/transition reference must fail lint; this PR only enforces Stage/Status values.
- Gate impact: Blocks merge for #143 Done-When; a core promised class remains unenforced and untested.

### [MAJOR] File-surface trespass outside the declared U3/U4 surfaces
- Evidence: PR #147 changes `skills/idc-consideration-schema/SKILL.md:20` even though #143's file surface is `scripts/lint-references.sh; templates/workflow-machine.yaml; templates/WORKFLOW.md` and #144's surface is `scripts/idc_release_check.py; tests/smoke/governance/release-gate-governance.sh`. PR #147 also adds `scripts/idc_lint_machine_yaml_refs.py` outside the literal #143 surface.
- Attack: the one-line skill-template change may be correct (`Status: Active` was stale), but it is a shipped skill-content mutation routed through a lint/template unit with no issue-surface grant. That defeats the file-surface coordination check this review was asked to enforce.
- Reproduction/verification:
  ```bash
  git diff --name-status 68bc19578214772fc6a02c8c924cfa916ea2da3a...66223088ef66f5c20e740d8b47f3c7a6d578b5df
  # includes: M skills/idc-consideration-schema/SKILL.md and A scripts/idc_lint_machine_yaml_refs.py
  ```
- Unblock condition: either move the skill/template correction to a scoped follow-up issue/PR or explicitly update/waive the unit surfaces. If the helper script is accepted as part of the lint implementation, record that surface expansion.
- Gate impact: Fails the requested no-trespass check; should be operator-waived or split before merge.

### [NIT] PR body only auto-closes #143, not the combined #144 unit
- Evidence: PR #147 body is `Closes #143`; issue #144 is only referenced by an issue comment saying it was consolidated.
- Attack: merging the PR will not auto-close #144 unless the operator closes it manually or updates the PR body.
- Unblock condition: add `Closes #144` if this combined PR is intended to close both units automatically.
- Gate impact: Tracking nit; does not affect code correctness.

## Test gaps
- Add a U3 red-when-broken case for transition/op references, e.g. a shipped markdown fixture containing a nonexistent operation name that must fail against `ops:` in `templates/workflow-machine.yaml`.
- If op-name validation is intentionally too noisy, update #143/Rule O wording so the gate honestly claims only Stage/Status validation.

## Surfaces checked
- TDD ordering: PASS. Commit order is `test(u3): red`, `test(u4): red`, then green implementation commits, then fix-round-1. The U3 red test fails against its red commit; the U4 red test fails against its red commit.
- U3 Done-When: FAIL. Real tree lint is green and Stage/Status seeded checks work, but transition/op references absent from yaml still pass lint.
- U4 Done-When: PASS. `idc_release_check.py --governance` fails on a seeded failing governance scenario and exits 0 on the clean governance lane.
- Layers claim: PASS at a broad layer level (`lint/scripts + templates`, `release tooling + governance tests`), with the file-surface exception above.
- Misplaced test path: PASS. `tests/governance/machine-yaml-crosscheck.sh` is deleted and replaced by `tests/smoke/governance/machine-yaml-crosscheck.sh`.
- Weakened tests/guards: FAIL for U3 transition/op enforcement (guard intentionally removed/no-op despite Rule O wording). Stage/Status fix-round-1 tests are materially stronger than the original misplaced test.
- Red-when-broken: PASS for Stage/Status Rule O wiring and U4 release-gate wiring; FAIL/MISSING for U3 transition/op references.

## Verification evidence
- Head happy path:
  ```bash
  cd /tmp/pi-harnesses/review/pr147
  bash scripts/lint-references.sh
  bash tests/smoke/governance/machine-yaml-crosscheck.sh
  bash tests/smoke/governance/release-gate-governance.sh
  python3 scripts/idc_release_check.py --governance
  ```
  Observed: all pass; full governance lane reports `ALL GREEN (38 real scenario(s) + self-check)`.
- U3 red ordering:
  ```bash
  cd /tmp/pi-harnesses/review/pr147-red-u3
  PATH="$PWD/bin:$PATH" bash tests/governance/machine-yaml-crosscheck.sh
  ```
  Observed: exits 1 because the old linter passes the bogus stage fixture.
- U4 red ordering:
  ```bash
  cd /tmp/pi-harnesses/review/pr147-red-u4
  bash tests/smoke/governance/release-gate-governance.sh
  ```
  Observed: exits 1 because `python3 scripts/idc_release_check.py --governance` succeeds before the gate exists.
- Mutation checks:
  ```bash
  # Delete Rule O block from scripts/lint-references.sh:
  bash tests/smoke/governance/machine-yaml-crosscheck.sh
  # observed: FAIL, linter passes seeded bogus Stage/Status refs.

  # Delete `if args.governance: return run_governance_lane()`:
  bash tests/smoke/governance/release-gate-governance.sh
  # observed: FAIL, seeded red lane no longer makes release check fail.
  ```
- Misplaced path check:
  ```bash
  git ls-tree -r --name-only 66223088ef66f5c20e740d8b47f3c7a6d578b5df \
    | grep -E '(^tests/governance/machine-yaml-crosscheck\.sh$|^tests/smoke/governance/machine-yaml-crosscheck\.sh$)'
  # observed: tests/smoke/governance/machine-yaml-crosscheck.sh only
  ```
