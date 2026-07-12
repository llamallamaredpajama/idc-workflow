# Phase 4 — Wave 1 handoff (pi-team run `phase4-2026-07-06`)

**Paused deliberately after Wave 1 at operator request. The operator continues Waves 2–4 from
the Pi runtime.** Plan: `~/.claude/plans/see-phase-4-of-quirky-neumann.md` (approved 2026-07-06).
Run ledger: `~/.claude/team-execute-runs/phase4-2026-07-06/run-ledger.md`. Lead brief (all unit
briefs, incl. U2/U5 not yet dispatched): `~/.claude/team-execute-runs/phase4-2026-07-06/lead-brief.md`.

> **Addendum 2026-07-07:** Wave 2's builder already ran to completion under the operator's own
> session — **PR #149 (`te/phase4-2026-07-06-u2-fix`) is READY and awaiting the two-lens gate.**
> The live lead is now session `019f3a5b…`, run `team-phase4-20260707-021525-c65f` (review-1 up).
> Panes: lead TUI (left) · `pi-team dashboard` (top right) · `watch-run.sh` feed (bottom right,
> script at `~/.claude/team-execute-runs/phase4-2026-07-06/watch-run.sh <run-id>`). The run-id
> details below reflect the original Wave-1 pause state.

## Pick up here

The **pi lead session is alive and waiting** with full context (told to stand by, not dispatch):

- tmux session `pi-lead`, visible in cmux workspace **"pi-team phase4"** (left pane = lead,
  right pane = `pi-team dashboard`). Attach anywhere: `tmux attach -t pi-lead`.
- Lead = pi session on `openai-codex/gpt-5.5`, pi-team run `team-phase4-20260706-234009-2f3c`,
  roster now lead + `review-1` (gpt-5.5). Builders 1–3 killed after their units merged.
- **To start Wave 2, type into the lead pane:**
  *"Dispatch Wave 2 now: team_add one builder with the U2 (#142) brief from the lead brief —
  common rules + unit brief verbatim."*
- Every desk step below is plain bash — run it in any terminal (or from a pi session with
  bash): nothing requires Claude.

## What landed (Wave 1)

On `te-integration/phase4-2026-07-06` (pushed; base `main` @ `e5048f9`):

| Commit | Unit | Content |
|---|---|---|
| `68bc195` | — | `.pi/team-lead.yaml` (phase4 preset) + `.pi/specialists-overrides.yaml` (builder write-roots for nested worktrees) |
| `2ac2434` | U1 (#141) | journal spine: every engine op appends `{who/what/when/guard-evidence hash}` NDJSON to `docs/workflow/transition-journal.ndjson`, both backends; fail-soft on write failure (loud stderr warn) **by design** — plan §6 rollout discipline; U2 reconciliation is the designed gap detector. New governance tests `journal-append.sh` (all 4 op kinds pinned red-when-broken, fs+github) + `journal-append-only.sh`. |
| `3355dc4` | U3+U4 (#143,#144) | Rule O in `lint-references.sh` via new `scripts/idc_lint_machine_yaml_refs.py`: validates `Stage:`/`Status:` values (per-field domains) + `eng <op>` references against `templates/workflow-machine.yaml`; WORKFLOW.md §3.1 board-schema table demoted to a machine-yaml pointer; `idc_release_check.py --governance` runs the governance lane red-when-broken (default path byte-identical). New tests `machine-yaml-crosscheck.sh`, `release-gate-governance.sh`. |

U3+U4 merged as ONE squash because the builders tangled (see sharp edges). PRs #147/#148
closed as audit trail (merges were local squashes — `gh pr merge` GraphQL stays off-limits).
Issues #141/#143/#144 closed with merge SHAs.

**Review ceremony receipts:** two lenses per unit, two fix rounds, everything verified by repro:
codex round 1 (P1 retry regression + 3×P2 matcher/test defects — all reproduced, fixed,
re-verified), review-1 round 2 (FAIL/BLOCKED reports with mutation checks →
`.worktrees/team-phase4-20260706-234009-2f3c/docs/reviews/2026-07-0{6,7}-pr14*.md`), re-verdict
**PASS both PRs**. Desk waivers recorded on #143: fail-soft journal policy (plan §6); surface
expansion (Rule O helper + a stale SKILL.md ref the new lint itself caught).

## Verification (drift check for resume)

- `te-integration/phase4-2026-07-06` HEAD = `3355dc4` (pushed). `origin/main` = `e5048f9` (untouched).
- Integration re-verify on `3355dc4`: **lint CLEAN · full smoke suite ALL GREEN (36 behavior ·
  22 mixed · 10 doc) · governance uv-parity spot checks PASS** (2026-07-06, real checkout).
- Full receipts: `/Users/jeremy/dev/sandbox/_idc-observability/phase4-wave1-integration-verify.txt`
  (+ `phase4-baseline-smoke.txt`, `phase4-codex-review-u{1,34}.txt`).
- Worktrees: shared `.worktrees/team-phase4-20260706-234009-2f3c` (pi-team's, keep while the run
  lives) + nested `u1/u3/u4` + desk `desk-u1`/`desk-u34` — all disposable; remove desk/nested ones
  any time (`git worktree remove --force <path>`).
- Open kanban: **#142 (U2, unblocked)**, **#145 (U5, blocked by #142)**, **#146 (U6, blocked by #145)**.

## The auth fix you must not lose

`pi-`-launched children run under an env **allowlist** (`SAFE_ENV_NAMES` in
`pi-harnesses/scripts/pi-minus-launcher.ts`) — provider keys are stripped; the first run died
keyless. Fix in force: **`PI_CODING_AGENT_DIR=$HOME/.pi/agent-phase4`** (allowlisted) — a mirror
of `~/.pi/agent` (symlinks) whose `auth.json` (0600) also carries the google key. The live tmux
session already has it exported. **Any relaunch of the lead needs:**

```bash
export PI_CODING_AGENT_DIR="$HOME/.pi/agent-phase4" \
       PI_HARNESS_BUILDER_MODEL=google/gemini-2.5-pro PI_HARNESS_BUILDER_THINKING=high \
       PATH="$HOME/.bun/bin:/opt/homebrew/bin:$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
cd /Users/jeremy/dev/proj/idc-workflow && pi   # then: /team resume — or /team on phase4 for a fresh run
```

(`/team resume` restores state read-only — it can NOT message old workers; a dead lead means
kill leftovers via `/team kill`, then a fresh `/team on phase4`.)

## Desk runsheet for Waves 2–4 (copy-paste; run from repo root on te-integration)

**Per-unit gate (after the builder's PR flips ready):**
```bash
git fetch origin
git worktree add .worktrees/desk-uN origin/te/phase4-2026-07-06-uN --detach
cd .worktrees/desk-uN
bash scripts/lint-references.sh
for t in tests/smoke/governance/*.sh; do case "$t" in *lib.sh) continue;; esac; bash "$t" >/dev/null 2>&1 || echo "FAIL: $t"; done
codex review --base te-integration/phase4-2026-07-06      # lens 2 (codex CLI)
```
Lens 1: type into the lead pane — *"send review-1 the adversarial review instruction from your
brief for PR #N (branch te/phase4-2026-07-06-uN, issue #M)"*. Blocker/Major → tell the lead to
send the builder a fix task (cap 3 rounds); re-gate; ask review-1 for a delta re-verdict.

**Per-unit merge (two-lens green only):**
```bash
cd /Users/jeremy/dev/proj/idc-workflow            # main checkout, on te-integration
git merge --squash origin/te/phase4-2026-07-06-uN
git commit -m "uN <title> (closes #M) — two-lens PASS receipts in commit body"
git push origin te-integration/phase4-2026-07-06
gh pr close <PR> --comment "merged locally as <sha>; audit trail"
gh issue close <M> --comment "merged to te-integration as <sha>"
bash scripts/lint-references.sh && bash tests/smoke/run-all.sh    # real checkout, PATH incl. ~/.bun/bin
```

**Wave 2 (U2 #142):** dispatch after typing the go-line above. Gate + merge as per runsheet.
U2 = reconcile board↔journal↔git in `idc_git_janitor.py` + doctor row, janitor rotation,
`idc_journal_replay.py` (empty diff on lifecycle), 3 new governance tests. Full brief in lead-brief.md.

**Wave 3 (U5 #145, ablation batches):** ONE long-lived builder; per batch the DESK runs the
gate — `bash scripts/lint-references.sh && bash tests/smoke/run-all.sh` + governance lane —
then tells the lead keep/restore (`git revert` on restore). Batch log:
`docs/dev/phase4-demotion-log.md`. Cap 3 failed batches → blocked-stop per contract.

**Wave 4 (U6 #146, acceptance + release):** verification surface = lint (+ cross-check
red-when-broken spot check), run-all, governance lane under `python3` AND `uv run --with pyyaml`,
`run-evals.sh` (clean exit = green; evalsets retired), journal replay empty diff, doctor
divergence negative test, `idc_release_check.py --governance` red on seeded failure; **sandbox
e2e via `codex exec`** (install + update sandboxes; recipe + orchestrator-prompt rules in
`CLAUDE.md` §e2e and `docs/dev/local-e2e-testing.md`; hook-fidelity caveat applies). Then
CHANGELOG + version lockstep bump (plugin.json + marketplace.json), final codex sweep of
`main...te-integration`, and — **merge-on-green to main is operator-authorized (2026-07-06)** —
local squash to main + push. Close #146, `/team kill` all, `git worktree remove` the leftovers,
`/team tidy --apply`, `/team off`.

## Sharp edges Wave 1 hit (so you don't re-hit them)

1. **Keyless builders** → fixed via the mirror agent dir above; probe before dispatch:
   `env -i HOME="$HOME" PATH="$PATH" PI_CODING_AGENT_DIR="$HOME/.pi/agent-phase4" pi -p --model google/gemini-2.5-pro "Reply PROBE-OK"`.
2. **Builders share the spawn cwd.** u3/u4 both committed in the shared team worktree despite
   worktree instructions → tangled branch, merged as one. Mitigation for U2/U5: dispatch ONE
   builder per wave (already the plan), and the brief's worktree step tells the builder to
   `cd` per tool call — Gemini loses cwd between calls.
3. **Gemini "final packet" quality is flaky** (garbled repetition, /tmp file pointers). Trust
   the artifacts (branch, PR, tests), not the prose.
4. **Watchers:** a PR-state poller misses bare pushes — watch branch SHAs
   (`git fetch && git rev-parse origin/<branch>`) for fix rounds.
5. **review-1 writes reports into the shared team worktree** (`.worktrees/team-…/docs/reviews/`),
   not the main checkout. Copy them out before `/team tidy`.
6. **codex reviews find real bugs every round** (4-for-4 here, again). Never skip that lens.

## Open questions / deferred

- None blocking Wave 2. U6 carries the release ceremony end-to-end (incl. `docs/dev/` phase-4
  record + CHANGELOG); merge-on-green to main already authorized.
- Phase-4 contract blocked-stop triggers stand: ablation regression ×3 batches; replay exposing
  non-additive Phase-2 engine gaps.
