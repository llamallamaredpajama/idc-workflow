# Changelog

All notable changes to the IDC Workflow plugin are documented in this file.

## Unreleased

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
