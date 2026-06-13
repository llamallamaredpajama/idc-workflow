---
name: idc-tracker-adapter
description: 'Use when an IDC role needs a tracker operation (create/set/link/move/query/comment, or claim/block/close) routed through the repo-configured backend.'
---
# idc-tracker-adapter

The dispatch surface for the IDC v2 tracker interface (`WORKFLOW.md §3`). It resolves the
active backend from `docs/workflow/tracker-config.yaml::backend` and routes every call to
the matching implementation, so callers never hard-code `filesystem` or `github` semantics.
This is the surface the canonical chain terminates at — the glass wall between planning and
building.

## Backend resolution

Read `<repo_root>/docs/workflow/tracker-config.yaml` and the `backend:` key:

| `backend` | Routed to |
|---|---|
| `filesystem` | `idc:idc-tracker-filesystem` (a root `TRACKER.md`; zero setup) |
| `github` | `idc:idc-tracker-github` (a GitHub Projects v2 board) |

Any other value → **halt** with `unknown_backend: <value>`. The adapter never
default-falls-back to a backend — an explicit mismatch is a programmer error that must
surface, not silently degrade.

## The interface (six core ops + conveniences)

Identical across backends; the adapter routes without reshaping signatures.

| Op | Signature |
|---|---|
| `createTicket` | `(title, body, type, labels) → ticket_id` |
| `setField` | `(ticket_id, field ∈ {Status, Stage, Wave, Phase, Domain}, value)` |
| `link` | `(parent_id, child_id, kind ∈ {sub, blocks})` |
| `move` | `(ticket_id, status ∈ {Blocked, Todo, In Progress, Done})` |
| `query` | `(filter) → [ticket_id, …]` |
| `comment` | `(ticket_id, body)` |

Conveniences layered on the six: `claim(ticket, agent)` (Status→In Progress + claim
comment), `block(ticket, by)` (Status→Blocked + native blocked-by), `close(ticket)`
(Status→Done; idempotent). A seventh core op is a contract change requiring a Ripple.

### Merge lease (single-holder serialization)

For merge serialization — where one holder must be proven **atomically** before touching the
integration ref (e.g. flat pi finisher residents with no orchestrator) — the adapter exposes a
fail-closed lease: `leaseAcquire(name, owner, ttl) → token | fail` and `leaseRelease(name,
token)`. Backends realize it differently:

- **filesystem** — implemented: `lease-acquire`/`lease-release` (flock-backed acquire-if-empty-
  or-expired, release-by-token, TTL expiry). See `idc:idc-tracker-filesystem`.
- **github** — **interim**: no native compare-and-set lease yet, so merge stays **single-holder
  fail-closed** — exactly one orchestrator merges (no lease → no merge); a finisher never
  self-merges concurrently. A native Projects-field CAS lease is a tracked follow-up.

## Fail-closed posture

On backend failure (CLI exit ≠ 0, GraphQL error, write failure) the adapter surfaces the
implementation's structured error unchanged and returns non-zero — no automatic retry; the
caller decides retry/halt. It never silently swallows a tracker error before a commit.

## Authority boundaries

- Read `backend` + route only. Never mutates `tracker-config.yaml::backend`. Never edits
  `TRACKER.md` or board items directly — always through the resolved implementation
  (`idc:idc-tracker-filesystem` / `idc:idc-tracker-github`).
- Never decides backend selection (the per-repo config is the source of truth). Never
  spawns teammates. Never reads or writes canonical docs.
