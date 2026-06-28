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

## Executable helper

The backend is executable so it round-trips deterministically (no agent guesswork, and the
smoke tests are real). All mutations go through the shipped helper, standard-library Python:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_tracker_fs.py" --tracker <repo>/TRACKER.md <op> [args]
```

| Interface op | Invocation |
|---|---|
| (bootstrap) | `init` — create an empty `TRACKER.md` (idempotent) |
| `createTicket` | `create --title T [--status Todo] [--stage Stg] [--wave W] [--phase P] [--domain D] [--blocked-by N,N]` → prints the new number |
| `setField` | `set --num N --field {Status\|Stage\|Wave\|Phase\|Domain} --value V` |
| `move` | `move --num N --status "In Progress"` |
| `link` | `link --parent N --child M --kind {blocks\|sub}` (`blocks` → M blocked-by N) |
| `query` | `query [--status S] [--stage Stg] [--wave W] [--phase P] [--domain D]` → newline-separated numbers |
| `comment` | `comment --num N --body "…"` |
| claim | `claim --num N --agent NAME` (Status→In Progress + a comment naming the agent) |
| block | `block --num N [--by M]` (Status→Blocked + optional blocked-by) |
| close | `close --num N` (Status→Done; idempotent) |
| read | `show --num N [--field F \| --comments \| --blocked-by]` |
| lease-acquire | `lease-acquire [--lease merge] --owner NAME [--ttl S]` → prints an opaque token, or exits non-zero if already held (fail-closed) |
| lease-release | `lease-release [--lease merge] --token TOKEN` (release-by-token; idempotent when unheld; a wrong token is rejected) |
| lease-show | `lease-show [--lease merge]` → JSON `{owner, acquired_at, expires_at, held}` (token omitted), or empty when unheld |

The helper writes atomically (temp + replace), re-renders the board table on every
mutation, validates Status and Stage against their option sets, and never lets the JSON
block and the table diverge. The caller commits `TRACKER.md` with a `tracker:` prefix.

## Claim protocol

A builder claims an issue by `claim --num N --agent <name>` — that flips `Status` to
`In Progress` and records a claim comment naming the agent. Parallel claims on distinct
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
