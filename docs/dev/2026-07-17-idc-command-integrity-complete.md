# IDC Command Integrity + External Intake — branch COMPLETE, whole-branch review READY (2026-07-17)

**Branch:** `feat/idc-command-integrity` — HEAD `f964cfd` (this record adds one docs commit).
**Worktree:** `/Users/jeremy/dev/proj/idc-workflow/.worktrees/idc-command-integrity` (main checkout untouched on `main` at `dd170ff`).
**Range:** `dd170ff..f964cfd`, 77 commits, all 8 plan tasks.
**Ledger (authoritative per-round history):** `.superpowers/sdd/progress.md`.
**NOT merged, NOT pushed, NOT published, NOT tagged. No live repo repaired. Issues #106/#154 and live KE #706/#707/#708 untouched.**

## Verdicts

| Gate | Result |
|---|---|
| Tasks 1–7 per-task reviews | Spec PASS / Quality APPROVED (each closed clean; Task 6 round 8, Task 7 round 3) |
| Task 8 (2 capped rounds) | Round-2 blocker was a changelog sentence; the reviewer's prescribed correction applied (`f964cfd`) and verified by the whole-branch review |
| **Whole-branch final review** (`dd170ff..f964cfd`, fresh xhigh reviewer) | **READY — zero BLOCKS**; all six incident failure modes BLOCKED with citations (verdict: `.superpowers/sdd/task-final-review-READY.md`) |

Incident failure modes → structurally blocked (reviewer's load-bearing citations):
stale runtime admission (`idc_command_entry_gate.py:199`) · hidden raw mutations
(`idc_interlock_gate.py:1216`) · incomplete foreign-plan intake (`idc_command_contract.py:960`) ·
dishonest closeout (`idc_command_contract.py:2360`) · unsafe gate ordering
(`idc_gate_repair.py:493`) · fake historical repair (`idc_gate_proof.py:64`).

## Verification receipts (all on exact heads; commands + outcomes in the ledger)

- `bash scripts/lint-references.sh` → `lint-references: CLEAN (36 files scanned)`, exit 0.
- `/bin/bash tests/smoke/run-all.sh` → `idc smoke: ALL GREEN` (69 suites: 37 behavior · 22 mixed · 10 doc), exit 0 — re-run by the controller after every wave and on the final head.
- `python3 scripts/idc_release_check.py` → exit 0 (4.1.0 lockstep). `--governance` → ALL GREEN (79 scenarios).
- `uv run --python 3.13 --with pyyaml bash tests/smoke/phase-governance.sh` → ALL GREEN (79). (Unpinned uv selects the system Python 3.9 and fails environmentally; the pin is now documented in RELEASING.md.)
- `bash scripts/run-evals.sh --all` → clean exit (no evalsets; points at smoke, as the plan expects).
- `git diff --check` silent; worktree clean.
- **Incident e2e (Task 8 Step 5), install sandbox, Codex driver per operator policy:** A1–A7 ALL PASS on a real GitHub board (new sandbox Project #16) — exact-once intake 12/12, tamper refusal, interlock + script-indirection denials (SYNTHETIC hook invocations, disclosed — Codex cannot fire Claude hooks), single-unit Think with 11 units durably queued, honest oracle, janitor coherent, all lifecycle records closed honestly. Capture: `/Users/jeremy/dev/sandbox/_idc-observability/run-t8e2e.txt` + `ke-snap` post-snapshot `041-t8e2e-post-live`.
- **Gate-repair fixture (Step 6):** `.superpowers/sdd/task-8-step6-fixture-receipt.txt` (42 assertions; real journal writer + proof reader; disclosed harness-vs-literal-CLI deviation).

## The hook-fidelity proof — COMPLETE (2026-07-17 morning, operator-approved spend)

**Task 8 Step 4 ran with the REAL Claude `UserPromptExpansion` hook** (nested `claude -p` in the
update sandbox, candidate loaded via `--plugin-dir`):

- **Stale case** (receipt seeded to require `4.1.1` vs running `4.1.0`): Claude Code reported
  `UserPromptExpansion operation blocked by hook:` with the gate's verbatim refusal (names
  `/reload-plugins`; states `/clear does not reload plugin commands or hooks`); the command never
  expanded and **no lifecycle record was opened**. The original receipt was restored byte-exact.
- **Current case** (the sandbox's legacy v1 receipt): the command **expanded**, the real hook
  opened a **nonce-stamped lifecycle record**, doctor ran all ten rows (10 PASS with honest ⚠
  notes), the report persisted nonce-bound, **every PASS row survived its per-row re-derivation
  at closeout** (row 10 via the scanner's nonce-bound report), and the record closed `complete` —
  the entire Task-2 + Task-6 chain live, end-to-end, in a genuine Claude session.

Receipts: `_idc-observability/run-t8hook-stale.txt`, `run-t8hook-current.txt`, snapshots
`029-t8hook-baseline`/`030-t8hook-post`, receipt backup `t8hook-original-receipt.yaml.bak`.
**With this, every verification item in the completion boundary is met.**

## Operator ratification items (rulings made under the 2026-07-17 overnight authorization, all ledger-recorded)

1. Task 6 wave 7 ran past the round-7 cap (the handoff's pending go/no-go) after the lead
   independently re-confirmed both blockers by probe; round 8 returned zero blocks.
2. Task 7 wave 2 ran past its round-2 cap (completing round-1's finding into files the brief
   lists); wave 2b fixed two writer-disclosed same-class sites (incl. `idc_pr_finish.py`, an
   out-of-brief-list file, on an explicit ruling); round 3 returned zero blocks.
3. Task 8's round-2 one-sentence changelog fix was lead-committed and its verification delegated
   to the whole-branch review, which confirmed it and returned READY.
4. Branch-state incident: a terminated teammate's shutdown reset an amended commit off the branch;
   recovered without history rewrite after proving the staged delta byte-identical (`3d9322e`'s
   message carries provenance; lesson saved to memory + runbook notes).

## Deferred-hardening list

27 items, none blocking, each with rationale: `.superpowers/sdd/final-deferred-list.md`
(also summarized in the ledger). Highlights worth future issues: the Think PR-body↔gate binding
door (race-prone without a sanctioned edit helper); a README-badge assertion in the release check;
the engine's re-dispose double-journal (pre-existing, matches the known memory).

## What the operator can do next (each needs separate authorization)

1. ~~Confirm spend → run the hook-fidelity proof~~ **DONE 2026-07-17 morning** (see above).
2. Merge/push/publish 4.1.0 (release = bump+CHANGELOG+push in this repo; no tags).
3. Authorize the live knowledge-engine gate repair (#706/#707/#708) using the now-shipped
   `idc_gate_proof.py`/`idc_gate_repair.py` — dry-run first, exactly as the tool enforces.
