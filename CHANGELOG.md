# Changelog

All notable changes to the IDC Workflow plugin are documented in this file.

## Unreleased

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
