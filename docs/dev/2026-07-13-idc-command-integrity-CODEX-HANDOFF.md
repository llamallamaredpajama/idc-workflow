# IDC Command Integrity — Codex Handoff (Tasks 1–3 done, 4–8 remaining)

**Written:** 2026-07-13, at the operator's request to stop after Task 3 and hand off to Codex.
**Branch:** `feat/idc-command-integrity`
**Worktree:** `/Users/jeremy/dev/proj/idc-workflow/.worktrees/idc-command-integrity` (git-ignored `.worktrees/`)
**Main checkout:** `/Users/jeremy/dev/proj/idc-workflow` — untouched, still on `main` at `dd170ff`. Do NOT edit it.

## What this is
Execution of the plan `docs/dev/2026-07-12-idc-command-integrity-and-external-intake-plan.md` (the SOLE
spec — 8 serial tasks, test-first) under the protocol in
`docs/dev/2026-07-12-idc-command-integrity-claude-execution-runbook.md`. The plan and runbook win over
this handoff; if they disagree, report the conflict before changing code.

## Hard constraints (unchanged — do NOT cross)
- No merge, no push, no publish, no version bump except as Task 8 specifies (and only after Task 8's
  gates pass). Current `.claude-plugin/plugin.json` version is still `4.0.0`; the `4.1.0` bump is Task 8.
- Do NOT touch issue `#106`, issue `#154`, PR/gate/pointer `#706/#707/#708`, or the live
  `knowledge-engine` repo. Task 8 stops at a committed, verified branch pending separate operator
  authorization for merge/publish/live-repair.
- Every tracker write goes through `scripts/idc_transition.py` / the tracker adapters / a named
  reconciliation helper. `IDC_HOOKS_OBSERVE_ONLY=1` is the ONLY debug bypass — never add a second.
- Run `bash scripts/lint-references.sh` (must print `lint-references: CLEAN`) before every commit.
- Bash **3.2** compatibility is required for smoke tests (this machine's `/bin/bash` is 3.2.57; the
  default PATH `bash` is homebrew 5.x and will MASK 3.2 breakage — see Lessons below).

## Status
| Task | State | Commits (base..head) | Review outcome |
|---|---|---|---|
| Baseline | — | `dd170ff` | plan+runbook+forensics |
| 1. Runtime freshness → repo receipt | ✅ DONE | `dd170ff..50c5bcc` (`5629c3e`,`2c7c195`,`50c5bcc`) | Spec PASS / Quality APPROVED (3 rounds) |
| 2. Command lifecycle envelope | ✅ DONE | `50c5bcc..503b6c7` (`6401fb4`,`d723453`,`f1402af`,`fe7a771`,`939ae49`,`503b6c7`) | Spec PASS / Quality APPROVED (6 rounds) |
| 3. Hard mutation interlock + PR finisher | ✅ DONE (see note) | `503b6c7..0f97396` (16 fix commits) | Interlock class review-CONFIRMED closed; final journaling finding resolved (`0f97396`) per reviewer rec + directly verified. A final rubber-stamp whole-Task-3 review is optional. |
| 4. Exact-once intake manifest | ⏳ TODO | — | — |
| 5. Next-action oracle | ⏳ TODO | — | — |
| 6. `/idc:intake` + command-specific closeouts | ⏳ TODO | — | — |
| 7. Legacy gate repair (no fake history) | ⏳ TODO | — | — |
| 8. Release gate (docs, 4.1.0 bump, hook-fidelity + e2e proof) | ⏳ TODO | — | — |

**Post-Task-3 broad checkpoint (runbook-mandated): PASS** — `lint-references: CLEAN` and
`tests/smoke/run-all.sh` → `idc smoke: ALL GREEN` in the real checkout (default bash), and the Task-3
governance test verified under real `/bin/bash` 3.2.57 (exit 0).

### Task 3 note (why it took 14 rounds, and its terminal posture)
Task 3 is the security-critical guard that must deny the incident's raw `gh` mutations and
`bash <script>` indirection during an active IDC command, without breaking legitimate work. The
independent reviewer found real bypasses across many rounds (dynamic gh endpoints, command
substitution, `env -S`, `BASH_ENV`, wrapper/assignment interleaving, comment injection, multi-root
GraphQL, etc.). Final design: **defense-in-depth, fail-closed on anything opaque/dynamic** — since all
real mutations now flow through sanctioned Python doors, an uninspectable raw write-shaped command is
always denied. A single fixpoint prefix-normalizer (`_peel_to_inspect_head`) closes the
wrapper/assignment/control-word interleaving class by construction.
- **Accepted, documented limitation (NOT a blocker):** privilege-escalation wrappers
  (`sudo`/`doas`/`su -c`) are not followed for script-FILE indirection (a raw-`gh` combo behind them is
  still string-caught). The interlock is defense-in-depth, not a complete shell sandbox (shell is
  Turing-complete). If a later reviewer raises a *novel exotic* static-shell evasion, treat it as a
  noted limitation, not a blocker — unless it's a *straightforward* form an agent would naturally use.
- Task 3 added: hard active-command interlock (`scripts/hooks/idc_interlock_gate.py`), sanctioned PR
  finisher (`scripts/idc_pr_finish.py`), `idc_transition.py` `unblock --by` / `move --to-stage` /
  `set-field` / `link --kind blocks` engine doors + native-edge creation in `idc_gh_board.py`,
  `init`/`uninstall` command-keyed carve-outs, a schema-reconciliation journal record in
  `scripts/idc_stage_options.py` `apply` (readback + `op="schema-reconciliation"`, replay-safe), and
  routed the tracker-adapter/github/filesystem/gate-issue skills + `idc-plan`/`idc-recirculator` agents
  through the sanctioned doors.
- **Final review state:** the last independent review confirmed the interlock class closed (direct
  mutation denied, indirect fixture denied, sanctioned helper allowed, inactive session warned; bash 3.2
  verified) and raised ONE finding — that `idc_stage_options.py apply` must journal its reconciliation.
  That was fixed in `0f97396` exactly as recommended (durable `schema-reconciliation` record, no false
  reconciliation in replay) and verified directly (record-shape asserted, `journal-replay.sh` +
  `journal-replay-field-only.sh` pass, smoke 69/69 GREEN). No substantive issue remains open; a final
  rubber-stamp review of the full Task-3 range (`503b6c7..0f97396`) is a reasonable first Codex step but
  is not blocking.

## How the loop was run (adapt as needed in Codex)
Controller = `superpowers:subagent-driven-development`. Per task, strictly serial, one writer at a time:
1. Record `TASK_BASE=$(git -C <worktree> rev-parse HEAD)`.
2. Extract the brief: `<sdd-skill>/scripts/task-brief PLAN N` → `.superpowers/sdd/task-N-brief.md`.
   (`<sdd-skill>` = `/Users/jeremy/.claude/plugins/cache/claude-plugins-official/superpowers/6.1.1/skills/subagent-driven-development`.)
3. Implement test-first against the brief (exact values verbatim). Commit with the plan's commit message.
4. Freeze: `TASK_HEAD=$(git rev-parse HEAD)`; verify the range is the expected commits and main is
   untouched.
5. Package: `<sdd-skill>/scripts/review-package "$TASK_BASE" "$TASK_HEAD"` → a `.diff` file.
6. **Independent review** by a fresh read-only Codex session, launched detached in its own cmux
   workspace. Reusable helpers already staged in `.superpowers/sdd/`:
   - `build-review-prompt.sh N PKG [EXTRA]` → writes `task-N-review-prompt.md` (embeds the runbook's
     read-list + verdict contract + Global Constraints).
   - `run-review.sh N` → runs `codex exec --ephemeral --sandbox read-only -m gpt-5.6-sol -c
     'model_reasoning_effort="max"' -C <wt> -o task-N-review.md - < task-N-review-prompt.md`.
   - Launch: `cmux workspace create --name idc-review-task-N --cwd <wt> --command "bash
     .superpowers/sdd/run-review.sh N"`; poll for `task-N-review.md`.
   - The review contract yields two verdicts: **Spec compliance: PASS/FAIL** and **Task quality:
     APPROVED/CHANGES REQUIRED**. Any Important finding or FAIL/CHANGES-REQUIRED blocks the next task;
     loop fixes until both pass.
7. On clean review, append a completion line to `.superpowers/sdd/progress.md` (the durable ledger) and
   start the next task fresh.

**In Codex specifically:** you ARE the Codex engine, so the "independent reviewer" separation is weaker.
Options: (a) drive the implement→review loop with your own fresh sub-sessions/subagents and keep the
reviewer read-only; (b) use `codex review --base <task-base>` as a read-only lens; or (c) coordinate a
nested `claude -p` reviewer if the operator authorizes Anthropic spend. Keep the *fail-closed, adversarial*
review discipline — green tests alone are NOT sufficient (the reviews caught real bugs green smoke missed).

## Durable artifacts (all under `.superpowers/sdd/`, git-ignored working area)
- `progress.md` — the recovery ledger: per-task status + every review round's findings. **Read this first.**
- `task-{1,2,3}-brief.md` — extracted task specs. `task-{1,2,3}-report.md` — implementer + fix reports.
- `task-{1,2,3}-review*.md` — every review verdict (archived per round). `review-*.diff` — packages.
- `global-constraints.md` — the plan's Global Constraints (verbatim, handed to every reviewer).
- `build-review-prompt.sh`, `run-review.sh` — the reviewer launch helpers.

## Remaining tasks (from the plan — read the plan section for each; these are pointers)
- **Task 4** (`scripts/idc_intake_manifest.py` + fixtures + `external-intake-completeness.sh`): stdlib
  Markdown → exact-once JSON manifest (schema_version 1), class→route table, independent-review binding.
  Model tier the runbook assigns: **Sonnet/high**.
- **Task 5** (`scripts/idc_next_action.py` + `next-action-truth.sh`): read-only oracle → one truthful
  next command from intake manifests + live tracker state. Reuse `idc_autorun_drain.py` readers. **Sonnet.**
- **Task 6** (`commands/intake.md`, `agents/idc-intake.md`, all 11 `commands/*.md`, adapters, phase
  tests): `/idc:intake` + command-specific `validate_closeout()` matrix; every pipeline command's final
  response comes from the oracle. Consumes Tasks 2/4/5. **Opus/xhigh.**
- **Task 7** (`scripts/idc_gate_proof.py`, `scripts/idc_gate_repair.py` + `board-before.json` +
  `gate-repair-session-b7a93ff6.sh`): dry-run-first legacy-gate repair that journals
  `gate-reconciliation`, NOT a counterfeit guarded dispose. **Opus/xhigh.**
- **Task 8** (docs, scaffold, `CHANGELOG`, lockstep `plugin.json`/`marketplace.json` → `4.1.0`): release
  gate. Runs the full local gate + real Claude `UserPromptExpansion` hook-fidelity proof (needs operator
  spend approval; Codex cannot fire Claude hooks — assert via the real artifacts/synthetic payloads and
  mark the hook proof blocked if spend isn't authorized) + the incident e2e in the install sandbox.
  **Stops at the committed, verified branch. No merge/push/publish/live-repair.** **Opus/xhigh + close
  supervision.**

## Lessons / gotchas that bit us (save time)
- **`git checkout -- <file>` reverted uncommitted fixes** repeatedly during red-when-broken proofs. Use
  scratchpad `cp` backups or `git stash` for break/restore, never `git checkout` on a dirty file.
  Clear `scripts/__pycache__` after any Python break/revert (a stale `.pyc` masked a revert once).
- **The read-only Codex review sandbox denies `mktemp`**, so the reviewer canNOT run the temp-repo smoke
  suite — it reports those as "Cannot verify." Trust the implementer's/your own real-shell smoke run for
  behavioral green; the reviewer verifies via in-process probes + static analysis.
- **Bash 3.2:** the default PATH `bash` (homebrew 5.x) hides bash-4-only constructs (`mapfile`,
  `declare -A`, `${v^^}`, `&>>`, `|&`). Test governance/smoke scripts with `/bin/bash` (3.2.57). The
  Task-3 final review caught a `mapfile` that green smoke missed.
- `${CLAUDE_PLUGIN_ROOT}` is a markdown substitution token, NOT a shell/Python env var (empty in a Bash
  snippet). A hook/script that needs the root takes it as an argv argument. Emitting the literal token
  from Python produced broken remediation strings twice — always interpolate the real path.
- **Substrate:** implementers ran as fresh in-process subagents rooted at the worktree (one writer at a
  time); reviewers as detached read-only Codex via `cmux workspace create`. Named cmux-teammate spawns
  failed here ("Could not determine pane count") — in-process subagents were reliable.
- Model allocation (runbook): T1/4/5 Sonnet; T2/3/6/7 Opus; T8 Opus + supervision; every review on the
  strongest configured reviewer (`gpt-5.6-sol`, reasoning max).

## Whole-branch review + completion (after Task 8, per runbook)
After all 8 task reviews are clean: re-run the full verification set, generate one final package
`review-package $(git merge-base main HEAD) HEAD`, run a fresh read-only whole-branch Codex review that
specifically checks the incident's failure modes are structurally blocked (stale runtime admission,
hidden raw mutations, incomplete foreign-plan intake, dishonest closeout, unsafe gate ordering, fake
historical repair), require an overall READY/NOT READY. Then STOP with receipts. Nothing merged, pushed,
published, repaired live, or closed on GitHub without separate operator authorization.
