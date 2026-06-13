# Changelog

All notable changes to the IDC Workflow plugin are documented in this file.

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
  v1 behavioral evalsets are retired.
- New v2 PRD + master architectural spec for the plugin itself; rewritten README, `llms.txt`,
  architecture, and installing docs.

## 0.1.0 — 2026-06-11

Initial public release: the v1 IDC workflow, migrated from a local `~/.claude` installation
into a standalone, installable Claude Code plugin. (Superseded by 2.0.0.)
