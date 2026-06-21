# Changelog

All notable changes to the IDC Workflow plugin are documented in this file.

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
  explicit boolean check on `blocks_goal`), emitted by the implementer/finisher/review-engine closeouts;
  the finisher ships **fail-closed** until each deferral is resolved in-loop or converted into a
  dependency-linked board item that blocks the parent's Done.
- **P1 — Dependency-aware acceptance gate.** New `scripts/idc_acceptance_check.py` flags any Done issue
  with an unmet `blocks_goal:true` deferral (`acceptance: ok|gap`); `idc-build.md` Phase 4 wave-close
  runs it as a **blocking** gate that auto-files a recirculation per Done-but-inert issue.
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
