---
description: IDC health check — verify plugin enablement, gh auth + project scope, the 4-field tracker board, and the v2 scaffold (read-only)
argument-hint: (no arguments)
---

`/idc:doctor` diagnoses whether the current repository is correctly set up for the IDC v2
workflow. **It is strictly read-only** — it never creates, edits, or deletes a file, and
never mutates gh/board state. It checks plugin enablement, `gh` auth + `project` scope, the
tracker contract (`docs/workflow/tracker-config.yaml` + board reachability or `TRACKER.md`
for the filesystem backend), the v2 governance scaffold, and the install receipt — then
prints one `PASS`/`FAIL`/`SKIP` table with a one-line fix hint per row. See `WORKFLOW.md §3`.

> v2 rebuild status: the full `/idc:doctor` check set (aligned to the 4-field board and the
> lean v2 scaffold) is authored in **Phase 1** of the IDC v2 rebuild. (stub)
