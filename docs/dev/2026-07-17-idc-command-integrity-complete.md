# IDC command integrity — 4.1.2 final-hardening completion (2026-07-17)

**Branch:** `feat/idc-command-integrity` in the isolated
`.worktrees/idc-command-integrity` worktree.

**State:** **MERGED to `main` and pushed 2026-07-17** (operator-directed: fresh e2e re-runs green →
final simplify pass re-gated ALL GREEN → merge). Release 4.1.2 is live for `claude plugin update`;
no git tag (this plugin releases by version bump + push). No live knowledge-engine item was changed;
#706/#707/#708 remain untouched — the live gate repair is still a separate operator decision.

The pre-merge finale: both sandbox e2e suites were re-run at the final head with zero plugin
defects (install lifecycle + literal gate-repair proof on disposable Project #20; update path with
byte-preserved operator configs), and a four-lens cleanup pass landed as the branch's last commit
(marker wire-contract single-sourced, entry-gate matcher lint guard proven red-when-broken,
per-invocation read caches; skips recorded in `.superpowers/sdd/simplify-pass-2026-07-17.md`).

The original eight-task command-integrity package passed its whole-branch review at 4.1.0. The
follow-up 4.1.1 pass closed ten deferred findings. This 4.1.2 pass closes every remaining entry in
`.superpowers/sdd/final-deferred-list.md`; all 27 now have a concrete resolution.

## What 4.1.2 closes

- Intake helpers now produce exact, source-owned, nonce-bound failure receipts. A successful retry
  clears the receipt; a second real failure can close Intake honestly as `blocked_external`.
- Doctor and Janitor evidence is source-owned. Doctor rechecks the complete ten-row result at
  closeout, including the read-only Recirculation and GitHub field probes, and discloses its
  transient report and possible `.gitignore` append.
- Malformed tracker configuration is indeterminate rather than silently treated as filesystem.
  GitHub Project absence is accepted only for GitHub's exact missing-ProjectV2 response naming the
  configured project number.
- Gate repair refuses Todo pointers that still have blockers. Re-disposing an already-Done gate is
  a no-op only when the strict journal proves the same disposition; missing, conflicting, or corrupt
  history refuses.
- Hook wrappers check for Python 3.10 before importing the helpers. Smoke tests preserve a usable
  Homebrew/local PATH, and a read-only stability checker detects changes after a worker exits.
- Release metadata is 4.1.2 and README inventories all nine shipped agents.

## Fresh verification receipts

- `bash scripts/lint-references.sh` — CLEAN.
- `env PATH=/usr/bin:/bin bash tests/smoke/run-all.sh` — ALL GREEN, 70 phases
  (38 behavior, 22 mixed, 10 documentation).
- `uv run --python 3.13 --with pyyaml bash tests/smoke/phase-governance.sh` — ALL GREEN,
  83 real scenarios plus the self-check.
- `python3 scripts/idc_release_check.py --governance` — release metadata and governance green.
- The focused report, lifecycle, entry-freshness, gate-repair, disposal-journal, and prose suites
  all pass on the final bytes.
- `python3 scripts/idc_worktree_stability.py --repo "$PWD"` — three identical read-only samples.
- `git diff --check` and the relevant Python compiles are clean.

These commands are rerun immediately before the final implementation commit; the authoritative
outcomes are also appended to `.superpowers/sdd/progress.md`.

## Final-head GitHub-fidelity sandbox run

The disposable install sandbox was reset to `idc-baseline`; its old Project #16 was deleted and the
run created private Project #19. The candidate 4.1.2 source was driven from a detached Codex session,
not from this plugin-source session.

The run proved:

- Init provisioned the five fields and closed `complete` with a verified nine-file receipt.
- A real Intake extraction failure wrote helper/operation/exit/diagnostic/session/nonce evidence;
  a successful retry cleared it; a second failure closed `blocked_external` with exact evidence.
- Doctor ran all ten rows and its typed writer plus nonce-bound Janitor report closed `complete`.
- Real GitHub stderr was exactly
  `GraphQL: Could not resolve to a ProjectV2 with the number 2147483647. (user.projectV2)`;
  the production matcher returned `True` and the real Project #19 config was restored byte-for-byte.
- Final lifecycle state had zero active records, receipt verification was `ok: true`, and the
  candidate Janitor honestly returned advisory exit 1 for five report-only foreign branches.

Capture: `/Users/jeremy/dev/sandbox/_idc-observability/run-final-head-412-e2e.txt`.
Snapshots: `052-final-head-pre-055c7839` and `053-final-head-412-post-0e861526`.

Two final read-only edits landed in the candidate while that external run was in progress:
`commands/janitor.md` wording and the old-Python check in `scripts/idc_recirc_sweep_hook.sh`.
Neither changed an exercised Intake/Doctor/GitHub path. Their dedicated prose and entry-freshness
tests were run after the edits, so the receipt does not overstate the sandbox run as byte-frozen.

## Literal gate-repair proof

On disposable Project #19, merged sandbox PR #17 was bound to requirements gate #25 and pointer #26.
The gate was deliberately closed outside the guarded door, leaving the exact corrupt shape:
gate CLOSED / Buildable / Todo and pointer Consideration / Blocked by #25.

The literal `idc_gate_repair.py` command ran dry-run first, then `--apply`. Readback proved:

- gate #25 stayed CLOSED and became Buildable / Done;
- pointer #26 became Consideration / Todo with no remaining blockers;
- proof kind is `verified-reconciliation`;
- the journal contains exactly one `gate-reconciliation` and one real `unblock`, with zero
  fabricated `dispose` records;
- a second `--apply` was a clean no-op and the journal remained five total fixture records.

Receipt: `.superpowers/sdd/task-final-deferred-gate-repair-receipt.txt`.
Snapshot: `054-final-head-412-gate-repair-0e861526`.

## Hook fidelity

The earlier real Claude `UserPromptExpansion` proof remains valid and is not replaced by a synthetic
claim: a stale runtime was blocked before expansion, while the current runtime opened a nonce-bound
Doctor lifecycle, re-derived all ten rows, and closed complete. Captures remain
`run-t8hook-stale.txt` and `run-t8hook-current.txt` under `_idc-observability/`.

## Operator boundary

The verified branch and worktree stay intact. Merging, pushing, publishing 4.1.2, and repairing the
live knowledge-engine gate are separate operator decisions.
