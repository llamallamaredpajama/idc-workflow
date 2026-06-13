---
name: idc-schema-check
description: 'Use during Plan board admission to mechanically validate that an issue body is a complete, self-sufficient goal contract before it goes on the board.'
---
# idc-schema-check

The mechanical gate Plan runs on every issue body before admission (`WORKFLOW.md §3.2`,
§4.2). An issue is the glass-wall contract a builder works **cold**, so it must carry the
whole 6-element goal contract plus declared boundaries, dependencies, and trace. This is the
*only* structural plan review besides matrix deconfliction (`idc:idc-matrix-analysis`) — v2
deleted the multi-pass plan-review suite; content defects surface cheaply downstream as a
Ripple.

## Required issue body

```
GOAL: <single observable end-state>
VERIFICATION SURFACE: <runnable commands + what passing looks like — real functional tests>
CONSTRAINTS: <what must not regress; the no-punt rule>
BOUNDARIES: touch <owned surfaces> / off-limits <…>
ITERATION POLICY: record-and-vary
BLOCKED-STOP: <halt conditions + attempt ceiling>
ASSUMPTIONS: <inferred, vetoable>
---
Dependencies: <native blocked-by links>
Trace: <pillar file · consideration · PRD section>
```

## The check

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_schema_check.py" <issue-body.md>
```

It requires every labelled element to be present, `GOAL` and `VERIFICATION SURFACE` to be
non-empty, and `BOUNDARIES` to declare both `touch` and `off-limits` (the deconfliction
output). Exit non-zero with a reason list otherwise. It checks **structure, not prose** —
genuineness of the verification surface (real tests vs shallow) is enforced later by the
review engine's test-genuineness dimension at Build.

## Authority boundaries

- Validates issue-body structure only. Never admits the issue (the orchestrator does, via
  `idc:idc-tracker-adapter`), never writes canonical docs, never spawns teammates.
