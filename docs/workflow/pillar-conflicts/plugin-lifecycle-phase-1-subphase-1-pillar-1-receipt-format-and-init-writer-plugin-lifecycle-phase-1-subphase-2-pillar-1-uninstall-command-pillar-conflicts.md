# Pillar Conflicts: plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer ↔ plugin-lifecycle-phase-1-subphase-2-pillar-1-uninstall-command

**Pillar A:** `plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer` (link: `docs/plans/pillars/plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer-plan.md`)
**Pillar B:** `plugin-lifecycle-phase-1-subphase-2-pillar-1-uninstall-command` (link: `docs/plans/pillars/plugin-lifecycle-phase-1-subphase-2-pillar-1-uninstall-command-plan.md`)
**Clash count:** 1

| Resource Kind | Resource ID | Nature of Conflict | Resolution |
|---------------|-------------|--------------------|------------|
| file | CHANGELOG.md | both pillars append to `## Unreleased` to document Phase 1 lifecycle command changes | union |

## Evidence

### Clash 0 — CHANGELOG.md (union)

- `draft-pillar-1-1-1.md` owns `CHANGELOG.md` for the install-receipt substrate entry under `## Unreleased`.
- `draft-pillar-1-2-1.md` owns `CHANGELOG.md` for the uninstall command entry under `## Unreleased`.
- The entries are append-only prose bullets under the same heading. They do not overwrite the same paragraph or define contradictory behavior.
- `plugin-lifecycle-phase-1-subphase-2-pillar-1-uninstall-command` still blocks on `plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer` because uninstall consumes the receipt substrate; the dependency is serialized independently of this append-only union.

## Resolution rationale

Use `union`: both pillars may contribute distinct append-only bullets to `CHANGELOG.md ## Unreleased`, with the downstream uninstall pillar wave-ordered after the receipt substrate by its explicit `Blocks on:` directive. No Ripple is required because the shared surface does not contradict PRD/spec/master-plan scope, and no `commands/init.md`, receipt-path, or `docs/installing.md` shared write remains after the 1.2 plan deliberately excludes `commands/init.md` and consumes the receipt contract read-only.
