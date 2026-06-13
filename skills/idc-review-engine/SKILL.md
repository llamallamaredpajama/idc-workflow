---
name: idc-review-engine
description: 'Use to review a PR or a phase-close delta — the merged 13-dimension review engine that emits a structured, fail-closed verdict.'
---
# idc-review-engine

The merged review engine: every feature of the standalone `code-review-custom` workflow plus
the pi-idc-collab review agent, combined into one engine shipped **inside the plugin** so
consuming repos and outside/cloud agents get it (`WORKFLOW.md §4.3`). It is the
"real verification surfaces" guardrail — nothing merges that isn't actually green on genuine
functional tests.

Used at two sites, both **fresh-context bounded fan-out in every runtime** (cold readers =
true adversarial independence, token-optimal — never durable workers):

1. **Per-PR build review** — iterate on findings → reverify (real tests green) → the Build
   finisher automerges on `PASS`/`PASS-WITH-NITS`.
2. **Phase-close delta review** — one pass over the phase delta; findings are filed as new
   board issues (non-blocking; phase close does not drive them to zero).

## Architecture

- **~8 specialist reviewers** fan out across the 13 dimensions, each reading the diff cold
  and returning findings only in its lane.
- **The coordinator** (`idc:idc-review-coordinator`) merges them: cross-reviewer dedup by
  fingerprint, confidence scoring (drop anything below the **0.8** floor), the severity
  ladder, and the fail-closed verdict.

## The 13 dimensions

| # | Dimension | Looks for |
|---|---|---|
| 1 | protocol | API/interface contract honored across call sites |
| 2 | contract drift | implementation vs the issue's GOAL/contract and upstream docs |
| 3 | error handling | silent failures, swallowed errors, wrong fallbacks |
| 4 | resource mgmt | leaks, unclosed handles, unbounded growth |
| 5 | security | injection, authz, secrets, unsafe input |
| 6 | stack gotchas | language/framework footguns for this stack |
| 7 | unit-test rigor | branches/edge cases covered; assertions meaningful |
| 8 | integration-test gaps | seams + real-path coverage, not just units |
| 9 | dependency/bloat | new deps justified; no needless surface growth |
| 10 | complexity budget | could be materially simpler; over-abstraction |
| 11 | git-history narrative | commits trace to the contract; legible history |
| 12 | stale docs | docs/comments now contradicted by the change |
| 13 | simplification | dead code, duplication, clearer equivalents |

**Test genuineness** is enforced across dims 2/7/8: a verification surface must be a **real
functional test proving behavior**. A shallow, shortcut, or placeholder AI test suite (tests
that assert nothing, mirror the implementation, or stub the thing under test) is a **FAIL
finding**, not a nit.

## Finding shape + verdict

Each finding carries: `dimension`, `severity ∈ {blocker, major, minor, nit}`, `confidence`
(≥ 0.8), `evidence` (file:line + what), `attack` (the failure mode it enables), `unblock`
(the concrete fix), and a stable `fingerprint` (`dimension:file:line:gist`) for dedup.

The verdict is fail-closed and derived from the worst severity present:

| Worst severity | Verdict |
|---|---|
| blocker | `FAIL-BLOCKED` |
| major | `FAIL` |
| minor / nit | `PASS-WITH-NITS` |
| none | `PASS` |

Emit a structured JSON verdict + a human report under `docs/workflow/code-reviews/`. Validate
the JSON before acting on it:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_review_verdict_check.py" <verdict.json>
```

## Model tiers (resolved by the runtime adapter)

- `reasoning`: the coordinator/verdict and the **judgment** dimensions (1–8, 10, 12).
- `utility`: the **inventory** dimensions (9 dependency/bloat, 11 git-history, 13
  simplification sweep) — the coordinator may re-run any dimension up-tier on suspicion.

## Authority boundaries

- Read-only review. Emits the verdict + report; never edits source, tests, or canonical
  docs. The Build finisher (`idc:idc-build`) acts on the verdict (iterate / automerge /
  file phase-close issues); the engine never merges.
