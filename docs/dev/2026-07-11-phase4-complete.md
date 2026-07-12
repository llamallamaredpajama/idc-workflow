# Phase 4 complete — 4.0.0 released (2026-07-11)

The v4 deterministic-core refactor (plan §5,
[`2026-07-03-deterministic-core-refactor-plan.md`](2026-07-03-deterministic-core-refactor-plan.md))
is released to `main` as **4.0.0** (squash `89117d0`, closes #146). Phase 4 shipped the
journal/reconciliation spine + machine-as-data + release gate + prose demotion; phases 0–3 were
already on `main` unreleased — 4.0.0 ships the whole inversion to installed users
(`claude plugin update`).

## Scope decision (operator, 2026-07-11): DESCOPE path

The #150 close-out ran as three slices. **W1** (sweep-journal, `83fa479`) and **W2**
(dispose-terminal, `319d299`) are in this release. **W3** (flip the janitor journal-replay check on
by default) went 24 codex review rounds without converging — the non-convergence is architectural
(board write + journal append are two non-atomic writes; no transaction) — so the operator descoped
it: the replay check ships **opt-in** (`idc_git_janitor.py --check-journal-divergence`), the
24-round hardening is parked on branch **`te/phase4-closeout-w3` @ `7cfae2b` (branch kept — do not
delete)**, and the transactional design decision is tracked as **#154**. #150 stays open, scoped to
what #154 unlocks.

## U6 acceptance surface — receipts

All run 2026-07-11 on `te-integration/phase4-2026-07-06` (`319d299` → `d194bef` as acceptance
fixes landed), this checkout. Sandbox captures in
`/Users/jeremy/dev/sandbox/_idc-observability/` (operator-local).

1. **Reference lint + red spot-check** — `bash scripts/lint-references.sh` → `lint-references:
   CLEAN (34 files scanned)`, exit 0. Red check: seeded `Stage: Wibble` into `commands/janitor.md`
   → `Invalid Stage reference: 'Wibble'`, exit 1; removed → clean again.
2. **Full smoke** — `bash tests/smoke/run-all.sh` → `idc smoke: ALL GREEN` (69 phases; assertion
   classes 36 behavior · 22 mixed · 10 doc + the new phase7 case below). Re-run green after every
   acceptance fix and post-merge on `main`.
3. **Both-parser governance parity** — `engine-machine-table.sh`, `engine-illegal-transition.sh`,
   `journal-replay.sh` each PASS twice: system python3 (PyYAML 6.0.3) and a clean venv python3
   with **no** PyYAML (the engine's stdlib fallback parser). Full 59-scenario lane under the
   default parser = the `phase-governance` phase inside run-all (green).
4. **Evals** — `bash scripts/run-evals.sh --all` → exit 0 (`no evalsets` + pointer to the smoke
   suite; behavioral evalsets retired in v2 — clean exit = green).
5. **Temp-repo lifecycle + replay** — fresh temp repo, filesystem backend, real engine:
   create-ticket → claim/move to In Progress → guarded verdict close (3 journal lines) →
   `idc_journal_replay.py` → `OK: Journal replay matches current board state.`, exit 0.
6. **Negative divergence** — same repo (git-inited), raw tracker move injected out-of-band →
   `idc_git_janitor.py --json --check-journal-divergence` → exit 1 with
   `{"tier": "RISKY", "dim": "journal", "name": "#2", "detail": "Status mismatch: journal says
   'Todo', board says 'In Progress'"}`.
7. **Release-gate governance red/green** — isolated lane via `IDC_OVERRIDE_GOVERNANCE_LANE_DIR`:
   seeded failing scenario → `idc_release_check.py --governance` exit 1 naming
   `governance/seeded_fail.sh`; removed → exit 0 `governance lane: ALL GREEN`; flag-less run exit 0
   with no governance mention.
8. **Sandbox e2e — codex-driven (operator spend policy: no nested claude).**
   - **(a) install** (`ke-idc-test-repo-install`, reset to `idc-baseline`, github backend): full
     from-scratch lifecycle in one codex run — `/idc:init` provisioned fresh Project #15 (receipt
     verified), `/idc:think` (consideration #12 + Think PR #11 + gate #13), operator admission
     (PR merge + `decision-approved` + guarded `dispose --disposition gate-approved`), `/idc:plan`
     (exactly one Buildable #14), `/idc:build` (red test observed → real green tests → validated
     PASS verdict → guarded engine close → PR #16 merged). **Acceptance: 12 journal lines;
     `idc_journal_replay.py --backend github` → `OK: Journal replay matches current board state.`
     exit 0 on the live board; no journal-dim janitor findings** (janitor exit 1 only from two
     report-only foreign-branch leftovers of the pre-reset era); synthetic Stop payload into
     `idc_stop_fixpoint_gate.py` → exit 0. GraphQL delta +547. Capture:
     `run-u6-400-install-r2.txt` (attempt 1, `run-u6-400-install.txt`, fail-closed on an
     over-strict orchestrator prompt — prompt bug, sandbox untouched).
   - **(b) update** (`ke-idc-test-repo-update`): two-step — resync to prod 3.3.0 from a `main`
     worktree, then candidate 4.0.0 update. **Caught a real release blocker:** `/idc:update` never
     installed `docs/workflow/workflow-machine.yaml` into a repo with a pre-4.0.0 receipt (Phase 1
     classified only receipt-listed files; §B's restore promise unreachable; drift contract
     `ok:true` while blind). Fixed (`1359211`), then **live re-proven** with the sandbox reset to
     the resync state and NO repairs allowed: verify surfaced
     `unrecorded: [docs/workflow/workflow-machine.yaml …]`, §B installed it (cmp exit 0 vs
     template, no prompt), fresh receipt records it, post-run drift `ok:true` + `unrecorded: []`,
     operator configs hash-identical. Captures: `run-u6-400-update.txt`,
     `run-u6-400-update-reproof.txt`.
   - **Hook-fidelity caveat (per playbook):** Claude Code hooks do not fire inside a Codex
     process; hook behavior was asserted by invoking the hook scripts directly with synthetic
     payloads against the runs' real artifacts.
9. **Codex review sweep — 2 rounds (the operator's hard cap for this release).**
   - Round 1 (`run-u6-400-codex-review-r1.txt`): 5 findings, all P2, no Blocker/Major. Fixed now:
     undecodable journal bytes fail closed in all three readers (`f757a0d`, verified with seeded
     0xFF bytes + journal-family governance lane). Filed: #155 (janitor numberless carve-out),
     #156 (sweep rate-limit stop — current fail-soft is deliberate W1 design), #157 (Rule O
     `Stage = X` forms); the unlocked-replay-read finding is the #154 class (commented there).
   - Round 2 (`run-u6-400-codex-review-r2.txt`): 2 P1 + 3 P2. Fixed now (`559b730`): the github
     tracker skill's `block()` again creates the **native** issue-dependencies edge — U5-batch4
     had re-pointed it at the engine's `link --kind blocks`, which records only the marker edge
     the drain's dependency gate never reads (dependency-gate bypass in normal operation; engine-
     side native edge filed as #158); `/idc:init` stamps `code-reviews/.gitignore` (fresh-repo
     `unrecorded` noise, confirmed against the real install-sandbox receipt). Filed: #159
     (close-only recovery journal op), #160 (reclaim attribution); #155 escalated to P1 in-issue
     (still opt-in-only reachability).
10. **CHANGELOG + version lockstep** — dated 4.0.0 section in `CHANGELOG.md`; `plugin.json` AND
    `marketplace.json` both `4.0.0` (`d194bef`); `python3 scripts/idc_release_check.py` → exit 0
    (re-run green on merged `main`).

E2e follow-ups filed from the install run's deviations: #161 (brownfield init: pre-existing
docs/workflow subdir skips `.gitkeep`, stamp fails closed), #162 (plan provenance doc example uses
a basename the checker can't resolve).

## Waivers (settled decisions, per plan)

- Fail-soft journal writes (plan §6) — reconciliation is the detector, ops never fail-closed on a
  journal write error.
- Combined u3+u4 merge.
- W3 descope to opt-in (operator, 2026-07-11) — see the scope decision above.

## Cleanup

- Squash `89117d0` on `main`; #146 closed by the merge commit; #150 open (scoped to #154's
  unlock); issues #154–#162 track the residuals.
- Deleted (local + remote, all fully merged or superseded): `te/phase4-2026-07-06-u1`, `-u2-fix`,
  `-u3`, `-u4`, `te/phase4-closeout-w1`, `te/phase4-closeout-w2`,
  `te-integration/phase4-2026-07-06`; stale `.worktrees/` removed.
- **Kept:** `te/phase4-closeout-w3` @ `7cfae2b` (local + remote) — the #154 starting point.
