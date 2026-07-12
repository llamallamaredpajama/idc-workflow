---
name: idc-tracker-filesystem
description: 'Use when an IDC tracker operation must read or mutate the filesystem-backed tracker (the filesystem backend — a root TRACKER.md; zero external setup).'
---
# idc-tracker-filesystem

The filesystem backend implementation of the IDC v2 tracker interface (`WORKFLOW.md §3`).
It is what `docs/workflow/tracker-config.yaml::backend = filesystem` resolves through, the
zero-setup option for repos without a GitHub Project, and the deterministic substrate the
sandbox smoke tests run against. Always reached through `idc:idc-tracker-adapter`, never
called directly by a role.

## Substrate

State of record is a single `TRACKER.md` at the repo root. It carries a JSON block between
`<!-- idc-tracker-state:begin -->` / `<!-- idc-tracker-state:end -->` (the source of truth)
plus a re-rendered markdown **Board** table for humans. Every issue is `{number, title, status,
stage, wave, phase, domain, blocked_by[], attempt, comments[]}` — the five v2 fields plus native
blocked-by, the attempt counter, and claim comments. No other state exists.

`Status ∈ { Blocked, Todo, In Progress, Done }`.
`Stage ∈ { Consideration, Planning, Buildable, Recirculation }` is the column-grouping field:
upstream pointer items ride `Consideration`/`Planning`, buildable issues ride `Buildable`, and
`Recirculation` is the non-Buildable inbox for scope discovered mid-build (drained by
`/idc:recirculate`, never claimed as build work). A legacy 4-field tracker leaves Stage empty —
additive. There is no claim-state machine, lane, track, or bookend ceremony (v1, removed).

## Executable helper + the transition engine (the write door)

The backend is executable so it round-trips deterministically (no agent guesswork, and the
smoke tests are real). **Every Status change is a transition** and routes through the engine —
the single sanctioned write door: it validates machine-legality against
`workflow-machine.yaml`, verifies the write's read-back, and journals the op to
`docs/workflow/transition-journal.ndjson` (the record the janitor's board↔journal reconciliation
and doctor Row 10 replay). A raw Status write bypasses the journal and surfaces as divergence:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_transition.py" --backend filesystem --tracker <repo>/TRACKER.md <op> [args]
```

| Interface op | Engine invocation (journaled) |
|---|---|
| `createTicket` | `create-ticket --title T [--body B] [--stage Stg] [--status S]` → prints the new number (set `Wave`/`Phase`/`Domain`/blocked-by afterwards via the raw helper — non-Status fields have no engine op) |
| `move` | `move --num N --to-status "In Progress"` |
| claim | `claim --num N --agent NAME` (Status→In Progress + a comment naming the agent) |
| unblock | `unblock --num N` (Blocked→Todo) |
| block | `move --num N --to-status Blocked`, then `link --parent M --child N --kind blocks` (no single engine `block` op) |
| `link` | `link --parent N --child M --kind blocks` |
| close (verdict-backed) | `close --num N --verdict <verdict.json> --pr <PR>` — the guarded path to `Done`: the verdict must validate, pass, own the item and the PR, with every `merge_conditions[]` met |
| dispose (non-verdict terminal) | `dispose --disposition {gate-approved\|retired\|drained} --num N` — the guarded door to `Done` for a terminal item with **no review verdict**: gate-issue approval, pointer retirement (`--child <decomposition-child>`), recirc-drain retirement. The disposition's deterministic evidence guard must pass; the engine mints `Done` and journals which door + disposition + evidence |

The raw helper stays the mechanic for **reads, non-Status fields, and the primitives with no
engine op** (leases), standard-library Python:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_tracker_fs.py" --tracker <repo>/TRACKER.md <op> [args]
```

| Interface op | Invocation |
|---|---|
| (bootstrap) | `init` — create an empty `TRACKER.md` (idempotent) |
| `setField` (non-Status) | `set --num N --field {Stage\|Wave\|Phase\|Domain} --value V` — never `--field Status`: a Status write is a transition and goes through the engine above |
| `query` | `query [--status S] [--stage Stg] [--wave W] [--phase P] [--domain D]` → newline-separated numbers |
| `comment` | `comment --num N --body "…"` |
| read | `show --num N [--field F \| --comments \| --blocked-by]` |
| lease-acquire | `lease-acquire [--lease merge] --owner NAME [--ttl S]` → prints an opaque token, or exits non-zero if already held (fail-closed) |
| lease-release | `lease-release [--lease merge] --token TOKEN` (release-by-token; idempotent when unheld; a wrong token is rejected) |
| lease-show | `lease-show [--lease merge]` → JSON `{owner, acquired_at, expires_at, held}` (token omitted), or empty when unheld |

The helper writes atomically (temp + replace), re-renders the board table on every
mutation, validates Status and Stage against their option sets, and never lets the JSON
block and the table diverge. The caller commits `TRACKER.md` with a `tracker:` prefix.

## Claim protocol

A builder claims an issue through the engine — `idc_transition.py … claim --num N --agent <name>`
— which flips `Status` to `In Progress`, records a claim comment naming the agent, and journals
the transition. Parallel claims on distinct
issues never race (disjoint surfaces). Where a single holder must be proven **atomically** —
e.g. flat pi finisher residents with no orchestrator contending to update the integration ref —
use the fail-closed **merge lease** (`lease-acquire`/`lease-release`): an advisory `flock` on a
sidecar lock file makes acquire-if-empty-or-expired atomic across processes, returns an opaque
token, and enforces release-by-token + TTL expiry. No lease → no merge.

## Authority boundaries

- Read + mutate the filesystem tracker only, through the helper. Never decides the backend
  (the adapter routes here when `backend: filesystem`).
- Never writes canonical docs (PRD, spec, plans). Never spawns teammates.
- The github backend (`idc:idc-tracker-github`) is the sibling; both expose this identical
  op surface so a backend swap is transparent to callers.
