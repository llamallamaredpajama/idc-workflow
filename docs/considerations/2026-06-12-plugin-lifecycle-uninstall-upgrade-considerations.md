---
kind: consideration
queue_status: active-unprocessed
domain: plugin-lifecycle-uninstall-upgrade
updated: 2026-06-12
---

# Plugin Lifecycle: /idc:uninstall and /idc:upgrade

## Frame

The idc plugin has an installer (/idc:init) but no exit or update path. Two lifecycle commands are under
consideration: /idc:uninstall (remove all repo footprints safely; design largely settled by the operator) and
/idc:upgrade (refresh stamped files after plugin updates; shaped this session). A shared "install receipt"
substrate emerged that both commands consume.

## Named Ideas

- **Install receipt (shared substrate).** /idc:init writes a committed repo file listing every file it writes
  plus a content fingerprint. Upgrade uses it to prove a file untouched; uninstall uses it as the removal
  manifest. Rejected alternative: untracked machine-local file (benefits would not travel with clones).
- **/idc:uninstall — phased idempotent mirror of /idc:init.** Work products archived to an untracked repo-root
  tarball `idc-archive-<date>.tar.gz`, path always announced. GitHub untouched by default; opt-in
  `--close-issues` (reversible) and `--delete-board` (permanent, typed confirmation; issue deletion never
  offered). All repo footprints removed in ONE revertable commit: scaffold, configs, TRACKER.md when
  filesystem backend, `enabledPlugins` key stripped preserving other keys. Removal list is receipt-driven
  ("only delete what you created"); hardcoded footprint list retained as pre-receipt fallback — and note
  TRACKER.md is runtime-created (never written by init), so its receipt coverage is an open decision below.
  Re-runs report skipped-absent.
- **Uninstall preflight, two layers.** Clean git state required (tracked files; prior runs' untracked
  `idc-archive-*.tar.gz` must be exempt or re-runs self-block), plus a board state check: in-flight items
  ("N issues still in progress — orphaning") reported plainly with an explicit confirmation gate
  (warn-and-confirm; rejected: hard block, and no check at all).
- **/idc:upgrade — receipt-only detection (v1).** Silently re-stamp only files the receipt proves untouched;
  customized files get show-diff-and-ask. Pre-receipt installs: diff-and-ask for every file, one time.
  Rejected for v1: compare-against-prior-version-templates; layered all-three approach.
- **Upgrade scope: files only + board-drift detection.** Upgrade never mutates the board; it MUST compare the
  board schema against the new plugin version's expectation and report drift explicitly, never silently.
  Rejected: board migration machinery (hypothetical change, real risk to live issues and in-flight waves).
- **Receipt graduation.** The first upgrade on a pre-receipt repo finishes by writing a fresh receipt;
  ask-first treatment is one-time, then the repo is receipt-driven for both upgrade and uninstall.
- **Re-run to repair.** Upgrade inherits init's idempotency contract: each step checks current state; re-runs
  resume with "skipped, already current"; the receipt is rewritten ONLY at the end of a successful run so a
  half-done upgrade can never masquerade as finished. Rejected: all-or-nothing staging.

## Context Notes

- Machine-global surfaces are out of uninstall scope; the closing summary names `claude plugin uninstall` and
  `install-codex.sh --revert` for the operator to run separately.
- `install-codex.sh --revert` recorded-state manifest is the in-repo precedent for "only delete what you
  created."
- `commands/init.md` provides the created/skipped-existing idempotency vocabulary and the `enabledPlugins` jq
  write that uninstall mirrors and inverts.
- No version/stamp markers exist in stamped files today; `templates/WORKFLOW-config.yaml` `workflow.version`
  is a schema version, not an install stamp.
- `docs/installing.md` has no updating section today; the upgrade train adds one.
- The v0.1.0 release report records a plugin cache-refresh quirk relevant to upgrade runs.

## Open Decisions

- Receipt schema internals: field shape, fingerprint method, exact filename/path within the scaffold; what a
  receipt entry records for files the operator kept customized at diff-and-ask (mark customized / template
  fingerprint / exclude) — same answer for graduation and the end-of-run rewrite, else the next upgrade
  treats kept customizations as "untouched" and silently re-stamps them.
- Runtime-created footprints (TRACKER.md): does the tracker adapter append them to the receipt on first
  write, or does the hardcoded list permanently cover them (making it more than a pre-receipt fallback)?
- Failure-path postures, never silent: receipt present but invalid (abort loudly vs announce-and-confirm
  fallback); board read fails at uninstall preflight (hard block vs explicit "could not verify in-flight
  items" confirm); board drift check cannot run (third explicit outcome, distinct from "no drift").

## Engineering Implications

- /idc:init gains a new write surface (the receipt) and must fingerprint everything it stamps — fingerprints
  of the rendered as-written files (post token-substitution), not the templates.
- Upgrade and receipt-driven uninstall recompute on-disk fingerprints and compare against the receipt; that
  compare is the safety-critical surface and must fail toward asking, never toward silent re-stamp.
- Receipt is a committed scaffold file: covered by the clean-git preflight, removed in uninstall's single
  revertable commit, portable across machines and clones.
- Uninstall preflight extends beyond git-clean to a tracker/board read for in-flight detection.
- Upgrade needs access to the new plugin version's expected board schema to diff against the live board
  (report-only).
- Both commands carry init's idempotency vocabulary (created / skipped-existing), extended with two new
  statuses: skipped-absent (uninstall re-runs) and skipped-already-current (upgrade re-runs).

## Source Pointers

- commands/init.md — idempotency vocabulary; enabledPlugins jq write
- install-codex.sh — --revert recorded-state manifest precedent
- templates/WORKFLOW-config.yaml — workflow.version semantics
- docs/dev/2026-06-12-v0.1.0-release-report.md line 140 — cache-refresh quirk
- docs/installing.md — missing updating section

## Next Role Questions

- Operator sequencing preference for Plan to weigh (preference, not a verdict): two trains, uninstall first —
  Train 1 = /idc:init receipt-writing + /idc:uninstall; Train 2 = /idc:upgrade + installing.md updating
  section. Rejected by operator: one combined train (bigger, slower, riskier).
- Should the receipt fingerprint method follow an existing repo hashing convention, and where exactly should
  the receipt live in the scaffold?
- How should upgrade surface the cache-refresh quirk to operators (preflight note vs docs-only)?
