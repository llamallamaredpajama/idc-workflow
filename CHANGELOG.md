# Changelog

All notable changes for the IDC Workflow plugin are documented in this file.

## 4.1.1 — 2026-07-17

The command-integrity hardening patch closes ten deferred safety and honesty gaps from 4.1.0:

- Report writes now fail honestly, and Doctor closeout has forged-PASS regression coverage for all
  ten rows.
- Full gate reconciliation is requirements-change-only; board lint recognizes both centralized
  proof kinds; reciprocal Think PR/gate markers now go through one validating, idempotent binder.
- Pre-receipt uninstall uses an exact legacy-owned-file list and preserves every matrix, review, and
  intake work product; malformed existing receipts remain a hard failure.
- GitHub project deletion accepts only a null-node readback or GitHub's exact missing-node response;
  release manifests, changelog, and the single README badge are locked together; the git-finish smoke
  path is safe on macOS Bash 3.2 when its optional worktree argument array is empty.

## 4.1.0 — 2026-07-17

The command-integrity + external-intake release (plan:
`docs/dev/2026-07-12-idc-command-integrity-and-external-intake-plan.md`): **a command may not claim
more than it can prove, and it may not run at all if the code behind it is stale.** Where 4.0.0 made
the *board's* write path deterministic, this release does the same for the *command's* own
lifecycle — every `/idc:*` invocation now opens a durable record, and every terminal claim it makes
at closeout is re-derived from artifacts on disk or a live tracker read rather than believed.
Minor version because the changes are additive: refusals, one new entry point (`/idc:intake`), a
read-only next-action oracle, and **one additive scaffold migration** — `docs/workflow/intakes/`
(with its receipt-listed `.gitkeep`) joins the governed tree, and `/idc:update` offers it to
pre-4.1 repos as an `unrecorded` install (nothing else moves, and operator content is never
touched). **One manual step after upgrading: run `/reload-plugins` once** (see the upgrade note
below).

- **Stale commands are refused at the door (#106).** A `UserPromptExpansion` hook
  (`scripts/hooks/idc_command_entry_gate.py`, backed by `scripts/idc_plugin_freshness.py`) compares
  the *running* plugin's manifest version against the version recorded in the governed repo's
  install receipt, and blocks the command before it ever expands. This closes the failure mode where
  Claude Code's version-keyed cache keeps an old command body alive in a live session after an
  update — the operator sees a governed refusal instead of a silently outdated playbook. The refusal
  names the real recovery, **`/reload-plugins`**, and states plainly that **`/clear` does not reload
  plugin commands or hooks** (the wrong reflex, and the one that made this class hard to spot).
  Staleness blocks *every* command, recovery commands included, so a stale runtime can't diagnose
  itself with stale code. An unreadable or malformed receipt fail-closes the six **workflow**
  commands (`think|intake|plan|build|recirculate|autorun`) — never a pass — while the
  recovery/diagnostic commands (`doctor|update|uninstall|janitor`) and `init` may still expand on
  an invalid or unknown receipt so the operator can diagnose or migrate the repo (they too are
  blocked the moment the runtime is positively stale). Install receipts gain `receipt_version: 2`,
  which requires an exact `X.Y.Z` `plugin_version`; `receipt_version: 1` receipts predate the
  field and are tolerated, and any other value is invalid — refusing workflow commands and leaving
  only the diagnose/migrate path open.
- **The command closeout contract — claims are re-derived, never believed.** Every `/idc:*` opens a
  lifecycle record (`scripts/idc_command_contract.py`, `start`/`finish`/`status`), and a second
  `Stop` handler (`scripts/hooks/idc_command_closeout_gate.py`, after 4.0.0's fixpoint gate) refuses
  to let a session end on an unresolved or unproven one. The governing rule is a **claim table**
  (`_CLAIM_TABLE`): a command×status pair is only claimable if the validator can independently
  re-derive it — Autorun's drain status is read back from the persisted `.idc-drain-verdict.json`,
  Plan re-validates its matrix and re-runs schema/provenance against live child bodies, Build and
  Think re-read the real merged state of their PR through `gh`, and Intake re-checks its manifest
  review. **A status that cannot be re-derived is not claimable at all** — the fail-closed direction,
  so a caller can never talk its way to `complete` with a fabricated receipt string. Obligations
  stamped at `start` (Build's requested issues, Plan's admitted set, Think's manifest units) are
  **monotonic**: a restart may only add to them, and a restart pointed at a *different* intake
  manifest is refused outright at the real entry hook rather than silently replacing the first
  manifest's obligations — the path by which queued work used to disappear. `/idc:doctor` closes out
  under the same rule: its rows stay 1–10, but every row claiming **PASS** is independently re-run
  before the claim stands (FAIL and SKIP rows are never contested).
- **Raw board mutations are denied while a command is active.** A `PreToolUse` hook on `Bash`
  (`scripts/hooks/idc_interlock_gate.py`) classifies each command and **hard-denies** raw tracker
  writes — improvised `gh project`/`gh issue` mutations and GraphQL mutations — whenever the session
  owns an active IDC command, routing the operator to the sanctioned engine door instead. Outside an
  active command it warns rather than blocks. Crucially it also follows **script indirection**: a
  `bash some-script.sh` that mutates the board is inspected and denied *before the script runs*, with
  bounded depth and read size and a cycle guard, and files that resolve under the plugin's own
  `scripts/` are sanctioned rather than re-scanned. The posture on anything it cannot statically
  resolve — a dynamically built endpoint, an opaque `-c` payload, `BASH_ENV`-style startup
  smuggling, a privilege wrapper — is **fail-closed**: deny and say why. Provably read-only `gh` and
  GraphQL reads still pass, so Doctor and Update keep working. There are **no command-name
  exceptions**; Init's and Uninstall's own lifecycle writes go through validating tracker-adapter
  helpers like everyone else. Sensitive files (`.env`, `.envrc`, keys, credentials) are refused
  without being opened.
- **`/idc:intake` — a large external plan, compiled exactly once (new, 11th command).** A foreign
  artifact (a vendor plan, a consultant's document) is no longer something Build is expected to
  infer. `/idc:intake` compiles it into a durable manifest at
  `docs/workflow/intakes/<YYYY-MM-DD>-<slug>.json` (`scripts/idc_intake_manifest.py`:
  `extract`/`validate`/`link`/`status`), where every unit it found is enumerated **exactly once**,
  classified, and routed to a real IDC lane — and the artifact itself is never executed. The manifest
  is bound to its source by `sha256`, so an edited source is refused rather than silently
  re-interpreted, and `build`/`autorun` are **forbidden** routes: foreign scope must enter through
  Think or Recirculation like any other work. Reviews are **content-bound** — the approval file is
  named for the digest of the manifest content it approved
  (`<intake_id>.review.<manifest_content_sha256>.json`), so quietly dropping a unit and reusing the
  old PASS doesn't validate. Credential-shaped assignments are redacted out of extracted text and
  review notes, so compiling someone's plan can't commit their secrets into your repo.
- **A next-action oracle.** `scripts/idc_next_action.py` (`--repo`, `--json`, read-only) derives the
  genuinely correct next command from **durable** tracker and intake state, and the commands and
  runtime adapters hand off through it instead of guessing. It distinguishes the three answers that
  matter and never conflates them: a real action, a legitimate wait (`waiting-human-gate`), and
  `fixpoint` (nothing left). Reads fail closed — an unreadable or malformed tracker is exit 2
  (`invalid-tracker`), a throttled GitHub read is exit 3 (`rate-limited`), and neither is ever
  flattened into a cheerful "nothing to do".
- **Honest gate repair and reconciliation.** A corrupt or stranded human gate can now be fixed
  without inventing history. `scripts/idc_gate_proof.py` reports exactly one of three kinds —
  **`guarded-dispose`** (the gate genuinely went through the guarded terminal door),
  **`verified-reconciliation`** (it was repaired, and the repair says so), or **`unproven`** — and
  only the first two count as proven. `scripts/idc_gate_repair.py` is **dry-run by default**:
  `--apply` is the only door to a write, and it re-reads every precondition immediately before
  acting. Repairs journal under the honest `op=gate-reconciliation` record (the gate's evidence,
  plus a separate no-transition observation record for an already-unblocked pointer) and **never
  back-date a synthetic `dispose`** — so the journal keeps telling the truth about how a gate
  reached Done. (`full-repair` and `finish-pointer` are the tool's two *modes*, not journal ops; a
  pointer the tool completes is journaled by the engine's own real `unblock`.) `--finish-pointer`
  is the one sanctioned way to complete a pointer whose gate has cleared: it requires the proven
  gate to be the pointer's **sole remaining blocker**, and every unblock site in the stage
  playbooks and the PR finisher now routes through that door instead of a raw engine `unblock`
  that could drop a single edge and release work that
  was still legitimately blocked.
- **Upgrade note + intake scaffold ownership.** After updating to 4.1.0, **run `/reload-plugins`
  once**: the freshness gate ships *inside* this version, so a session already running the old code
  cannot be handed the hook retroactively — that one command is the bootstrap, and from then on the
  gate carries itself (`docs/installing.md`). `/idc:init` now creates `docs/workflow/intakes/`, and
  `/idc:update` gap-fills it into older governed repos **per file** via the `unrecorded` category
  (`idc_receipt_check.py verify --json`), without touching intake contents. The install receipt lists
  only the directory's `.gitkeep` — compiled manifests are operator **work product** and are never
  stamped as scaffold, which is exactly what stops `/idc:uninstall` from deleting a plan you paid to
  have compiled. Every command inventory (README, architecture, `AGENTS.md`, `llms.txt`, the
  templates) now reads **11 commands**: `think · intake · plan · build · recirculate · autorun ·
  janitor · init · doctor · update · uninstall`.

## 4.0.0 — 2026-07-11

The v4 deterministic-core release (plan: `docs/dev/2026-07-03-deterministic-core-refactor-plan.md`,
phases 0–4): **code owns state transitions, the LLM owns judgment.** Major version because the
write paths changed shape — every board state change now goes through one legality-checked engine
door, terminal states are reachable only through guarded terminal operations, and every engine op
leaves an auditable journal line. Operators with custom tooling that mutated the board directly
should switch to the engine CLI (`scripts/idc_transition.py`); `/idc:update` migrates governed
repos' scaffolds (including files new to this version — see the `unrecorded` mechanism below).

- **Single write door + machine-as-data (#133, #134, #137, #143).** The transition engine
  `idc_transition.py` is the only sanctioned door for create/move/close/link/dispose, on both
  backends, with transition legality checked against a machine table that now lives as data in
  `docs/workflow/workflow-machine.yaml` (scaffolded into governed repos; WORKFLOW.md's board-schema
  section routes to it). New lint Rule O cross-checks shipped files' states/statuses/engine-op
  references against the machine yaml; a raw-board-mutation lint catches improvised `gh project`
  writes in shipped playbooks.
- **Guarded terminal operations (#135, #136, #150-W2).** `close` requires a review-verdict receipt
  and honors `merge_conditions`; the build finisher gates on routed findings. Non-verdict terminal
  dispositions — `drained`, `retired`, `gate-approved` — each pass their own guard (provenance
  marker, decomposition link, approval artifact), with journal corroboration, gate binding, a
  TOCTOU re-proof, and stranded-gate recovery. **Done is reachable only through a guarded terminal
  op.** PreToolUse interlocks block raw terminal actions at the tool boundary.
- **Transition journal + reconciliation (#141, #142, #150-W1).** Every engine op appends a
  who/what/when/guard-evidence NDJSON line to `docs/workflow/transition-journal.ndjson` —
  append-only (journal write failures are fail-soft + loud; reconciliation is the detector), with
  atomic closed-segment rotation and a sidecar append lock. The recirculation sweep's restage +
  intake are journaled and atomic (fixes the #130 root-cause class). `idc_journal_replay.py`
  rebuilds expected board end-state from the journal and diffs the actual board;
  janitor + doctor reconcile board↔journal↔git. The replay divergence check ships **opt-in**
  (`idc_git_janitor.py --check-journal-divergence`); the default flip is parked on a
  transactional journal/board design (#154 — the 24-round hardening is preserved on
  `te/phase4-closeout-w3`).
- **Hook spine (phase 3: #138, #139, #140 + stages D/E).** Obligations ledger (script-written,
  session-scoped, advisory-locked); Stop fixpoint gate — an autorun/build orchestrator cannot stop
  while the board says work remains (ledger alone never blocks a clean board), with a persisted
  drain verdict making the github stop path 0-GraphQL; recirculator closeout-or-checkpoint on
  SubagentStop + kill-safe main-session reconciliation; PostToolUse board-coherence self-repair
  (commit↔claim, issue↔board-add); wave-close acceptance gate (an acceptance error/gap is
  non-terminal, never a masqueraded `complete`); TeammateIdle synthesis reconstructs a phantom-idle
  implementer's real state from git evidence.
- **Truthful signals (phase 0: #124–#128).** Three-conjunct drain fixpoint with a distinct
  `drain: recirc-pending` (exit 4); atomic Stage+Status item creation on both backends; board-lint
  flags (+ `--fix`) empty-Status considerations; janitor RESUME-RECIRC finding for truncated
  recirculation drains; the glob-driven red-when-broken governance test lane (59 scenarios,
  parser-parity tested under PyYAML and the stdlib fallback).
- **Release gate (#144).** `idc_release_check.py --governance` runs the governance lane as a
  release gate (self-check guarded, isolated-lane override for tests); version-lockstep checking
  unchanged.
- **Prose demotion (#145).** Imperative control-flow prose across `commands/`, `agents/`,
  `skills/` demoted to one-line advisory pointers wherever a deterministic gate now enforces the
  behavior — judgment knowledge (severity meanings, disposition guidance, review rubrics) stays.
  Every shipped file examined; 4 ablation-gated batches, log in `docs/dev/phase4-demotion-log.md`.
- **Release-acceptance fixes (U6, this release's own gate).** The codex-driven sandbox e2e +
  two-round review sweep caught and fixed before shipping: `/idc:update` now surfaces + installs
  files new to the installed plugin version (`idc_receipt_check.py verify` `unrecorded` bucket —
  without it, updated repos silently missed `workflow-machine.yaml` and the drift contract read
  clean); the github tracker skill's `block()` recipe again creates the **native**
  issue-dependencies edge (the engine-link substitution left children invisible to the drain's
  dependency gate — engine-side native edge is #158); undecodable journal bytes now fail closed
  (classified error, never an unclassified crash); `/idc:init` stamps
  `docs/workflow/code-reviews/.gitignore`. Deferred with issues: #155 (janitor numberless-create
  carve-out, opt-in surface), #156 (sweep rate-limit stop), #157 (Rule O `Stage = X` forms),
  #159 (close-only recovery journal op), #160 (reclaim attribution), #161 (brownfield init
  stamp), #162 (plan provenance doc example).

## 3.3.0 — 2026-07-02

The 2026-07 effectiveness-audit fix package (umbrella #110): the pipeline now cleans up after
itself deterministically, closes issues atomically, stops re-reading the whole board per write,
and ships a test suite that proves all of it against real git.

- **`/idc:janitor` (#97)** — a deterministic board↔git reconciler, report-first with four tiers
  (SAFE-FIX / REPORT-ONLY / RISKY / COHERENT); `--apply-safe` applies only the SAFE-FIX tier
  (IDC-attributable **and** merged **and** clean). Triple-wired: the command, an autorun preflight,
  and doctor Row 10 — and reusable as a deterministic e2e post-condition gate
  (`docs/dev/e2e-postcondition-gate.sh`). Hardened by adversarial review: tip-SHA guard before any
  branch delete (name-reuse never force-deleted, local **or** server-side re-creation), `build[-/]`
  attribution anchor (a foreign `buildbot` can't be IDC-attributed), closed-as-not-planned never
  stamped Done, fail-closed exit 2 on any degraded/capped/unqueryable read, and remote-branch truth
  from one read-only `git ls-remote` (stale tracking refs can't produce phantom findings).
- **Deterministic finish tail (#107)** — `idc_git_finish.py`: the build finisher's close-out is now
  verified end-state (tracker close both halves + `git ls-remote` proves the remote branch is gone),
  backend-blind via the tracker adapter. Fixes the worktree-collision race and omitted
  `--delete-branch` (audit RC1+RC2).
- **Atomic issue close (#96)** — `idc_gh_close.py`: Status→Done + close + live read-back verify as
  one operation; a Done-but-open item is now exit-2, never silent (RC3).
- **Item-id cache (#98)** — `idc_gh_board.py --emit-idmap` reads the board once per wave; `itemid()`
  consumes the cache via `IDC_ITEMID_CACHE`, and the orchestrator hands the cache path to every
  durable worker **in the brief** (the only thing that crosses the session boundary). Kills the
  quadratic per-write board re-read (RC4a): measured 0 GraphQL calls per status-write with the cache
  on vs a full board read each without.
- **Rate-limit pause/resume (#99)** — `_gh` preflight + 403/secondary-limit detection emits a
  machine-readable `rate-limited until <reset>` verdict (exit 3, never a false positive on plain
  permission 403s); the autorun drain consumes it as pause-and-resume — a rate-limited wave is
  surfaced and resumable, never silently dropped (RC4b).
- **Closing keywords + deleteBranchOnMerge offer (#100)** — the PR-authoring agents (Claude + Pi
  runtime, in parity) write closing keywords as plain unbackticked text so GitHub actually
  auto-closes; new lint Rule M (case-insensitive) catches backticked closing-keyword instructions in
  shipped files; `/idc:init` + `/idc:update` now *offer* enabling `deleteBranchOnMerge`
  (consent-gated, headless default = declined, never silent).
- **Provenance gate (#101) + marker helper (#102)** — `idc_provenance_check.py` post-condition gate
  and `idc_emit_marker.py` deterministic marker emission (fail-closed: a field value that would
  break the HTML-comment sentinel is rejected, round-trip-verified against the sweep's own parser).
- **Model-escalation ladder (#105)** — `model_routing` tiers annotated in the config template and
  encoded across all three runtime adapters (Claude · Codex · Pi) in parity; new commented
  `janitor: auto-safe` knob documented (defaults off, report-only).
- **e2e rebuild (#103)** — `run-all.sh` now runs 67 phases, all green: every fix-package test wired,
  a real-git lifecycle phase (bare-origin remote, real merges, janitor certifies the end-state) and
  a multi-wave accumulation phase (no cross-wave debris or stale-id leaks), plus an honest
  assert-class rollup (`35 behavior · 22 mixed · 10 doc`, fail-closed on untagged phases). Every new
  test proven red-when-broken.

P2 items deliberately left open with status comments: #104 (github merge lease), #106 (force-update
gate), #108 (derive recirc_count), #109 (sweep/drain read batching).

Pi becomes a first-class, smooth runtime: a real-LLM end-to-end drain now goes green (Think→Plan→
Build, build-finish self-merging on PASS), one `PI_IDC_MODEL` var boots every role (no 7-per-role-pin
ceremony), and `/idc:init --pi` wires the adapter. The release also fixes a real drain blocker —
build-review could not persist its verdict — and tightens two role-contract fidelity gaps the
real-LLM e2e surfaced.

- **fix(pi): build-review can now persist its verdict (the drain blocker).** An earlier change added
  the `write` tool to `build-reviewer.md` + the `BUILD_REVIEW_ALLOWED` guard lane but missed the
  launcher's `role_tools()`, which still stripped it — so every verdict write died at "Tool write
  not found" and build-finish's MG-B gate blocked every drain. `role_tools()` now grants build-review
  `write` (the guard still restricts writes to `docs/workflow/code-reviews/**` — tool available +
  path-guarded, defense-in-depth).
- **feat(pi): `PI_IDC_MODEL` umbrella.** One provider-qualified var (e.g. `google/gemini-2.5-pro`)
  fills every role. Precedence: per-role `PI_IDC_<ROLE>_MODEL` > umbrella > stock default. The stock
  defaults span three providers (Anthropic/DeepSeek/OpenAI) no single install has keys for, so a
  fresh `idc-pi run` previously failed closed on every role unless an operator set 7 per-role vars.
- **feat(pi): `/idc:init --pi`.** Mirrors `--codex` (Phase 6b → `install-pi.sh`); the adapter skill
  ships with the plugin.
- **fix(pi): role-contract fidelity.** `build-implementer.md` now directs implementing the goal
  contract's EXACT artifact (no language/framework substitution — build-impl was freelancing Python
  vs the contract's POSIX shell, which review FAIL-BLOCKs); `build-reviewer.md` now forbids
  confabulated verification (record only commands actually run — a fabricated log could yield a
  false PASS that lands a broken build through the merge gate).
- **Docs:** the umbrella + a "Pi runtime (optional)" section in `docs/installing.md`; honest status
  in `README.md`/`docs/architecture.md` (Pi runs end-to-end; still "Experimental" — parallel build
  pool + autorun drain pending, #66 L1/L4).
- **New red-when-broken smokes:** `phase8-pi-review-write-tool.sh` (role_tools grants build-review
  write), `phase8-pi-model-umbrella.sh` (umbrella + per-role precedence), plus `--pi` and fidelity
  assertions in `phase1-init-doctor.sh` / `phase8-pi-prompt-alignment.sh`.

**Verified:** `tests/smoke/run-all.sh` ALL GREEN; `scripts/lint-references.sh` clean; real-LLM Pi e2e
green end-to-end — the build-review write fix validated in fresh drains, and the umbrella dogfood
drained 7/7 with every role booted on one `PI_IDC_MODEL` var.

## 3.1.4 — 2026-06-28

Fix: the GitHub backend read the project board with `gh project item-list` **without `--limit`**, so
it silently truncated to gh's 30-item default. On a board with more than 30 items whose front had
filled with `Done` work, `/idc:autorun` saw a non-representative slice and falsely reported the pipe
drained ("Nothing pending") while dozens of `Stage = Buildable, Status = Todo` issues sat past item
30. A latent pagination bug exposed by board growth, not a regression in any one release. This
release makes **every** GitHub board read paginate the whole board, and hardens the read / drain /
write paths against the silent-failure class the bug belonged to.

- **True cursor pagination for every GitHub board read.** A shared `idc_gh_board.py` reader pages
  `items(first:100, after:cursor)` until `hasNextPage` is false and returns the complete board
  (ASCII-escaped, control-char-safe). Every reader — the tracker-github `query`/`itemid` ops, the
  recirculation sweep's three reads, `/idc:doctor` Row 9, and `/idc:uninstall`'s in-flight count —
  routes through it. No `--limit N` ceiling remains anywhere (a fixed limit would just move the
  truncation threshold).
- **Deterministic GitHub drain predicate.** `idc_autorun_drain.py --backend github` computes
  build-lane eligibility from the fully-paged board using the **same** predicate as the filesystem
  backend (`Status = Todo`, empty/`Buildable` Stage, not `[operator-action]`, all `blocked_by` Done).
  Autorun no longer improvises a board query in prose; `agents/idc-autorun.md` + `commands/autorun.md`
  mandate the helper.
- **Fail-closed wherever a partial / blind read could masquerade as "done".** The paginator raises on
  a GraphQL `errors` payload, a missing `node.items`/`nodes`/`pageInfo`, a non-bool/missing
  `hasNextPage`, `hasNextPage=true` with no `endCursor`, and `MAX_PAGES` exhaustion. The drain verdict
  emits `drain: unknown` (exit 2) — never a hollow `drain: complete` — when no work is eligible but any
  candidate's `blocked_by` could not be verified. `/idc:doctor` Row 9 emits an explicit `SKIP` on an
  unreadable board, and `/idc:uninstall` reports the in-flight count as `unknown` (requiring explicit
  confirmation) rather than a misleading `0`.
- **GitHub `setField` `--project-id` bug fixed (separate, pre-existing).** The tracker-github
  `setField` op — and everything that wraps it (claim / move / block / close / retire) — passed the
  integer `project_number` to `gh project item-edit --project-id`, which current `gh` rejects (it
  requires the project **node id**). The op now resolves and passes the `PVT_…` node id, mirroring the
  recirculation sweep. (Agents had been silently working around this at runtime; the skill is now
  correct as written.)
- **The recirculation sweep reports success honestly.** Filing a Recirculation ticket counts/logs as
  "filed" only on actual `gh` success; a board-read failure surfaces a degraded state instead of
  silently risking a duplicate; a failed Wave clear is surfaced rather than logged as cleared.
- Regression coverage: a hermetic smoke fixture (a 135-item, multi-page board with the eligible
  frontier past item 30) proves the read returns the whole board and goes red if pagination is
  removed; the GitHub drain, each fail-closed paginator branch, and the recirculation success-gating
  carry red-when-broken tests. Verified end-to-end against a seeded 48-item GitHub sandbox board (42
  eligible seen vs ≤25 from a truncated read) and a live `setField` round-trip via the node id.

## 3.1.3 — 2026-06-28

Patch: `/idc:update` now *applies* the `Recirculation` Stage-option fix itself, instead of only
reporting it. 3.1.2 made update detect the missing option and point the operator at `/idc:init`; but
the command a user naturally runs after a plugin update is `/idc:update`, so routing the fix through a
separate command recreated the very friction it was meant to remove.

- **`/idc:update` appends the missing `Recirculation` option in place (non-destructively).** Its Phase
  3 board reconcile now performs exactly one board mutation — appending a missing *required* `Stage`
  option via the shared `idc_stage_options.py` helper (re-sends existing options by node id so item
  values survive; appends only the new option; never replaces the option set). It is idempotent
  (`stage-recirc-already-present` on a re-run) and fail-closed. Every *other* kind of board drift
  stays strictly report-only, and update never performs a destructive or structural board mutation
  and never touches the data-bearing configs.
- **`/idc:doctor` 9c** now points the operator at `/idc:update` (the natural post-upgrade command) as
  the primary remediation; doctor itself stays strictly read-only.
- Verified by a full update-sandbox E2E: on a pre-3.1.0 3-option board, `/idc:update` appended
  `Recirculation` and the existing items' Stage values were preserved on the live board.

## 3.1.2 — 2026-06-28

Patch: makes the 3.1.0 `Recirculation` Stage actually provisionable on a real GitHub board. 3.1.0
added the `Recirculation` Stage value across the schema, both tracker skills, `WORKFLOW.md`, doctor
9c, and `/idc:recirculate` — but never updated the two surfaces that **provision or validate** the
board's `Stage` options, so on a real board `/idc:recirculate` had no stage to file into (fresh
installs *and* upgrades).

- **`/idc:init` now provisions all four `Stage` options and reconciles an existing board.** Phase 4
  creates the `Stage` field with `Consideration, Planning, Buildable, Recirculation` on a fresh board,
  and on a board that predates 3.1.0 (a 3-option `Stage`) **appends `Recirculation` non-destructively**
  — it re-sends every existing option *with its node id* (so GitHub preserves them and item values
  survive) and appends only the new option, never replacing the option set (a replace re-IDs every
  option and wipes item values). Previously init created only the 3 options and skipped an existing
  `Stage` field entirely, so doctor 9c's "run `/idc:init`" remediation was a dead loop.
- **New `scripts/idc_stage_options.py` helper** assembles that exact non-destructive
  `updateProjectV2Field` mutation (idempotent: a no-op when the option already exists; fail-closed on
  bad input). The GitHub-API mechanism it relies on (append by preserving existing option node ids)
  is verified by a hermetic regression test plus a full update-sandbox E2E.
- **`/idc:update` now reports the gap instead of being blind to it.** Its Phase 3 board-drift contract
  includes the 4th option and reports `stage-recirc-missing` for a present-but-stale `Stage` field,
  pointing the operator at `/idc:init` for the non-destructive fix. Update remains report-only — it
  never mutates the board.
- **Regression coverage.** `tests/smoke/phase1-stage-recirc-append.sh` (red-when-broken) pins the
  non-destructive append, and `phase7-command-prose-invariants.sh` locks the init/update provisioning
  invariants so this can't silently regress.

## 3.1.1 — 2026-06-28

Patch: fixes a fatal plugin-load error introduced in 3.1.0.

- **Removed the redundant `hooks` key from `plugin.json`.** 3.1.0 shipped the new SessionEnd
  recirculation-sweep hook at the standard `hooks/hooks.json` path *and* also declared
  `"hooks": "./hooks/hooks.json"` in the manifest. Claude Code auto-discovers the standard-path
  file, so the manifest reference resolved to an already-loaded file and the loader aborted with
  `Duplicate hooks file detected … manifest.hooks should only reference additional hook files`,
  preventing the hook from loading. The `manifest.hooks` field is only for *additional* hook files
  at non-standard paths; since `hooks/` holds only the standard `hooks.json`, the reference was
  pure redundancy. Removing it restores a clean load — the SessionEnd hook still registers via
  auto-discovery (its behavior is unchanged).
- **Regression guard in `scripts/lint-references.sh`.** Lint now fails if `plugin.json`'s `hooks`
  field points at the standard `hooks/hooks.json` path, so this duplicate can't recur.

## 3.1.0 — 2026-06-28

Scope discovered mid-build now has a sanctioned home: a new **`Recirculation`** intake instead of
leaking onto the board as a claimable `Buildable` issue. Discovered scope must recirculate — be
triaged for a PRD/TRD change, planned, and sequenced — before it can become buildable, and every
other door is closed so the leak can't recur.

- **New `Recirculation` Stage (the non-Buildable inbox).** A 4th Stage across the schema surface
  (`idc_tracker_fs`, `idc_schema_check` with a dedicated `check_recirculation` body shape, both
  tracker skills, `tracker-config`, `WORKFLOW.md`). The autorun drain flips from a denylist to a
  **Buildable-only allowlist** — claim only `Stage=Buildable` (the empty→Buildable legacy default
  preserved), so any non-Buildable stage is build-excluded by construction (closes the empty-Stage
  footgun).
- **Deterministic provenance.** Plan writes the same pillar `id` into the matrix YAML and stamps it
  onto the issue (`<!-- idc-provenance: {matrix,pillar} -->`, github-only), so a planned Buildable is
  provably linked to its matrix pillar — the downstream sweep matches exactly, never fuzzily.
- **Scope-origination guardrails.** `idc-build` / `idc-implementer` / `idc-finisher` (+ the Pi
  mirror) may no longer originate tracker scope (no raw `gh issue create`, no self-set
  `Stage=Buildable`/`Wave`); in-boundary work is fixed in-loop, everything else files a
  `Stage=Recirculation` ticket. The finisher's `blocks_goal` deferral now mints a Recirculation
  ticket; the implementer emits a structured `idc-discovery` marker for recommend-but-not-doing fixes.
- **Deterministic detective (`scripts/idc_recirc_sweep.py`) + SessionEnd hook.** Re-stages rogue
  Buildables (bypassed Plan → no provenance) and captures untickered discovery/deferral markers.
  Regime-gated so a legacy/unstamped board is never destructively re-staged; no-matrix and filesystem
  skips mirror board-lint. A project-scoped `SessionEnd` hook runs it `--auto-correct` (fail-soft);
  `/idc:doctor` Row 9b runs it `--report` (read-only, defense-in-depth) and Row 9c offers the
  add-one-option `Stage` migration (detect + offer, never mutates).
- **`/idc:recirculate` inbox-drain.** A board-scan mode drains every `Stage=Recirculation` ticket
  through the existing recirculator decision flow: PRD/TRD-worthy → the one gate (ticket rides
  Blocked); not-gate-worthy → an admitted consideration + the ticket retired (provenance preserved).
- **Autorun starts at the top of the pipeline** — recirculate → plan → drain, pausing only at human
  gates. Its Recirculation intake first runs the rogue-sweep `--auto-correct` itself (the `SessionEnd`
  hook is cancelled in a headless `-p`/`/loop` session, so autorun can't rely on it) before draining.
- **Plan batch dedup/deconflict (quality layer).** One Plan run scoops all admitted considerations
  and runs a read-only pre-pass comparing each against every other pending consideration, the open
  Buildable/in-flight lane, and the codebase — yielding one de-duplicated, deconflicted plan (reusing
  the matrix clash fan-out, not a new mechanism).

Sandbox e2e against the github autorun board caught three real defects (all fixed + regression-tested):
the sweep's `project_number` parse ate its inline comment (silently disabling the github sweep); that
failure reported a hollow "clean" all-clear (now a degraded SKIP); and the `SessionEnd` hook is
cancelled in a headless `-p` run (now backstopped by the autorun preflight sweep).

Gates: `lint-references.sh` CLEAN · `tests/smoke/run-all.sh` ALL GREEN (45 tests; 4 new/extended) · every new guard shown red-when-broken · autorun-sandbox e2e validated (board unmutated).

## 3.0.5 — 2026-06-26

An advisory build-lane hygiene check for `/idc:doctor` (#91), hardened by three
follow-ups (#92–#94) that closed false-clean / false-flag holes found during e2e.

- **New advisory Row 9 in `/idc:doctor` (`scripts/idc_board_lint.py`).** Re-runs the
  existing Plan-time schema check over the build-eligible lane (`Status=Todo`,
  `Stage=Buildable`) and flags prose-only dependencies — a dependency stated in prose
  with no native `blocked-by` link. Closes the gap where an issue that bypassed Plan
  could sit build-eligible while malformed, and Autorun would claim it cold (live
  repro: #482). The helper is pure stdlib and reuses `idc_schema_check` (no schema
  duplication); github-only by construction; strictly read-only and **advisory — it
  never FAILs doctor** (exit 0 on valid input, SKIP on unparseable, SKIP on the
  filesystem backend).
- **Shell-agnostic Row 9 loop (#92).** The build-eligible list was iterated with an
  unquoted `for n in $nums`; under zsh (doctor's real Bash-tool shell) a newline blob
  is not word-split, so the loop ran once over the whole blob and Row 9 falsely
  reported `board-lint: clean (0 scanned)`. Now piped through `while IFS= read -r n`,
  which iterates per line in both bash and zsh.
- **Tri-state `blocked_by` so a failed dep lookup never false-flags (#93).** A failed
  `gh api .../dependencies/blocked_by` call coerced to `[]`, indistinguishable from a
  confirmed no-link, so an issue stating a dep in prose got falsely flagged.
  `blocked_by` is now tri-state: `null` = UNKNOWN (lookup failed → never flag),
  `[]` = confirmed none (still flags), `[n,…]` = linked.
- **Surface degraded dependency-lookup state — no silent all-clear (#94).** A
  board-wide dependencies-API outage made every issue UNKNOWN → nothing flagged → a
  silent "clean." The summary now counts indeterminate issues and appends
  `; N dependency lookup(s) indeterminate`, which Row 9 maps to PASS-with-warn
  (never FAIL).

Each fix added a red-when-broken smoke case (`tests/smoke/phase1-doctor-board-lint.sh`).

Gates: `lint-references.sh` CLEAN · `tests/smoke/run-all.sh` ALL GREEN · every new guard shown red-when-broken.

## 3.0.4 — 2026-06-21

Two follow-ups logged on PR #72 (deliberately out of scope at merge), resolved together.

- **Fail-closed on a missing `issues` key (both state-block readers).** `scripts/idc_acceptance_check.py`
  and `scripts/idc_autorun_drain.py` both read the embedded `idc-tracker-state` JSON block, and both
  defaulted a **missing** `issues` key to an empty board (`state.get("issues", [])`) — so a
  github-materialization bug (or a hand-edit) that dropped the key would silently read as `acceptance: ok`
  / `drain: complete`. Both readers now **fail closed (exit 2)** when the `issues` key is absent, while an
  explicitly-present `issues: []` still reads as a legitimate empty board. The two readers are kept in
  lockstep (identical guard) by new red-when-broken parity cases in `phase4-acceptance.sh` and
  `phase6-autorun.sh`; `idc_autorun_drain.py`'s loader also gained the sibling's `isinstance(state, dict)`
  guard so the require-present check is total.
- **Filesystem-backend portability of the human gates.** The requirements gate (Think-PR merge) and the
  strategic `operator-decision` gate (`decision-approved` label / decision-PR merge) detect approval via
  github-only signals; on the `filesystem` backend (a `TRACKER.md` repo with no PRs and no labels) those
  signals can't exist, so a gate's dependents would stay `Blocked` forever. `idc-gate-issue` now documents
  the **backend-portable approval signal** — on filesystem the operator approves by moving the gate
  issue's `Status` to `Done` (the existing `close`/`move` op; no seventh op), fail-closed the same way —
  via a new *Approval signal by backend* section, a pointer note in `WORKFLOW.md §2`, and a
  red-when-broken prose invariant in `phase6-autorun.sh`. No GitHub-backend behavior changes.

Gates: `lint-references.sh` CLEAN · `tests/smoke/run-all.sh` ALL GREEN · every new guard shown red-when-broken.

## 3.0.3 — 2026-06-21

Seven prioritized fixes from the first live-repo `/idc:autorun` audit
(`docs/reviews/2026-06-21-autorun-session-audit.md`), which surfaced two structural failures: autorun
**improvised four human gates** its playbook never sanctioned, and a wave **shipped inert work** (issue
#449 merged "Done" carrying a Spanner DDL with no provisioned instance, the gap filed as a passive
follow-up). The fixes make the plugin structurally incapable of both. **Hybrid posture (binding):**
deterministic only where the signal is mechanical (the new acceptance check + the structured-deferral
schema); behavioral where it's a judgment call (the no-ask invariant, the outcome-test requirement, the
strategic gate). **No static-allowlist reject was added to `idc_schema_check.py`** — a documented,
intentional divergence from the audit's literal "enforce at schema-check" wording.

- **P0 — No-ask invariant (autorun + build).** The sanctioned stops are now explicitly *exhaustive* in
  `agents/idc-autorun.md` and `agents/idc-build.md`: never ask the operator how-autonomous, never
  re-confirm a chosen scope, never convert a deterministic `drain: continue` into a question, never call
  `AskUserQuestion`. "Check in" means report progress and keep draining. Reinforced in
  `docs/mental-model.md`.
- **P0 — Outcome-level verification surface.** `idc-goal-contract` element 2 now requires at least one
  command exercising the GOAL's observable end-state (run / apply / query / HTTP / e2e), not merely
  static checks; `idc-review-engine` makes an **all-static** verification surface a `major`/FAIL
  (contract-drift / test-genuineness) so an inert deliverable is caught at Build review.
- **P1 — Structured, validated deferrals.** A deferral is now a structured object
  `{kind, what, blocks_goal: bool, suggested_issue}` validated by `idc_review_verdict_check.py` (with an
  explicit boolean check on `blocks_goal` and a non-empty-string check on the other required fields),
  emitted by the implementer/finisher/review-engine closeouts; the finisher ships **fail-closed** until
  each deferral is resolved in-loop or converted into a dependency-linked board item that blocks the
  parent's Done. Any deferral that survives the loop is **serialized onto its issue as a hidden
  `<!-- idc-deferral: {…} -->` comment marker** (reusing the existing `comment` op — no 7th op, no new
  tracker field); that marker is the producer the wave-close acceptance check parses (without it the
  gate would be inert).
- **P1 — Dependency-aware acceptance gate.** New `scripts/idc_acceptance_check.py` reads the deferral
  comment markers and flags any Done issue with an unmet `blocks_goal:true` deferral
  (`acceptance: ok|gap`) — a deferral is "met" only when its `suggested_issue` names a **distinct, Done,
  and non-inert** enabler (transitive, evaluated whole-board), and the gate fails closed on a
  non-boolean `blocks_goal`, an unparseable marker, or a numberless `--wave`. `idc-build.md` Phase 4
  wave-close runs it as a **blocking** gate that auto-files a recirculation per Done-but-inert issue; on
  the github backend the same script runs over a materialized `idc-tracker-state` block (no model
  judgement), and phase-close also runs it unscoped (whole-board) as a backstop.
- **P2 — Broadened recirculation trigger.** A third trigger — impl right *and* plan right but the
  increment is inert/acceptance-gapped — is added to the finisher, implementer, and `/idc:recirculate`.
- **P2 — Strategic decision gate.** A second gate type (`operator-decision`) in `idc-gate-issue` gives a
  non-requirements GO/NO-GO a real board slot (fail-closed: an explicit `decision-approved` label or a
  merged decision-PR; a closed-but-unapproved gate is not a GO), so the orchestrator never improvises
  one. The requirements gate stays the only admission gate; reuses the six tracker ops (no 7th).
  Documented in `WORKFLOW.md §2.1` (append-only).
- **P3 — Phase-close blocks acceptance-class findings.** `idc-build.md` Phase 5 drives acceptance-class
  findings to zero / recirculation (other delta findings stay non-blocking), and the acceptance check
  runs at every wave-close, not only at the phase boundary.

**Post-review hardening (multi-lens adversarial review of this branch).** A `/simplify` pass and a
cold multi-lens review closed several gate edge cases before release: the acceptance gate's
self-reference loophole; transitive/whole-board inertness (an out-of-wave Done-but-inert enabler no
longer reads as "met"); `blocks_goal: null`/missing now fails closed; present-but-null deferral and
finding fields are rejected by the validator; the github acceptance path was made concrete; and two
bypassable smoke greps (the all-static severity floor, the plan `--auto` polarity) were replaced with
non-invertible ones.

New smoke coverage: `tests/smoke/phase4-acceptance.sh` (registered in `run-all.sh`) plus deferral-schema
and prose-invariant assertions across phases 3–6, each shown red-when-broken.

## 3.0.2 — 2026-06-19

Two post-3.0.1 fix passes: the **experimental Pi runtime's merge gate is brought into line with the
production Claude standard**, and the leftover-issues backlog is cleared.

- **Pi runtime — merge-on-green is now BEHAVIORAL, not a hard interlock (experimental runtime only).**
  An earlier iteration built the Pi build-finisher's merge gate as a hard "MG-B" interlock: the
  per-role bash guard blocked `gh pr merge <N>` unless an independent reviewer had authored a PR-keyed
  `verdict.json` PASS, and the reviewer was granted scoped write to that file. That is **stricter than
  the production Claude runtime**, where the finisher merges on green because its prompt's
  `/fullauto-goal` contract says so — no hard lock, no GitHub branch protection. The Pi runtime now
  **mirrors that behavioral gate**: the verdict-file interlock, the reviewer's verdict-dir write grant,
  and the verdict-file reader are removed; `build-review` is **read-only** again (findings travel to
  `build-finish` over coms-net); `build-finish` keeps merge-only-on-green+PASS **behaviorally**.
  **Zero GitHub changes.** All of the PR's general guard hardening is retained (cross-repo `git -C`
  denial, the `git -c alias=…` arbitrary-shell block, the role-scoped merge grant, force-push /
  `--auto` / `--admin` denials, the governance file-write ACL, glob / `--pathspec-from-file`
  refusals), as is the alignment of all 7 Pi role prompts to the 5-field board
  (Status/Stage/Wave/Phase/Domain + blocked-by). The guard's best-effort residuals are now documented
  in `runtime/pi/SECURITY.md`.
- **Leftover-issues backlog cleared (#69).** Triage closed 12 stale/already-resolved issues; the real
  work was **lint MIN-9 hardening** (+ test), the **codex command-mirror prune + a `/idc:doctor` drift
  check** (+ test), and the **Pi model-doc truth** fix (the launcher hardcodes the per-role model
  defaults; the docs now say so). `#66` (Pi self-driving runtime maturity) stays open.

## 3.0.1 — 2026-06-19

Overnight autorun / e2e hardening from two autonomous loops against the autorun sandbox.

- **Silent-failure retirement.** A GraphQL retire step that could fail silently now surfaces the error,
  and `/idc:uninstall` cleans up after it.
- **Deterministic branch cleanup.** A non-deterministic post-drain branch cleanup is replaced with a
  deterministic one.
- **jq-injection hardening** in the GitHub tracker recipe, plus a `.gitignore` for review-report litter
  under the scaffolded `code-reviews/` tree.
- **Exit-report accuracy.** The Autorun exit report no longer overstates what a drain completed.

## 3.0.0 — 2026-06-16

IDC v3 — **the gate moves to the top, requirements grow a second half, and Ripple becomes the
Recirculator.** A single idea is now approved **once, at the end of Think**, then planning and
building free-flow. **Breaking** (the `/idc:ripple` command is renamed and the human gate relocates).

- **`/idc:ripple` → `/idc:recirculate` (Ripple → Recirculator).** A full, atomic rename of the
  backflow stage across the command, the agent, the doc-sync skill, the layers helper script, every
  prose reference, and — load-bearingly — the **typed `ripple` coms-net role** in the pi runtime (the
  `IdcRole` type, the role Set, the glass-wall ACL special-cases, the path-policy switch, and the
  persona peer-lists). The retrograde path is now the **Recirculator** everywhere. **Breaking:** scripts
  or muscle-memory calling `/idc:ripple` must switch to `/idc:recirculate`.
- **The one gate moved to the end of Think (requirements admission via the Think PR).** Previously the
  single human gate sat mid-pipeline and the PRD auto-merged before approval. Now **Think** crystallizes
  an idea into its requirements and opens a **Think PR** carrying them; the PRD/TRD stay **draft until
  you merge it** — **merge = approval = admission**. Approval is **sync or async** (in-session, or leave
  the PR open and approve later from the GitHub web UI). **Plan sheds all requirements authoring** and
  becomes pure decomposition (no PRD/TRD, no gate). **Autorun** treats an **open Think PR** exactly like
  an open gate — *report + skip*, never stall or bypass — so an unattended run only ever
  plans/builds **admitted** ideas. The Recirculator reuses this same gate for any backflow that needs a
  requirements change. **Breaking:** the approval point and the doc-write authorities changed.
- **The TRD is now a first-class, gateable requirements doc, with a toggle.** The old un-gated `spec`
  layer is elevated to a **TRD** (the technical *how*), authored by Think alongside the PRD. A new
  `gating:` block in `WORKFLOW-config.yaml` controls admission: **`gating.prd`** (default **on** — the
  PRD always gates) and **`gating.trd`** (default **off** for greenfield; **on** for brownfield, to
  protect an established stack from silent re-architecture). The gate predicate becomes
  `gate = prd_changed OR (spec_changed AND trd_gating)`. The gate's arming switch **fails closed**: a
  present-but-unrecognized `gating.*` value (typo / mis-indent) gates **on** rather than silently
  defaulting off, and an unreadable explicit config is a hard error — a brownfield's intended
  `trd: on` is never silently lost.
- **TRD establishment at `/idc:init` (brownfield scan-and-confirm; no-invent).** Init now scans a
  brownfield repo for existing PRD/TRD/spec files + the stack and **confirms what it found** with you
  (scaffold-from-repo / from-scratch / a mix) — it **never invents** an exhaustive architecture doc at
  setup — and sets the type-aware gating default (brownfield `gating.trd: on` / greenfield off).
  Greenfield keeps the PRD-then-TRD conversation in Think (no starter docs written at init). PRD/TRD
  template shapes updated to the two-doc model.
- **Metaphor + docs rebuilt to the two-diverter model.** `docs/mental-model.md`, `README.md`,
  `docs/architecture.md`, and the hero/banner diagram assets are rebuilt to the v3 picture:
  **Diverter #1** = the one gate (the Think PR admitting the PRD + TRD); planning is a **processing
  train** (grid-plates → the matrix → the matrix-analysis filter → the sequencer manifold → parallel
  **waves**, *no turbines*); **Build** is the only place with **turbines** (iterative loops —
  implementer → review filter → finisher); **Diverter #2** = ship-or-return at the end of Build,
  feeding the **Recirculator** backflow up to Diverter #1; the tracker is the **dashboard**. The old
  "Bleed Valve" term is retired.
- **The v3 gate model reaches every runtime, including the experimental Pi runtime.** The gate
  relocation (Think authors + gates the PRD/TRD; Plan is pure decomposition that authors nothing and
  runs no gate) now holds on the **default Claude runtime**, **Codex**, **and** the optional,
  experimental **Pi runtime**: its role-harness write-authority gives Think (not Plan) `docs/prd` +
  `docs/specs`, and the `think`/`plan` personas encode author-at-Think / pure-decompose — fail-closed,
  no fail-open gate. See `docs/architecture.md` (Runtime model).

## 2.1.5 — 2026-06-15

- **Testing-suite overhaul so "green" means "ready for production."** 2.1.3 passed lint + smoke +
  e2e + adversarial review yet shipped a bad `/idc:update` experience, because the suite tested a
  bash re-encoding of the rules (never the real command), used blank inputs, and never asserted the
  quiet/no-op default. This release closes those holes for the file-changing commands
  (`init`/`update`/`uninstall`/`doctor`):
  - **Realistic-input + no-op-default tests** (`tests/smoke/phase7-file-commands-noop-default.sh`,
    shared fixture `tests/smoke/lib/realistic-repo.sh`): the commands' decision helpers are now
    exercised against a *filled-in, already-set-up* repo (and an older-schema upgrade), asserting the
    non-destructive/quiet default — when a project is already correct, nothing changes and no prompt
    is raised. This is the exact assertion 2.1.3 lacked.
  - **Prose-invariant backstop** (`tests/smoke/phase7-command-prose-invariants.sh`): cheap grep
    checks lock the must-hold instructions in the file-changing command markdown (e.g. update never
    offers to overwrite a data config; init stamps data configs `--customized`; doctor is read-only).
  - **`docs/RELEASING.md`** — a three-gate production-ready checklist (automated checks green; no-op
    default holds on a realistic repo; a read-only sanity check against a *real* configured repo
    before tagging). An audit confirmed every repo-mutating decision in the file-changing commands
    already lives in a testable helper, not free-form prose.
  No shipped runtime behavior changed; this is test/doc/process hardening (version bump per the
  shippable-change rule).

## 2.1.4 — 2026-06-15

- **`/idc:update` no longer presents a destructive keep-vs-replace prompt for the two data-bearing
  configs.** `WORKFLOW-config.yaml` and `docs/workflow/tracker-config.yaml` are operator-owned data
  files seeded once from a *blank stub* template, so a filled config always differs from the
  template byte-wise — that difference is the operator's data, not drift. The old flow surfaced this
  as a "keep your data / replace with the blank stub" decision on every update, where "replace"
  could only ever destroy data and align nothing. Update now **preserves these files unconditionally
  and never offers to overwrite them.** A new `scripts/idc_config_keys.py` extracts *structural*
  key-paths (list contents, block scalars, and flow values treated as opaque), so update can tell
  "only your data differs" (→ `preserved — config current`, silent) from "the new version added a
  key/field" (→ a non-destructive advisory listing the new optional keys to adopt by hand). This is
  the smooth, non-breaking, structure-aligning behavior an update should have. Subsumes and
  strengthens 2.1.3's `always_ask` guard.
- **`/idc:update` Phase 0 now halts on a stale-session load.** Claude Code caches a command's
  markdown at session start and runs it from a version-keyed cache dir; updating the plugin
  mid-session can leave the session executing the OLD command body against a NEWER install (which
  can re-introduce just-fixed bugs). A new `scripts/idc_plugin_freshness.py` compares the running
  version against the newest version in the cache; if a newer one is installed, update STOPs and
  tells the operator to `/reload-plugins` or restart. Fail-open: `--plugin-dir` dev loads and
  undetectable cases proceed normally.

## 2.1.3 — 2026-06-14

- **`/idc:update` now resolves every template through one shared map, closing a docs-tree clobber
  footgun.** Update re-derived each stamped file's template source loosely ("the templates live
  under `templates/`"), so an agent resolving `docs/workflow/README.md` by basename/path-tail could
  pick the unrelated `templates/README.md` (the templates-dir doc) and overwrite the governed
  README. A new `scripts/idc_template_for.py` is the single source of truth for the dest→template
  mapping — `docs/workflow/<rest>` → `templates/docs-tree/<rest>`, with `WORKFLOW.md`,
  `WORKFLOW-config.yaml`, and `docs/workflow/tracker-config.yaml` special-cased — and **both**
  `idc_init_scaffold.sh` and `/idc:update` now resolve through it, so scaffold and resync can't
  drift. Update stops rather than guessing if the resolver rejects a path.
- **Legacy-receipt guard: `/idc:update` always diff-and-asks for the two data-bearing configs.**
  A repo installed by a pre-2.1.0 plugin carries a receipt that marks `WORKFLOW-config.yaml` and
  `docs/workflow/tracker-config.yaml` `state: stamped` (they predate the `--customized` guard), so
  the first post-upgrade update could silently overwrite their `domains` / `field_ids` /
  `project_number`. `idc_receipt_check.py verify --json` now emits an `always_ask` set, and update
  shows-diff-and-asks for those paths regardless of receipt state. Additive, back-compatible.

## 2.1.2 — 2026-06-14

- **`/idc:init` now gates *every* Phase-4 board mutation behind the provenance check.** 2.1.1 moved
  the repo-link past the destructive `Status`-options gate, but the four `gh project field-create`
  calls (`Stage`, `Wave`, `Phase`, `Domain`) still ran *before* it — so an existing populated board
  with incompatible `Status` options got those fields added and then STOPped half-provisioned. The
  provenance gate now runs **first**; the four field-creates and the link both run **only past it**,
  so a STOP leaves someone else's board exactly as found (no fields added, not linked). The
  field-creates are also **idempotent** now (check-first against `field-list`) — `gh project
  field-create` does not dedupe, so re-running/linking an already-provisioned board no longer adds
  duplicate same-named fields.

## 2.1.1 — 2026-06-14

- **`/idc:init` now links the GitHub Projects board to the governed repo.** A Projects v2 board
  is owned by the user/org, so creating it with `gh project create` left it invisible from the
  repo — its **Projects tab** read "Add projects from your organization…" and operators looking
  at the repo to approve `operator-action` gate issues couldn't find the board. Init now runs an
  idempotent link step on **both** the create and link-existing paths (repo-rooted probe → `gh
  project link`; reports `linked` / `skipped-existing`), and the Phase 8 summary reports the
  outcome. Tooling was never affected — it addresses the board by `owner + number` — so this is
  purely a human-gate UX fix. The link step runs only **after** the destructive `Status`-options
  gate passes, so an existing populated board with incompatible `Status` options STOPs **unlinked**
  rather than being published to the repo half-provisioned.
- **`/idc:doctor` gains a report-only "board not linked" advisory.** Check 3's `github` branch
  now surfaces a never-FAIL **PASS with ⚠** when a reachable board isn't linked to the repo (with
  the one-line `gh project link` fix), mirroring the stale-cache advisory; a transient/auth
  GraphQL error yields a could-not-determine note, never a FAIL.

## 2.1.0 — 2026-06-14

- **Per-repo opt-in hardening (no global leak).** IDC now installs at `project` scope
  (`claude plugin install idc@idc-workflow --scope project`), so its `/idc:*` commands activate
  only in repos you opt in — never machine-wide. The old install docs used the default `user`
  scope, which surfaced IDC in **every** repo; the README + install guide now document the
  project-scoped flow and the `claude plugin disable idc@idc-workflow --scope user` reseal for
  older installs. `/idc:doctor`'s first check now **FAILs** when IDC is enabled at `user` scope
  (it previously rubber-stamped that state as PASS), with the one-line fix. The project-scope
  install registers IDC `false` at the global `user` scope (an explicit off-switch, not "absent");
  doctor **SKIP**s an opaque `--plugin-dir`/managed override instead of passing it; and scoped
  updates use `claude plugin update idc@idc-workflow --scope project`.

- **Plugin lifecycle commands (built on the install receipt).** Two receipt-driven lifecycle
  commands rejoin the surface — now **nine** commands:
  - `/idc:update` — refresh stamped scaffold files after a plugin update. Silently re-stamps
    files the install receipt proves untouched, shows a diff and asks on files you customized
    (never silently overwriting your edits), and **reports** GitHub board drift without ever
    mutating the board. Files-only, idempotent (`skipped-already-current`); graduates a
    pre-receipt repo to receipt-driven on first run.
  - `/idc:uninstall` — remove IDC's repo footprints as the inverse of `/idc:init`: a
    receipt-driven removal manifest (with a hardcoded pre-receipt fallback), work products
    archived to an untracked `idc-archive-<date>.tar.gz`, and one **revertable** commit that
    strips only IDC's scaffold/config/enablement key. GitHub is untouched by default; opt-in
    `--close-issues` (reversible) and `--delete-board` (permanent, typed confirmation).
  - Both consume the install receipt `/idc:init` already writes; the safety-critical
    fingerprint compare lives in the dependency-free helper `scripts/idc_receipt_check.py`
    (`stamp` + `verify`), covered by the `tests/smoke/phase7-lifecycle.sh` round-trip. (At
    2.0.0 these commands were retired pending this receipt substrate; this re-adds them on it.)

- **Update-path + release hardening.** `/idc:init` now records the two operator/board-data
  scaffold files (`WORKFLOW-config.yaml` `domains`, `tracker-config.yaml` `field_ids`) as
  `state: customized`, so `/idc:update` shows-diff-and-asks instead of silently overwriting
  them from the template — closing a data-loss bug that wiped `domains`/board wiring on every
  update. Update's board-drift report (and `/idc:doctor`) are now on the full **five-field**
  Stage contract (a missing `Stage` is additive/informational, never a failure), the docs spell
  out the scope-aware `claude plugin update idc@idc-workflow --scope project` (the bare command
  targets `user` scope and errors for a project install), and a release-discipline lint guard
  fails a ship-without-version-bump and a `plugin.json`/`marketplace.json` version mismatch.

## 2.0.0 — 2026-06-12

Full v2 overhaul — a clean-slate rebuild from the operator interview in
`docs/considerations/2026-06-12-idc-v2-overhaul-considerations.md`. **Breaking.**

- **Guardrails, not train tracks.** v2 trusts the model and keeps only five guardrails: the
  one PRD gate, matrix deconfliction, real verification surfaces, ripple, and one-way flow
  through the glass wall. The standing reviewer/fixer/researcher roles, the multi-pass plan
  reviews, the claim-state machine, and the per-edit gates are gone.
- **Command surface:** seven commands — `think`, `plan`, `build`, `ripple`, `autorun`,
  `init`, `doctor`. The `sequence` command is retired (sequencing is now a phase inside
  plan); the standalone uninstall/update/upgrade commands are retired (their lifecycle scope
  folds into init-written install receipts).
- **Inventory:** ~23 agents → 6 (per-stage orchestrators + one durable-worker implementer +
  the review coordinator); ~38 skills → 12; the five Codex skill trees → one Codex adapter
  over a shared runtime-neutral core.
- **Tracker:** the board is now **four** fields — `Status` (`Blocked|Todo|In Progress|Done`),
  `Wave`, `Phase`, `Domain` — plus native blocked-by, an `attempt:<n>` label, and claim
  comments; an issue is workable cold by an outside agent. The eight-field
  claim-state/lane/track machinery is gone.
- **The one gate:** a single PRD-change approval issue (plain-terms summary + diff + push
  notification, approved from the GitHub web UI). Everything else automerges when green.
- **Runtime model:** a runtime-neutral core over three primitives (durable worker, bounded
  fan-out, goal loop) with one thin adapter per runtime (Claude, Codex); tier-symbolic model
  routing in `WORKFLOW-config.yaml`.
- **Review engine:** the merged 13-dimension review engine now ships inside the plugin (all
  `code-review-custom` features + the pi-idc-collab review agent), with test genuineness as a
  review dimension.
- **Verification:** the functional smoke suite (`tests/smoke/`) over executable helpers; the
  v1 behavioral evalsets are retired. CI runs the smoke suite on every PR/push.
- **Settings safety:** `/idc:init` uses a tested safe-write helper for
  `.claude/settings.json` and the install receipt excludes that operator-owned file from
  stamped fingerprints.
- New v2 PRD + master architectural spec for the plugin itself; rewritten README, `llms.txt`,
  architecture, and installing docs.

## 0.1.0 — 2026-06-11

Initial public release: the v1 IDC workflow, migrated from a local `~/.claude` installation
into a standalone, installable Claude Code plugin. (Superseded by 2.0.0.)
