# Phase 4 close-out run book — #150 code half + U6 release (2026-07-09)

One teams run completes the entire remainder of the v4 deterministic-core build.
Scope = finish Phase 4 (the only mid-implementation phase): **issue #150's code half**
(which formally `Blocks: #146`) then **issue #146 / U6** (acceptance surface + sandbox
e2e + release to main — merge-on-green to main operator-authorized 2026-07-06).
Phase 5 is explicitly a per-item operator menu ("deliberately not one contract",
blueprint §5) and is **out of scope** — the build is DONE when Phase 4 is on main.

## Team topology

- **Lead/orchestrator:** the launching session — Fable 5, extra-high reasoning.
  Context-lean: telegrams only, owns the merge queue into
  `te-integration/phase4-2026-07-06`, runs the release tail itself.
- **Builders / reviewers / verifiers:** cmux teammates on **Opus 4.8**
  (`model: "opus"`), `mode: bypassPermissions` (acceptEdits teammates stall on
  prompts — standing feedback).
- **External review lens:** codex CLI (`codex review --base …`) — MANDATORY per
  unit; it has found a real bug every round for 10+ consecutive rounds this phase.
- **Worktrees:** lead pre-creates them and verifies `git worktree list` before any
  teammate writes (Agent-tool `isolation: "worktree"` has an open silent-landing
  bug). Never two writers on one file.

## Stage 0 — preflight (lead, serial)

1. No live team-execute run on THIS repo (`ps` + `~/.claude/team-execute-runs/`;
   verified clean at authoring time — the only live codex belongs to ks-worktrees).
2. `te-integration/phase4-2026-07-06` clean, up to date with origin (verified:
   head `8e26745`).
3. Baseline gate green before any work: `bash scripts/lint-references.sh` &&
   `bash tests/smoke/run-all.sh` (no piping — piping masks the exit code).
4. Pre-create worktrees for W1 and W2.

## Stage 1 — #150 code half (W1 ∥ W2 → W3)

### W1 (Opus builder) — journal the sweep + rotation race + adjacent #130
- `scripts/idc_recirc_sweep.py`: the `Stage=Recirculation` stamp is a sanctioned
  code door that bypasses the journal → add `journal_append` (same additive
  pattern the finisher got in PR #149).
- Rotation/append race (round-10 residual P2): `os.replace` rewrite can drop a
  concurrent append — close it with the ledger's existing advisory-lock pattern
  (or re-check-after-replace), red-when-broken governance test either way.
- **Adjacent fix, explicitly authorized:** #130 — re-point
  `idc_recirc_sweep.py::apply_github` at the atomic `create_item()` (root cause
  of the #255/#256 empty-Status class; same file, small, deferred since Phase 0).
- New governance tests auto-discovered; both parsers.

### W2 (Opus builder, critical path) — the engine-contract gap
The one real design item, reserved for the operator by U2's BLOCKED-STOP.
**Design direction (settled by approving this run book):**
- Terminal dispositions become first-class **guarded ops in
  `templates/workflow-machine.yaml`** (a stage-transition/disposition table),
  not prose. Implemented in `scripts/idc_transition.py`, replacing the
  `'Awaiting a non-Done terminal disposition (Phase 4)'` stub.
- **REFINED at launch (2026-07-09), supersedes the earlier draft line:** the board
  has exactly one terminal status (`Done` — `templates/workflow-machine.yaml:53-55`)
  and the existing PR #73 operator contract already closes gate items to Done, so a
  new board Status option is explicitly OUT of scope (board-schema blast radius;
  "match existing standard, don't gold-plate"). The invariant becomes: **`Done` is
  reachable ONLY via guarded terminal ops** — verdict-guarded `close` stays the sole
  door for BUILT work; the new disposition op mints Done only with per-disposition
  deterministic evidence, and every journal line records which door + evidence.
- W1/W2 interface, settled by issue #150's own text: the sweep's stamp gets a
  **direct additive `journal_append`** (W1) — it does NOT wait for a new engine
  stage-transition op; #150's Done-When explicitly allows "engine-routed or direct
  journal_append". Both units must keep the journal REPLAY helper consistent: new
  record kinds (sweep restage, dispositions) must reconstruct to an empty diff.
- Each disposition is evidence-guarded, journaled, both backends:
  - `gate-approved` — requires the backend's real approval artifact (github:
    merged Think PR / `decision-approved` label; filesystem: gate item
    Status→Done — the PR #73 semantics).
  - `retired` (pointer decomposition) — requires the decomposition record.
  - `drained` (recirc-inbox drain) — requires recirc provenance
    (`idc-recirc-source` key).
- `skills/idc-gate-issue` + tracker adapters re-pointed at the new op (the U5
  prose pattern: one-line advisory pointer, engine enforces).
- TDD; every guard mutation-proven red-when-broken; both parsers.

### Review relay (per unit, loop to zero Blocker/Major)
`codex review --base te-integration/phase4-2026-07-06` from the unit worktree
+ one FRESH Opus adversarial reviewer with mutation proof (neuter the guard →
watch the test go red → restore). Fix in-unit, re-review.

### W3 (Opus builder, after W1+W2 merged) — flip the default
- Janitor journal-replay check defaults ON (revert the PR #149 opt-in gate;
  keep `--check-journal-divergence` as a no-op compat flag).
- Restore the "default janitor run includes journal reconciliation" governance
  case; doctor Row 10 drops the explicit flag.
- Close **#150** with receipts. Also close **#131** (already resolved — U5 batch
  `a9ded63` removed the "four dimensions" prose; verified gone 2026-07-09).

### Merge queue (lead, serial)
Squash-merge each unit into te-integration one at a time; post-merge gate
(lint + full run-all) after each before the next merges.

## Stage 2 — U6 acceptance surface (#146) — fan out

- **V1 (Opus verifier):** local gates, items 1–7 of the Goal-3 surface in
  `docs/dev/2026-07-07-phase4-fullauto-plan.md`: lint + seeded
  "Stage: Wibble" red spot-check; full run-all (bun on PATH for phase8);
  governance lane under python3 AND `uv run --with pyyaml`; run-evals clean;
  temp-repo full engine lifecycle → replay empty diff; hand-injected divergence
  → janitor/doctor flags it; `idc_release_check.py --governance` red on seeded
  failure / green clean.
- **V2 ∥ V3 (Opus verifiers):** sandbox e2e via **codex, not nested claude**
  (spend policy 2026-07-06), per CLAUDE.md §"Full GitHub-fidelity e2e": direct
  `codex exec --cd <sandbox> --dangerously-bypass-approvals-and-sandbox` with
  the full orchestrator-prompt rules (PLUGIN_ROOT = this checkout, script-only
  board mutations, session-id exports), capture to
  `/Users/jeremy/dev/sandbox/_idc-observability/`, `ke-snap` pre/post.
  - V2: **install** sandbox — full lifecycle with journaling on: journal lines
    appear, replay diff empty.
  - V3: **update** sandbox — `/idc:update` migrates cleanly: thin-router
    WORKFLOW.md refresh lands, operator-owned data configs preserved, drift
    contract clean.
  - Hook-fidelity caveat goes in the record verbatim (hooks don't fire under
    codex); hook behavior asserted by piping synthetic payloads into the hook
    scripts directly.
- **V4 (after V1–V3):** final codex sweep `codex review --base main` over the
  whole phase-4 diff; Blocker/Major fixed by a builder and re-swept to clean.

## Stage 3 — release (lead, serial; only when Stage 2 is fully green)

1. CHANGELOG.md dated release section + version bump in
   `.claude-plugin/plugin.json` AND `marketplace.json` in lockstep (release =
   bump+CHANGELOG+push, no tags); `python3 scripts/idc_release_check.py` → 0.
2. `git checkout main && git pull --ff-only`, squash-merge te-integration,
   push (authorized 2026-07-06).
3. Write `docs/dev/2026-07-09-phase4-complete.md`: what shipped, receipts
   (exact commands + observed output), waivers (fail-soft journal per blueprint
   §6; combined u3+u4 merge; codex hook-fidelity caveat).
4. Close **#146**; delete remote unit branches; live repos (knowledge-engine,
   mdm) untouched — they pick the release up via `claude plugin update`.

## Stop conditions (halt with evidence + exact input needed)

- Journal replay exposes engine gaps needing non-additive Phase-2 rework
  BEYOND the W2 contract above.
- Sandbox e2e blocked on environment (gh auth, sandbox drift).
- GraphQL budget exhaustion mid-e2e (GitHub paces ~1 drain/hour) — stagger,
  don't burn the window.

## Not in this run

Phase 5 menu items (each needs its own operator decision), and backlog polish
that doesn't block #146: #129 (chronic CI red — pre-existing infra), #132,
#104, #106, #108, #109, #123, #66.
