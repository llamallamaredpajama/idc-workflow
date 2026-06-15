# Plan — testing-suite overhaul: make "green" mean "ready for production"

**Branch:** `chore/testing-suite-overhaul` · **Ships as:** `2.1.5` · **Status:** IMPLEMENTED — all four
pieces shipped (P1 audit: pass; P2 `phase7-file-commands-noop-default.sh` + `lib/realistic-repo.sh`;
P3 `phase7-command-prose-invariants.sh`; P4 `docs/RELEASING.md`). Agreed via /grill-me 2026-06-15.

## Why

2.1.3 passed lint + the full smoke suite + a live e2e + an adversarial review, yet shipped a bad
`/idc:update` experience (a destructive keep-vs-replace prompt for data-bearing configs). Three holes
let it through:

1. **Smoke tests re-encode each command's rule in bash and check the encoding** — they never run the
   actual command markdown an agent reads, so a prose/behaviour flaw is invisible.
2. **The e2e measured "no data loss," never "is the default experience non-alarming."** There was no
   assertion for "when nothing needs changing, stay quiet."
3. **Tests used blank inputs.** The bug only manifests on a *filled-in, real* config; a freshly
   scaffolded stub never triggers it.

This plugin is mostly *AI instructions* (command markdown) + small helper programs. You can't truly
unit-test an instruction without running an AI (slow, costly, non-deterministic — rejected). The
durable fix is the opposite of an exotic AI-in-CI layer: **push decisions out of the prose into small
testable programs, and test those programs with realistic inputs, asserting the right outcome —
including the quiet/no-op default.**

## Scope decisions (from /grill-me)

- Applies to the **file-changing commands only**: `init`, `update`, `uninstall`, `doctor`. The
  judgment commands (`think`/`plan`/`build`/`ripple`/`autorun`) stay in prose + hermetic smoke
  guardrails — "is this a good plan?" can't be reduced to a program.
- **No AI-in-CI.** No reviving the dormant `run-evals.sh` role-enactment harness as a required layer.
- Keep it simple: two layers (fast hermetic smoke every PR; one manual pre-release sanity check), not
  three.

## The four pieces

### Piece 1 — Audit: no destructive decision may live only in prose (file-changing commands)

Audit `init`/`update`/`uninstall`/`doctor` and confirm every **mechanical, repo-mutating** decision is
made by a helper program (testable), not by free-form prose. Audit findings (2026-06-15):

- `update.md` — already routes through `idc_config_keys.py`, `idc_receipt_check.py`,
  `idc_template_for.py`, `idc_plugin_freshness.py`. Covered.
- `init.md` — delegates the destructive mechanics to `idc_init_scaffold.sh`, `idc_receipt_check.py`,
  `idc_settings_json.py`. Confirm no remaining prose-only destructive branch (e.g. board provisioning
  gates are read-only/advisory; the receipt stamp + `--customized` flagging is in the helper).
- `uninstall.md` — delegates to `idc_receipt_check.py` (removal manifest) + `idc_settings_json.py`.
  Confirm the "only delete what IDC created" decision is helper-driven (it is: the receipt is the
  manifest).
- `doctor.md` — **all 7 checks are prose** (zero helper calls), BUT doctor is **read-only/advisory**
  (no repo mutation), so a wrong call is a misleading report, not damage. Lower priority — extract a
  check into a helper only if it's cheap and high-value; otherwise leave and rely on the prose
  text-checks (Piece 3). Do NOT force a refactor.

Deliverable: a short written audit result in this doc + any small extraction the audit surfaces. If
the audit finds nothing destructive living only in prose, that is a passing result — record it.

**Audit result (2026-06-15): PASS — no extraction needed.**

- `update` — fully helper-driven (4 helpers). ✓
- `uninstall` — the deletion manifest *is* the receipt (`idc_receipt_check.py verify`); the
  unchanged→remove / customized→ask classification is helper-fed; never deletes what it didn't create.
  The only prose path is the pre-receipt hardcoded-fallback footprint (a fixed list, not a judgment). ✓
- `init` — file scaffolding is idempotent-never-clobber (`idc_init_scaffold.sh`); receipt + settings
  via helpers. The one prose-driven mutation is **board provisioning** — inherently live-`gh` (can't
  be a pure offline program), and already provenance-gated + idempotent (2.1.1/2.1.2). The "stamp the
  two data configs `--customized`" decision is a hardcoded prose list → backstopped by Piece 3. ✓
- `doctor` — all 7 checks are prose, but **read-only** (no repo mutation), so no destructive decision
  exists to extract. ✓

Conclusion: every repo-*mutating* decision already lives in a testable helper. Piece 1 is a passing
audit; the residual prose invariants are locked by Piece 3's text-checks.

### Piece 2 — Raise the test bar for the four file-changing commands

Add a small shared **realistic-project fixture** + an **older-version-setup** variant, and make every
file-command's smoke test clear this bar:

- **Realistic input:** run against a *filled-in* repo (real-looking `domains`, `field_ids`,
  `project_number`, `prd`), not just a blank scaffold; include an "init'd at an older version, now
  updating" case.
- **Right outcome:** assert the correct result for the operation.
- **Quiet/no-op default (the 2.1.3 catch):** when the project is already correct, assert the command
  does **nothing destructive and raises no prompt** — no file overwrite, no diff-and-ask. This is a
  first-class, required assertion for each file-command.

Mechanics: a `tests/smoke/fixtures/` helper (or a shared shell function) that emits a populated
config repo, reused across the file-command tests. The existing `phase7-update-config-structure.sh`
already does an inline version of this; standardize it.

### Piece 3 — Cheap text-checks on the four command markdown files (backstop, every PR)

A handful of grep-style invariants on the prose that remains (runs in smoke, no LLM, no cost):

- `update.md` must instruct **never overwrite a data-bearing config** / never offer whole-file replace
  for them.
- `init.md` must stamp the two data configs `--customized`.
- (extend as the audit surfaces other must-hold prose invariants — keep the list small + high-value.)

One such check already exists (`phase7-update-config-structure.sh` asserts §A carves out the missing
case). Add a focused `tests/smoke/phaseX-command-prose-invariants.sh`.

### Piece 4 — Release gate: "green = ready for production"

A short `docs/RELEASING.md` checklist, gating the version bump/tag. "Ready" =

1. CI green (lint + full smoke).
2. The new realistic-input + no-op-default tests green.
3. **One read-only command** run against a real already-configured repo:
   `python3 scripts/idc_config_keys.py --added <real-repo-config> <rendered-template>` for each data
   config → confirm "no destructive prompt, correct preserve/advisory." (The exact read-only check run
   against lootr-web during the 2.1.4 fix.)

Optionally surface the checklist via `idc_release_check.py` (already run by `lint-references.sh`) so a
release can't be tagged without acknowledging it — keep it advisory if wiring it hard is fragile.

## Verification (this plan's own exit criteria)

- `bash scripts/lint-references.sh` exit 0; `bash tests/smoke/run-all.sh` ALL GREEN incl. the new
  realistic-input/no-op tests + the prose-invariant test.
- Each of the four file-commands has a smoke test that runs against a realistic fixture and asserts the
  quiet/no-op default.
- `docs/RELEASING.md` exists with the 3-point gate; version 2.1.5 lockstep + CHANGELOG.
- A live e2e (the existing sandbox loop) still passes; fresh-teammate adversarial pass clean.

## Out of scope

AI-in-CI; reviving the role-enactment eval harness as a required layer; refactoring the judgment
commands; testing the team-orchestrator pipeline end-to-end (covered by smoke guardrails).
