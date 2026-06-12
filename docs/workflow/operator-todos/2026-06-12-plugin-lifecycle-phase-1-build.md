# Operator Todos — 2026-06-12-plugin-lifecycle-phase-1-build

## BLOCKING

### Restore the mandatory Build matrix dispatch-check substrate

- **Filed:** 2026-06-12T22:54:14Z
- **By:** build via idc:idc-skill-file-operator-todo
- **Context:** build bootstrap halted before dispatching #16
- **Action required:** Build cannot legally dispatch the active plugin-lifecycle issue because the mandatory dispatch-check CLI substrate is missing from this checkout. The documented gate requires `scripts/sync_github_tracker.py export-state --output <tracker-state.json>` followed by `docs/workflow/scripts/pillar_matrix.py --dispatch-check --pillar=<pillar> --tracker-state=<tracker-state.json> --json`, but neither `scripts/sync_github_tracker.py` nor `docs/workflow/scripts/pillar_matrix.py` exists in the repo. Route the missing substrate through the appropriate upstream IDC role before retrying Build.
- **Phase/subphase blocked:** yes

## Side-jobs

## INFO
