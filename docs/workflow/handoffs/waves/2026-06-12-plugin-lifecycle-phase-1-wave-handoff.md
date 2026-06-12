# Wave handoff — plugin lifecycle Phase 1

- **Sequence run:** `2026-06-12-lifecycle-phase-1-admit`
- **Tracker backend:** GitHub Projects v2 — Project #4
- **Recorded at:** 2026-06-12T22:21:11Z
- **Audit:** `docs/workflow/audits/2026-06-12-plugin-lifecycle-phase-1-sequence-admission-audit.md`

## Live Build queue

### Wave 1 — Active

- #16 — **Build: receipt format and init writer**
  - Pillar trace key: `plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer`
  - Pillar plan: `docs/plans/pillars/archive/plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer-plan.md`
  - Matrix: `docs/workflow/pillar-matrices/plugin-lifecycle-phase-1-matrix.yaml`
  - Blocks on: none

### Wave 2 — Pending

- #17 — **Build: uninstall command**
  - Pillar trace key: `plugin-lifecycle-phase-1-subphase-2-pillar-1-uninstall-command`
  - Pillar plan: `docs/plans/pillars/archive/plugin-lifecycle-phase-1-subphase-2-pillar-1-uninstall-command-plan.md`
  - Matrix: `docs/workflow/pillar-matrices/plugin-lifecycle-phase-1-matrix.yaml`
  - Blocks on: #16

## Superseded invalid admission

- #14 and #15 were direct-admitted before Sequence. They were removed from Project #4 and closed as `not planned` before #16/#17 were created.

## Build handoff instructions

- Start with #16 only. Do not dispatch #17 until #16 has landed and the tracker is advanced according to normal Build/Sequence policy.
- Treat the archived pillar plan linked in each issue as the authoritative /goal contract source.
- If implementation discovers PRD/spec/master-plan drift, stop and invoke the Ripple/change-order path rather than silently expanding issue scope.
