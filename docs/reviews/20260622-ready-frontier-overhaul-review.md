# Code review — IDC ready-frontier / area-ownership / merge-train / recirc-narrowing overhaul

Scope: `1567f3e..a56059e` (17 commits, 28 files, +1834 / −82)

**Verdict (round 1):** FAIL/BLOCKED → (round 2, post-fix) **PASS-WITH-NITS**
**Risk tier:** full (1916 reviewable lines, 28 files, non-security-sensitive)
**Packet:** `.code-review/runs/20260622-061108-ready-frontier-overhaul`
**Reviewer completion:** 5/5 required reviewers succeeded + 2/2 script dimensions
**Second-lens note:** codex already ran per-wave adversarial review (4 rounds); this is an independent `code-review-custom` lens over the whole run.

This run shipped 7 units — #74 dag-matrix, #75 autorun-autonomy, #76 ready-frontier-build, #77 sous-chef-ownership, #78 adapter-fanout-docs, #79 e2e-merge-train, #80 narrow-recirc-deconflict.

## 13-dimension coverage

| # | Dimension | Mode | Result |
|---|---|---|---|
| 1 | Repo Protocol | subagent (protocol-reviewer) | PASS — 0 findings |
| 2 | Schema & Contract Drift | subagent (type-design-analyzer) | PASS — 0 findings |
| 3 | Error Handling Integrity | subagent (silent-failure-hunter) | PASS — 0 findings |
| 4 | Resource Management | inline | PASS — temp-dir trap-cleanup in every new smoke test; no leaked fds/procs |
| 5 | Security | inline (no security-sensitive files → no security-reviewer) | PASS — no secrets, no network, no untrusted exec introduced |
| 6 | Stack Gotcha Audit | inline | PASS — BSD/GNU-portable grep (`has`/`hasflat`, no `\b`/PCRE); `${CLAUDE_PLUGIN_ROOT}` not used as shell var |
| 7 | Unit-Test Rigor | subagent (test-analyzer) | **1 Major (round 1)** → fixed round 2 |
| 8 | Integration-Test Gap | inline | PASS — hermetic full-lifecycle smoke over temp repos; phase4-e2e exercises the real flock lease |
| 9 | Dependency & Bloat | script | PASS — 0 dependency changes (stdlib-only Python, no new deps) |
| 10 | Complexity Budget | inline | PASS — new helpers are small line-scanners/union-find; no over-abstraction |
| 11 | Git-History Narrative | script | Nit — team-execute branch-prefixed subjects don't match conventional-commits; subjects >72 chars (run-workflow convention, not code) |
| 12 | Stale-Docs Sweep | subagent (comment-analyzer) | PASS-WITH-NITS — 2 nits (both pre-noted in operator-todos) |
| 13 | Simplification Applied | status row | Not requested — default read-only review |

## Reviewer results

| Reviewer | Required | Status | Verdict | Findings |
|---|---|---|---|---:|
| protocol-reviewer | yes | accepted | pass | 0 |
| type-design-analyzer | yes | accepted | pass | 0 |
| silent-failure-hunter | yes | accepted | pass | 0 |
| test-analyzer | yes | accepted | pass-with-nits | 1 major |
| comment-analyzer | yes | accepted | pass-with-nits | 2 nit |
| dependency-audit (script) | yes | accepted | pass | 0 |
| commit-narrative (script) | yes | accepted | pass-with-nits | nit (subject style) |

## Findings

### Major

- **`tests/smoke/phase4-ready-frontier.sh` over-claims area-packing coverage** (test-analyzer, conf 0.85).
  The header + section B claim to guard "AREA-PACKING dispatch" and "ready = blocked_by-Done AND its
  file surface is free", but section A only drives `idc_autorun_drain.py --frontier`, which computes
  the **dependency** frontier (never reads `surfaces`/areas). The area-carving half is asserted only by
  prose-greps over `agents/idc-build.md` — a real surface-collision dispatch bug would ship green.
  Sharper than the operator-todos "accepted prose-grep limitation": the area **carving**
  (`idc_matrix_check.surface_areas` union-find) IS executable, and `phase3-dag-matrix.sh §(c)` only
  greps the word "area" against an all-disjoint fixture (the union is never exercised).
  **Unblock (both applied):** (a) add a red-when-broken area-partition assertion in
  `phase3-dag-matrix.sh` (surface-sharing pillars across waves → one area; disjoint → separate; count
  pinned); (b) narrow `phase4-ready-frontier.sh`'s header so it states the dependency frontier is the
  behavioral guarantee and area-packing dispatch is doctrine-grep coverage (carving guarded in phase3).
  → **RESOLVED round 2** (commit on `team-execute/sb-fin1`).

### Minor

(none — the operator-todos Minors were cleared as part of the deferred-todos sweep, see below.)

### Nit

- **`scripts/idc_autorun_drain.py` docstring frames `width:` in wave terms** (comment-analyzer, conf 0.88)
  — "the next wave can staff" / "per-wave sous-chef count" contradict the same docstring's wave-blind
  statement. Pre-noted in operator-todos (wave/2). → cleared in the rename pass.
- **`skills/idc-adapter-claude/SKILL.md` "one cook per stage thunk"** (comment-analyzer, conf 0.82) —
  conflates the sequential role-pipeline with the cross-surface cook fan-out. Pre-noted (wave/3).
  → reworded.
- **Commit subjects** don't follow conventional-commits and exceed 72 chars (commit-narrative script) —
  this is the team-execute run-workflow branch convention (`te-execute/sb-*:`), not a code defect.
  Left as-is (run artifact).

## Surfaces cleared

- **Namespacing / `${CLAUDE_PLUGIN_ROOT}` / personal-path discipline** — `idc:<name>` everywhere; no
  shell-var misuse of `${CLAUDE_PLUGIN_ROOT}`; no personal paths or personal-skill refs in shipped
  files; `lint-references.sh` CLEAN (33 files). (protocol-reviewer)
- **Producer/consumer contracts** — matrix-YAML (`blocks_on`) and board-JSON (`blocked_by`) field
  names reconcile; single `parse_matrix` owner (drift-proof); `--frontier`/`width:` consumed verbatim
  by `idc-build.md` / `idc-autorun.md` / `commands/autorun.md`; default output byte-identical.
  (type-design-analyzer)
- **Fail-closed error handling** — every malformed-input shape in `idc_dag.py` / `idc_matrix_check.py`
  / `idc_autorun_drain.py` exits non-zero with a named reason before any clean "PASS"/"width:0" can
  print; a cycle returns `None` path/width (never a falsely-clean DAG). (silent-failure-hunter)
- **Test red-when-broken integrity** (the half that IS executable) — `phase3` pins distinct integers
  (cp=2, width=4 ≠ naive 3) so a wrong DAG goes red; `phase4-e2e-merge-train` exercises the real flock
  lease with a serialize-vs-concurrent contrast pair; `phase8-adapter-fanout-docs` section-scopes its
  greps to defeat the file-wide-grep bypass. (test-analyzer)

## Notes — items intentionally left (out of scope / accepted standard)

- **Prose-grep doctrine tests** (`phase6-autorun-autonomy.sh §B`, `phase4-ready-frontier.sh §B`
  doctrine greps): agent-markdown behaviors with no executable surface. The repo's accepted standard
  (matching `phase6-autorun.sh` / `phase7`) is prose-grep doctrine locks; the negation-governed
  contradiction guards within them ARE genuinely reddable. Converting just these to an "executable
  harness" would be a suite-wide change out of step with the standard — gold-plating. Left noted.
- **`idc_matrix_check.py` runs `idc_dag.analyze()` twice on a PASS** (wave/1 Nit): harmless for
  plan-sized matrices; memoization is optional. Left noted.
